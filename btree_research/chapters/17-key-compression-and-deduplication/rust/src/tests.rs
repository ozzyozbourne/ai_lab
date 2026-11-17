//! Tests for tree.rs, mirroring zig/src/tests.zig one for one. Where Zig
//! injects allocation failures, Rust runs out of its page budget.
use crate::demo;
use crate::prng::SplitMix64;
use crate::tree::*;
use std::cmp::Ordering;
use std::collections::BTreeSet;

fn cell(key: &str, tids: &[Tid]) -> LeafCell {
    LeafCell { key: key.as_bytes().to_vec(), tids: tids.to_vec() }
}

fn config(page_size: usize, truncate: bool, dedup: bool) -> Config {
    Config { page_size, truncate, dedup }
}

#[test]
fn run_prints_exactly_expected_output() {
    let mut out = String::new();
    demo::run(&mut out);
    assert_eq!(out, include_str!("../../expected_output.txt"));
}

#[test]
fn compare_tuple_key_bytes_then_tid_and_a_missing_tid_is_minus_infinity() {
    assert_eq!(compare_tuple(b"app", Some(9), b"apple", Some(1)), Ordering::Less); // a prefix sorts first
    assert_eq!(compare_tuple(b"apple", Some(1), b"apple", Some(2)), Ordering::Less);
    assert_eq!(compare_tuple(b"apple", None, b"apple", Some(0)), Ordering::Less); // truncated TID
    assert_eq!(compare_tuple(b"apple", Some(0), b"apple", None), Ordering::Greater);
    assert_eq!(compare_tuple(b"apple", None, b"apple", None), Ordering::Equal);
    assert_eq!(compare_tuple(b"b", None, b"apple", Some(99)), Ordering::Greater);
}

#[test]
fn separator_shortest_prefix_that_separates_tid_only_when_keys_are_equal() {
    let cases: [(&str, &str, &str, Option<Tid>); 5] = [
        ("banana", "cherry", "c", None),
        ("blackberry", "blueberry", "blu", None),
        ("app", "apple", "appl", None),       // left is a prefix of right
        ("apple", "apply", "apply", None),    // differ in the last byte: no gain
        ("apple", "apple", "apple", Some(4)), // equal keys: last-left key AND TID
    ];
    for (left, right, key, tid) in cases {
        let l = cell(left, &[4]);
        let r = cell(right, &[7, 9]);
        let (sep_key, sep_tid) = separator(true, &l, &r);
        assert_eq!(sep_key, key.as_bytes());
        assert_eq!(sep_tid, tid);
        // The contract: last_left <= sep < first_right.
        assert_ne!(compare_tuple(&l.key, Some(4), sep_key, sep_tid), Ordering::Greater);
        assert_eq!(compare_tuple(sep_key, sep_tid, &r.key, Some(7)), Ordering::Less);
        // Without truncation the separator is always the full last-left tuple.
        assert_eq!(separator(false, &l, &r), (left.as_bytes(), Some(4)));
    }
}

#[test]
fn byte_accounting() {
    assert_eq!(leaf_cell_size(5, 1), 15); // slot 2 + len 2 + "apple" 5 + TID 6
    assert_eq!(leaf_cell_size(5, 3), 29); // slot 2 + len 2 + 5 + count 2 + 3 * 6
    assert_eq!(sep_size(None), 0);
    let c = Sep { key: b"c".to_vec(), tid: None };
    assert_eq!(sep_size(Some(&c)), 5);
    assert_eq!(sep_size(Some(&Sep { key: b"banana".to_vec(), tid: Some(3) })), 16);
    assert_eq!(pivot_size(&c), 9);
}

#[test]
fn empty_tree_duplicates_rejected_key_size_limit() {
    let mut tree = Tree::new(config(256, true, true));
    tree.validate().unwrap();
    assert_eq!(tree.max_key_len(), 27);
    assert_eq!(tree.put(b"apple", 1), Ok(true));
    assert_eq!(tree.put(b"apple", 1), Ok(false)); // same (key, TID): already there
    assert_eq!(tree.put(b"apple", 2), Ok(true)); // same key, other row: a new entry
    let long = [b'x'; 28];
    assert_eq!(tree.put(&long, 1), Err(Error::KeyTooLarge));
    assert_eq!(tree.put(&long[..27], 1), Ok(true));
    assert!(tree.contains(b"apple", 2));
    assert!(!tree.contains(b"apple", 3));
    assert!(tree.delete(b"apple", 1));
    assert!(!tree.delete(b"apple", 1));
    assert_eq!(tree.count, 2);
    tree.validate().unwrap();
}

