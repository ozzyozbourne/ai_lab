//! The fixed scenario printed by `cargo run` (and by the Zig twin).
//! Everything is deterministic: keys come from SplitMix64 with fixed seeds.
use crate::art::{Art, KIND_COUNT, KIND_NAMES};
use crate::hash_index::HashIndex;
use crate::keys::{self, Entry, Lookup};
use crate::prng::SplitMix64;
use crate::sorted_index::{OwnedEntry, SortedIndex};
use std::fmt::Write;

// `write!` into a String cannot fail; this keeps the call sites short.
macro_rules! out {
    ($dst:expr, $($arg:tt)*) => { write!($dst, $($arg)*).expect("writing to a String cannot fail") };
}

/// Build the whole program output.
pub fn run() -> String {
    let mut w = String::new();
    path_compression(&mut w);
    four_layouts(&mut w);
    dense_and_sparse(&mut w);
    three_indexes(&mut w);
    w
}

fn print_census(w: &mut String, tree: &Art) {
    let c = tree.census();
    out!(
        w,
        "nodes: prefix={} node4={} node16={} node48={} node256={}; leaves={}; longest path={} nodes\n",
        c.nodes[0],
        c.nodes[1],
        c.nodes[2],
        c.nodes[3],
        c.nodes[4],
        c.leaves,
        c.max_path
    );
}

/// Section 1: the classic radix-tree words. Each string is encoded with a
/// 0x00 terminator, which shows up in the dumps as \x00.
fn path_compression(w: &mut String) {
    w.push_str("== 1. Path compression and prefix splits ==\n");
    let mut tree = Art::new();
    let words = ["romane", "romanus", "romulus", "rubens", "ruber", "rubicon", "rubicundus"];
    for (word, value) in words.into_iter().zip(1u64..) {
        tree.put(&keys::encode_str(word.as_bytes()), value).expect("keys are prefix-free");
        tree.validate().expect("valid tree");
        // Show the tree after each of the first three keys, then at the end.
        if value <= 3 || value == words.len() as u64 {
            if value <= 3 {
                out!(w, "put \"{word}\" = {value}\n");
            } else {
                w.push_str("put \"rubens\" = 4, \"ruber\" = 5, \"rubicon\" = 6, \"rubicundus\" = 7\n");
            }
            w.push_str(&tree.dump());
        }
    }
    print_census(w, &tree);
    out!(w, "prefix splits: {}\n", tree.prefix_splits);

    w.push_str("keys in order:");
    let mut it = tree.iterator();
    while let Some(e) = it.next() {
        w.push(' ');
        keys::write_bytes(w, &e.key[..e.key.len() - 1]); // drop the terminator
    }
    w.push('\n');

    let lo = "rube"; // a raw byte bound: no terminator, not a stored key
    it.seek(lo.as_bytes());
    let first = it.next().expect("rubens follows");
    out!(w, "first key >= \"{lo}\": ");
    keys::write_bytes(w, &first.key[..first.key.len() - 1]);
    out!(w, " = {}\n\n", first.value);
}

/// Section 2: 256 two-byte keys 'k', b. All of them branch at the same node
/// (below the prefix "k"), which therefore has to take every layout in turn.
fn four_layouts(w: &mut String) {
    w.push_str("== 2. One node through four layouts ==\n");
    let mut tree = Art::new();
    let mut bytes: Vec<u64> = (0..256).collect();
    SplitMix64::new(28).shuffle(&mut bytes);

    w.push_str("  keys  layout   slots used/reserved  event\n");
    let mut last_kind: Option<usize> = None;
    for (&b, n) in bytes.iter().zip(1u64..) {
        tree.put(&[b'k', b as u8], n).expect("keys are prefix-free");
        let c = tree.census();
        // Exactly one inner node exists; find which layout it has now.
        let kind = (1..KIND_COUNT).rfind(|&k| c.nodes[k] == 1);
        if n == 1 || kind != last_kind || n == 256 {
            out!(w, "  {:>4}  {:<7}  {:>3}/{:<3}", n, kind.map_or("(none)", |k| KIND_NAMES[k]), c.slots_used, c.slots_allocated);
            match (last_kind, kind) {
                (_, None) => w.push_str("              one key: a prefix chain, no inner node yet\n"),
                (None, Some(_)) => w.push_str("              second key splits the prefix\n"),
                (Some(from), Some(to)) if from != to => {
                    out!(
                        w,
                        "              {} was full: copied into a {} for byte 0x{:02x}\n",
                        KIND_NAMES[from],
                        KIND_NAMES[to],
                        b
                    );
                }
                _ => w.push_str("              every byte has its own slot\n"),
            }
            last_kind = kind;
        }
    }
    tree.validate().expect("valid tree");
    out!(w, "grow steps: node4->node16 {}, node16->node48 {}, node48->node256 {}\n", tree.grows[0], tree.grows[1], tree.grows[2]);
    w.push_str("pool     created  live\n");
    let (created, live) = (tree.pool_created(), tree.pool_live());
    for k in 0..KIND_COUNT {
        out!(w, "{:<8} {:>7}  {:>4}\n", KIND_NAMES[k], created[k], live[k]);
    }
    w.push('\n');
}

