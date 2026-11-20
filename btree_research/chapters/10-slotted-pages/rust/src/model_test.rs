//! Model test: the shared operation stream is applied to one SlottedPage and
//! to the oracle from ops.rs (a sorted array of u64 pairs). After every
//! operation the page must validate and answer exactly like the oracle.
//!
//! A page is finite, so `put` may fail with PageFull. The test then checks
//! that the refusal was justified and that the page did not change, and does
//! not apply the put to the oracle.
use crate::demo::fnv1a64;
use crate::ops::{Config, Op, OpStream, Oracle, Weights};
use crate::slotted_page::{self as sp, PageError, SlottedPage};
use crate::workload::{self, MAX_KEY_LEN, MAX_VALUE_LEN};

#[derive(Default)]
struct Coverage {
    page_full: usize,
    replaced: usize,
    saw_free_blocks: usize,
    saw_fragments: usize,
    compactions: usize,
}

fn run_model(config: Config) -> Coverage {
    run_model_reserved(config, 0).0
}

/// The tail pattern is written once, right after `init_reserved`; the page
/// must leave it alone through every operation.
const TAIL_PATTERN: u8 = 0xA5;

/// Also returns the FNV-1a hash of the final page image (reserved tail
/// included).
fn run_model_reserved(config: Config, reserved: u8) -> (Coverage, u64) {
    let mut buf = [0u8; sp::PAGE_SIZE];
    let mut page = SlottedPage::init_reserved(&mut buf, reserved);
    page.reserved_area_mut().fill(TAIL_PATTERN);
    let mut oracle = Oracle::new();
    let mut cov = Coverage::default();

    let mut kb = [0u8; MAX_KEY_LEN];
    let mut vb = [0u8; MAX_VALUE_LEN];
    for op in OpStream::new(config) {
        match op {
            Op::Put { key, value } => {
                let k = workload::key_bytes(&mut kb, key);
                let v = workload::value_bytes(&mut vb, value);
                let before = page.stats();
                let snapshot = *page.bytes();
                // What the put needs versus what the page can give back.
                let need = sp::cell_size(k.len(), v.len());
                let old = page.get(k).map(|old_v| sp::cell_size(k.len(), old_v.len()));
                let available = match old {
                    Some(o) => before.free_bytes + o,
                    None => before.free_bytes.saturating_sub(sp::SLOT_SIZE),
                };
                match page.put(k, v) {
                    Ok(()) => {
                        assert!(need <= available);
                        oracle.put(key, value);
                        cov.replaced += usize::from(old.is_some());
                        // A put that had to compact leaves no free block
                        // behind, although there were some before.
                        let after = page.stats();
                        if before.free_block_count > 0
                            && after.free_block_count == 0
                            && after.frag_bytes == 0
                            && before.gap < need + sp::SLOT_SIZE
                        {
                            cov.compactions += 1;
                        }
                    }
                    Err(err) => {
                        assert_eq!(err, PageError::PageFull);
                        assert!(need > available);
                        assert_eq!(page.bytes(), &snapshot);
                        cov.page_full += 1;
                    }
                }
            }
            Op::Delete { key } => {
                let expected = oracle.delete(key).is_some();
                assert_eq!(page.delete(workload::key_bytes(&mut kb, key)), expected);
            }
            Op::Get { key } => {
                let got = page.get(workload::key_bytes(&mut kb, key));
                let expected = oracle
                    .get(key)
                    .map(|value| workload::value_bytes(&mut vb, value));
                assert_eq!(got, expected);
            }
            Op::Range { lo, hi } => {
                // A range scan on a sorted page: lower bound, then walk slots.
                let mut i = page.search(workload::key_bytes(&mut kb, lo)).index;
                for entry in oracle.range(lo, hi) {
                    assert_eq!(page.key(i), workload::key_bytes(&mut kb, entry.key));
                    assert_eq!(page.value(i), workload::value_bytes(&mut vb, entry.value));
                    i += 1;
                }
                assert_eq!(i, page.search(workload::key_bytes(&mut kb, hi)).index);
            }
        }
        page.validate().unwrap();
        assert!(page.reserved_area().iter().all(|&b| b == TAIL_PATTERN));
        assert_eq!(page.count(), oracle.len());
        let s = page.stats();
        cov.saw_free_blocks += usize::from(s.free_block_count > 0);
        cov.saw_fragments += usize::from(s.frag_bytes > 0);
    }
    let hash = fnv1a64(page.bytes());
    (cov, hash)
}

fn config(seed: u64, key_space: u64) -> Config {
    Config {
        seed,
        count: 20_000,
        key_space,
        weights: Weights::default(),
    }
}

#[test]
fn model_20000_operations_page_mostly_full() {
    // 300 possible keys of about 36 bytes each do not fit in 4 KiB, so the
    // page fills up and every free-space path is taken many times.
    let cov = run_model(config(10, 300));
    // Coverage asserts: a model test that never reaches the hard paths
    // proves nothing about them.
    assert!(cov.page_full > 0);
    assert!(cov.replaced > 0);
    assert!(cov.saw_free_blocks > 0);
    assert!(cov.saw_fragments > 0);
    assert!(cov.compactions > 0);
}

#[test]
fn model_small_key_space_page_never_fills_heavy_overwrite_and_delete() {
    let cov = run_model(config(11, 40));
    assert_eq!(cov.page_full, 0);
    assert!(cov.replaced > 0);
    assert!(cov.saw_fragments > 0);
}

#[test]
fn model_delete_heavy_the_page_empties_again_and_again() {
    run_model(Config {
        seed: 12,
        count: 20_000,
        key_space: 16,
        weights: Weights {
            put: 2,
            delete: 4,
            get: 1,
            range: 1,
        },
    });
}

#[test]
fn model_a_reserved_tail_of_4_or_32_bytes_is_never_touched_zig_and_rust_build_the_same_image() {
    // Same stream as the first test, on a page that ends 4 (a CRC-32) or 32
    // bytes early. The page is still mostly full, so every path runs next
    // to the tail. The hashes are pinned in both languages: equal constants
    // mean byte-identical pages, tail pattern included.
    let (cov, hash) = run_model_reserved(config(10, 300), 4);
    assert!(cov.page_full > 0 && cov.saw_fragments > 0 && cov.compactions > 0);
    assert_eq!(hash, 0xeb85adf9ab8de35f);
    let (cov, hash) = run_model_reserved(config(10, 300), 32);
    assert!(cov.page_full > 0 && cov.saw_fragments > 0 && cov.compactions > 0);
    assert_eq!(hash, 0x35c30344813275d9);
    // reserved = 0 through the same function is the page of the first test.
    let short = Config {
        count: 3000,
        ..config(10, 300)
    };
    let (_, hash) = run_model_reserved(short, 0);
    assert_eq!(hash, 0x3b3ad4029bd5294a); // the last line of expected_output.txt
    // The visualization's JS model replays this one as a self-test.
    let (_, hash) = run_model_reserved(short, 4);
    assert_eq!(hash, 0x5f6f7576b6c3ed44);
}