#[test]
fn a_search_routes_correctly_through_truncated_separators() {
    let mut tree = Tree::new(config(128, true, true));
    let words = ["a", "ab", "abc", "abcd", "b", "ba", "bab", "c", "ca", "cab", "d", "da"];
    for round in 0..6 {
        for (i, w) in words.iter().enumerate() {
            assert_eq!(tree.put(w.as_bytes(), round * 100 + i as Tid), Ok(true));
        }
    }
    tree.validate().unwrap();
    let s = tree.stats();
    assert!(s.height >= 2);
    assert_eq!(s.entries, 72);
    for (i, w) in words.iter().enumerate() {
        let want: Vec<Tid> = (0..6).map(|round| round * 100 + i as Tid).collect();
        assert_eq!(tree.get(w.as_bytes()), want);
    }
    // Keys that are absent but equal to, shorter or longer than separators.
    for w in ["", "aa", "abcde", "bb", "cz", "e"] {
        assert!(tree.get(w.as_bytes()).is_empty());
    }
}

#[test]
fn deduplication_turns_a_page_of_duplicates_into_posting_lists_instead_of_splitting() {
    let mut with = Tree::new(config(256, true, true));
    let mut without = Tree::new(config(256, true, false));
    for i in 0..60 {
        let key: &[u8] = if i % 2 == 0 { b"open" } else { b"closed" };
        with.put(key, i).unwrap();
        without.put(key, i).unwrap();
    }
    with.validate().unwrap();
    without.validate().unwrap();
    let (a, b) = (with.stats(), without.stats());
    assert_eq!(a.entries, 60);
    assert!(a.posting_cells > 0);
    assert_eq!(b.posting_cells, 0);
    assert!(a.leaf_pages < b.leaf_pages);
    assert!(with.counters.dedup_passes > 0);
}

#[test]
fn posting_list_split_a_tid_inside_a_posting_lists_range_pushes_the_largest_one_out() {
    let mut tree = Tree::new(config(256, true, true));
    // 15 even TIDs fill the page; the 16th put triggers the dedup pass.
    let mut i: Tid = 0;
    while tree.counters.dedup_passes == 0 {
        tree.put(b"k", i).unwrap();
        i += 2;
    }
    let before = tree.stats();
    assert!(before.posting_cells > 0);
    assert_eq!(tree.put(b"k", 3), Ok(true)); // inside the first posting list
    assert_eq!(tree.counters.posting_swaps, 1);
    let after = tree.stats();
    assert_eq!(before.posting_cells, after.posting_cells);
    assert_eq!(before.leaf_cells + 1, after.leaf_cells); // the evicted TID became a plain cell
    tree.validate().unwrap();
    let tids = tree.get(b"k");
    assert_eq!(tids.len() as Tid, i / 2 + 1);
    assert_eq!(tids[..5], [0, 2, 3, 4, 6]);
}

#[test]
fn range_is_ordered_by_key_and_tid_and_respects_the_upper_bound() {
    let mut tree = Tree::new(config(128, true, true));
    for (i, w) in ["d", "b", "a", "c", "b", "d", "b"].iter().enumerate() {
        tree.put(w.as_bytes(), 10 - i as Tid).unwrap();
    }
    let got: String =
        tree.range(b"b", Some(b"d")).map(|(k, tid)| format!("{}@{tid} ", String::from_utf8_lossy(k))).collect();
    assert_eq!(got, "b@4 b@6 b@9 c@7 ");
}

/// The key for model-test index `i`: fixed-width digits first, so byte order
/// equals index order, then a tail of varying length so that prefixes vary.
fn model_key(i: u64) -> Vec<u8> {
    format!("k{i:02}{}", &"xxx"[..(i % 4) as usize]).into_bytes()
}