/// Section 3: the same number of 8-byte integer keys, once dense (0..999) and
/// once spread over the whole u64 range.
fn dense_and_sparse(w: &mut String) {
    w.push_str("== 3. Dense and sparse integer keys (1000 each, 8 bytes big-endian) ==\n");
    w.push_str(
        "         prefix  node4  node16  node48  node256  slots used/reserved  longest path  nodes visited by 1000 gets\n",
    );
    let mut rng = SplitMix64::new(2828);
    for (which, name) in ["dense", "sparse"].into_iter().enumerate() {
        let mut tree = Art::new();
        let stored: Vec<u64> = (0..1000).map(|i| if which == 0 { i } else { rng.next_u64() }).collect();
        for (&k, i) in stored.iter().zip(0u64..) {
            tree.put(&keys::encode_u64(k), i).expect("fixed-width keys are prefix-free");
        }
        tree.validate().expect("valid tree");
        let mut steps = 0u64;
        for (&k, i) in stored.iter().zip(0u64..) {
            let found = tree.lookup(&keys::encode_u64(k));
            assert_eq!(found.value, Some(i));
            steps += u64::from(found.steps);
        }
        let c = tree.census();
        out!(
            w,
            "{:<7}  {:>6}  {:>5}  {:>6}  {:>6}  {:>7}  {:>9}/{:<9}  {:>12}  {:>26}\n",
            name,
            c.nodes[0],
            c.nodes[1],
            c.nodes[2],
            c.nodes[3],
            c.nodes[4],
            c.slots_used,
            c.slots_allocated,
            c.max_path,
            steps
        );
    }
    w.push('\n');
}

/// Collect values from the ART: keys >= lo that are < hi (if given) and start
/// with `prefix` (if given). The iterator yields them in key order.
fn art_collect(tree: &Art, lo: &[u8], hi: Option<&[u8]>, prefix: Option<&[u8]>) -> Vec<u64> {
    let mut out = Vec::new();
    let mut it = tree.iterator();
    it.seek(lo);
    while let Some(e) = it.next() {
        if hi.is_some_and(|h| e.key >= h) || prefix.is_some_and(|p| !e.key.starts_with(p)) {
            break;
        }
        out.push(e.value);
    }
    out
}

fn same_values(entries: &[OwnedEntry], values: &[u64]) -> bool {
    entries.len() == values.len() && entries.iter().zip(values).all(|(e, &v)| e.value == v)
}

fn is_sorted(entries: &[Entry<'_>]) -> bool {
    entries.windows(2).all(|pair| pair[0].key < pair[1].key)
}

/// One ordered query (a byte range [lo, hi)) answered by all three indexes.
fn compare_query(w: &mut String, tree: &Art, hash: &HashIndex, want: &[OwnedEntry], lo: &[u8], hi: &[u8], prefix: Option<&[u8]>) {
    out!(w, "  sorted array  {:>3} entries in key order (a slice between two binary searches)\n", want.len());

    let values = art_collect(tree, lo, if prefix.is_none() { Some(hi) } else { None }, prefix);
    out!(
        w,
        "  art           {:>3} entries in key order (seek, then iterate); same as sorted: {}\n",
        values.len(),
        same_values(want, &values)
    );

    let mut found = Vec::new();
    let inspected = hash.scan_range(lo, Some(hi), &mut found);
    let ordered_before = is_sorted(&found);
    found.sort_by_key(|e| e.key);
    let values: Vec<u64> = found.iter().map(|e| e.value).collect();
    out!(
        w,
        "  hash index    {:>3} entries after inspecting all {} slots; in key order: {}; same as sorted after sorting: {}\n",
        found.len(),
        inspected,
        ordered_before,
        same_values(want, &values)
    );
}

/// Section 4: one data set, three indexes, four kinds of question.
fn three_indexes(w: &mut String) {
    w.push_str("== 4. Same data in a sorted array, an ART and a hash index ==\n");
    let mut sorted = SortedIndex::new();
    let mut tree = Art::new();
    let mut hash = HashIndex::new();

    // Keys look like "cat/0042": a tenant name, a slash, a 4-digit id.
    let tenants = ["ant", "bee", "cat", "dog", "eel", "fox"];
    let mut rng = SplitMix64::new(4);
    for i in 0..600 {
        let tenant = tenants[rng.below(tenants.len() as u64) as usize];
        let id = rng.below(10_000);
        let key = keys::encode_str(format!("{tenant}/{id:04}").as_bytes());
        let a = sorted.put(&key, i);
        let b = tree.put(&key, i).expect("keys are prefix-free");
        let c = hash.put(&key, i);
        assert!(a == b && b == c);
    }
    sorted.validate().expect("valid sorted index");
    tree.validate().expect("valid tree");
    hash.validate().expect("valid hash index");
    out!(w, "600 puts, {} distinct keys such as \"cat/0042\"; hash table capacity {}\n", sorted.len(), hash.capacity());
    print_census(w, &tree);

    // Point lookups: every stored key, then 300 keys that cannot exist
    // (5-digit ids).
    let mut steps = [0u64; 3];
    let mut found = [0usize; 3];
    let lookup_all = |key: &[u8]| -> [Lookup; 3] { [sorted.lookup(key), tree.lookup(key), hash.lookup(key)] };
    for e in sorted.entries() {
        for (k, r) in lookup_all(&e.key).into_iter().enumerate() {
            steps[k] += u64::from(r.steps);
            if r.value == Some(e.value) {
                found[k] += 1;
            }
        }
    }
    let hits = sorted.len();
    for _ in 0..300 {
        let tenant = tenants[rng.below(tenants.len() as u64) as usize];
        let key = keys::encode_str(format!("{tenant}/{}", rng.range(10_000, 100_000)).as_bytes());
        for (k, r) in lookup_all(&key).into_iter().enumerate() {
            steps[k] += u64::from(r.steps);
            if r.value.is_some() {
                found[k] += 1;
            }
        }
    }
    out!(w, "\npoint lookups ({hits} hits, 300 misses)\n");
    w.push_str("                found  steps  unit of a step\n");
    let names = ["sorted array", "art", "hash index"];
    let units = ["whole-key comparison", "node visited", "slot probed"];
    for k in 0..3 {
        out!(w, "  {:<12}  {:>5}  {:>5}  {}\n", names[k], found[k], steps[k], units[k]);
    }

    // Range and prefix bounds are raw bytes without the terminator, so they
    // are bounds, not keys.
    w.push_str("\nrange \"bee/2000\" <= key < \"bee/4000\"\n");
    compare_query(w, &tree, &hash, sorted.range(b"bee/2000", b"bee/4000"), b"bee/2000", b"bee/4000", None);

    // A prefix is the range [prefix, prefix with its last byte + 1).
    w.push_str("\nprefix \"cat/\"\n");
    compare_query(w, &tree, &hash, sorted.prefix_range(b"cat/"), b"cat/", b"cat0", Some(b"cat/"));

    w.push_str("\nfirst 4 keys\n");
    w.push_str("  sorted array ");
    for e in &sorted.entries()[..4] {
        w.push(' ');
        keys::write_bytes(w, &e.key[..e.key.len() - 1]);
    }
    w.push_str("\n  art          ");
    let mut it = tree.iterator();
    for _ in 0..4 {
        let e = it.next().expect("at least four keys");
        w.push(' ');
        keys::write_bytes(w, &e.key[..e.key.len() - 1]);
    }
    w.push_str("\n  hash index   ");
    for slot in hash.slots().iter().flatten().take(4) {
        w.push(' ');
        keys::write_bytes(w, &slot.key[..slot.key.len() - 1]);
    }
    w.push_str("  (slot order)\n");

    w.push_str(concat!(
        "\n",
        "what each index can answer\n",
        "                point  range        prefix       ordered scan\n",
        "  sorted array  yes    yes          yes          yes\n",
        "  art           yes    yes          yes          yes\n",
        "  hash index    yes    scan + sort  scan + sort  scan + sort\n",
    ));
}

#[cfg(test)]
mod tests {
    #[test]
    fn run_prints_exactly_expected_output_txt() {
        assert_eq!(super::run(), include_str!("../../expected_output.txt"));
    }
}