fn model_run(cfg: Config, seed: u64, ops: usize) {
    let mut tree = Tree::new(cfg);
    // Oracle: an ordered set of (key index, tid).
    let mut oracle: BTreeSet<(u64, Tid)> = BTreeSet::new();
    let mut rng = SplitMix64::new(seed);
    for n in 0..ops {
        let ki = rng.below(40);
        let tid = rng.below(64);
        let key = model_key(ki);
        let present = oracle.contains(&(ki, tid));
        match rng.below(10) {
            0..=5 => {
                assert_eq!(tree.put(&key, tid), Ok(!present));
                oracle.insert((ki, tid));
            }
            6..=7 => {
                assert_eq!(tree.delete(&key, tid), present);
                oracle.remove(&(ki, tid));
            }
            8 => assert_eq!(tree.contains(&key, tid), present),
            _ => {
                // get: every TID of the key, in order.
                let want: Vec<Tid> = oracle.range((ki, 0)..(ki + 1, 0)).map(|&(_, t)| t).collect();
                assert_eq!(tree.get(&key), want);
            }
        }
        assert_eq!(tree.count, oracle.len());
        if n % 64 == 0 {
            tree.validate().unwrap();
        }
    }
    tree.validate().unwrap();
    // Full scan equals the oracle.
    let scan: Vec<(Vec<u8>, Tid)> = tree.range(b"", None).map(|(k, t)| (k.to_vec(), t)).collect();
    let want: Vec<(Vec<u8>, Tid)> = oracle.iter().map(|&(ki, t)| (model_key(ki), t)).collect();
    assert_eq!(scan, want);
}

#[test]
fn model_test_against_an_ordered_set_oracle_all_four_configurations() {
    for truncate in [false, true] {
        for dedup in [false, true] {
            model_run(config(128, truncate, dedup), 17, 6000);
            model_run(config(256, truncate, dedup), 1717, 6000);
        }
    }
}

fn build_small(max_pages: usize) -> Result<Tree, Error> {
    let mut tree = Tree::new(config(128, true, true));
    tree.max_pages = max_pages;
    for i in 0..70 {
        tree.put(&model_key((i * 7) % 20), i)?;
    }
    Ok(tree)
}

#[test]
fn page_budget_exhausted_anywhere_during_a_build_error_returned() {
    let pages = build_small(usize::MAX).unwrap().pages.len();
    assert!(pages > 3);
    for budget in 1..pages {
        assert_eq!(build_small(budget).err(), Some(Error::OutOfPages));
    }
    build_small(pages).unwrap().validate().unwrap();
}

#[test]
fn a_put_that_fails_for_lack_of_pages_leaves_the_tree_exactly_as_it_was() {
    let mut tree = Tree::new(config(128, true, false));
    let mut saw_root_split_failure = false;
    for i in 0..400u64 {
        let key = model_key((i * 13) % 40);
        let before = tree.stats();
        // Allow no new page, then one, then two ... until the put gets through.
        let mut k = 0;
        loop {
            tree.max_pages = tree.pages.len() + k;
            match tree.put(&key, i) {
                Ok(inserted) => {
                    assert!(inserted);
                    break;
                }
                Err(err) => {
                    assert_eq!(err, Error::OutOfPages);
                    tree.validate().unwrap();
                    assert_eq!(tree.stats(), before);
                    assert!(!tree.contains(&key, i));
                    if k >= 2 {
                        saw_root_split_failure = true; // leaf + internal split done, root page denied
                    }
                }
            }
            k += 1;
        }
    }
    tree.validate().unwrap();
    assert!(tree.stats().height >= 3);
    assert!(saw_root_split_failure);
}

#[test]
fn deletes_empty_a_leaf_but_never_merge_it_away() {
    let mut tree = Tree::new(config(128, true, true));
    for i in 0..5000 {
        assert_eq!(tree.put(b"churn", i), Ok(true));
        assert!(tree.delete(b"churn", i));
    }
    assert_eq!(tree.pages.len(), 1);
    assert!(tree.pages[0].cells.is_empty());
    tree.validate().unwrap();
}
