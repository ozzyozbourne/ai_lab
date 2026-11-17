//! Chapter 01: why B-trees.
//!
//! `cargo run` prints a fixed, deterministic scenario that compares three
//! ways of keeping keys findable (one sorted array, a binary search tree, and
//! wide nodes) by the measure that matters for a database: page reads.
//! The output is exactly ../expected_output.txt; the Zig program prints the
//! same bytes.

use ch01_why_btrees::bst::{Bst, PageAligned};
use ch01_why_btrees::cost::{ENTRIES_PER_PAGE, Entry, PAGE_SIZE, Trace};
use ch01_why_btrees::prng::SplitMix64;
use ch01_why_btrees::sorted_array::SortedArrayMap;
use ch01_why_btrees::{height, wide};
use std::fmt::Write;

/// The guide's canonical keys (chapters 03 to 08 insert the same sequence).
const CANONICAL: [u64; 12] = [10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15];

/// Why a step of the scenario could not be completed.
type Failure = Box<dyn std::error::Error>;

fn main() -> Result<(), Failure> {
    print!("{}", report()?);
    Ok(())
}

/// Everything the program prints, as one string, so that a test can compare
/// it with expected_output.txt.
fn report() -> Result<String, Failure> {
    let mut w = String::new();
    writeln!(w, "Chapter 01: why B-trees")?;
    writeln!(
        w,
        "Cost model: count page reads ({PAGE_SIZE}-byte pages, {ENTRIES_PER_PAGE} entries each), not comparisons."
    )?;
    hand_example(&mut w)?;
    where_the_bytes_live(&mut w)?;
    race(&mut w)?;
    price_of_inserts(&mut w)?;
    height_table(&mut w)?;
    Ok(w)
}

// ---- 1 --------------------------------------------------------------------

fn hand_example(w: &mut String) -> Result<(), Failure> {
    writeln!(w, "\n== 1. Hand example: 12 keys ==")?;
    write!(w, "insert order:")?;
    for k in CANONICAL {
        write!(w, " {k}")?;
    }
    writeln!(w)?;

    // Sorted array. Zig puts these 12 entries in a stack buffer; a Vec always
    // lives on the heap, so the limit of 16 entries plays the buffer's role.
    let mut array = SortedArrayMap::with_limit(16);
    for k in CANONICAL {
        array.put(k, k * 10).map_err(|_| "sorted array is full")?;
    }
    array.validate()?;
    write!(w, "sorted array:")?;
    for e in array.items() {
        write!(w, " {}", e.key)?;
    }
    writeln!(w, "\n  entries shifted by the 12 puts: {}", array.moves)?;
    let mut trace = Trace::new();
    array.get_traced(17, &mut trace);
    writeln!(
        w,
        "  get(17): {} comparisons, {} page read",
        trace.comparisons, trace.page_reads
    )?;

    // BST, same insert order.
    let mut tree: Bst = Bst::new();
    for k in CANONICAL {
        tree.put(k, k * 10).map_err(|_| "out of nodes")?;
    }
    tree.validate()?;
    let mut trace = Trace::new();
    tree.get_traced(17, &mut trace);
    writeln!(w, "BST, same insert order: height {}", tree.height())?;
    writeln!(
        w,
        "  get(17): {} comparisons, {} page reads",
        trace.comparisons, trace.page_reads
    )?;

    // BST fed the keys in ascending order: a linked list.
    let mut chain: Bst = Bst::new();
    for e in array.items() {
        chain.put(e.key, e.value).map_err(|_| "out of nodes")?;
    }
    let mut trace = Trace::new();
    chain.get_traced(30, &mut trace);
    writeln!(w, "BST, ascending insert order: height {}", chain.height())?;
    writeln!(
        w,
        "  get(30): {} comparisons, {} page reads",
        trace.comparisons, trace.page_reads
    )?;

    // Wide nodes of order 4 laid over the sorted array.
    let mut trace = Trace::new();
    wide::get_traced(array.items(), 4, 17, &mut trace);
    writeln!(
        w,
        "wide nodes, M = 4 (at most 3 keys per node): height {}",
        height::min_height(array.len() as u64, 4)
    )?;
    writeln!(
        w,
        "  get(17): {} comparisons, {} page reads",
        trace.comparisons, trace.page_reads
    )?;
    Ok(())
}

// ---- 2 --------------------------------------------------------------------

fn where_the_bytes_live(w: &mut String) -> Result<(), Failure> {
    writeln!(w, "\n== 2. Where the bytes live ==")?;

    // A sorted array is one contiguous block. With room for 16 entries (the
    // 256-byte stack buffer of the Zig version) it can grow only that far.
    let buffer_len = 16 * size_of::<Entry>();
    let mut array = SortedArrayMap::with_limit(buffer_len / size_of::<Entry>());
    let mut fitted = 0;
    let mut failed_at = 0;
    for i in 1..40 {
        if array.put(i, i).is_err() {
            failed_at = i;
            break;
        }
        fitted += 1;
    }
    writeln!(
        w,
        "sorted array in a {buffer_len}-byte stack buffer: {fitted} entries fit, put #{failed_at} fails, len stays {}",
        array.len()
    )?;
    writeln!(
        w,
        "  12 entries are {} contiguous bytes: less than one page",
        12 * size_of::<Entry>()
    )?;

    // A tree node can be anywhere. `Bst<PageAligned>` makes the worst case
    // real: every node is a page-aligned, page-sized allocation, so each
    // pointer hop of a lookup lands on a different page of memory.
    let mut tree: Bst<PageAligned> = Bst::new();
    for k in CANONICAL {
        tree.put(k, k * 10).map_err(|_| "out of nodes")?;
    }
    let mut trace = Trace::new();
    tree.get_traced(17, &mut trace);
    writeln!(
        w,
        "BST with one page per node: {} nodes; get(17) visits {} nodes on {} distinct pages of memory",
        tree.len(),
        trace.page_reads,
        tree.pages_on_path(17)
    )?;
    Ok(())
}

// ---- 3 --------------------------------------------------------------------

const RACE_KEYS: u64 = 100_000;
const RACE_LOOKUPS: u64 = 1000;

/// Sum and maximum of one counter over many lookups.
#[derive(Default)]
struct Tally {
    total: u64,
    max: u64,
}

impl Tally {
    fn add(&mut self, x: u64) {
        self.total += x;
        self.max = self.max.max(x);
    }
}

#[derive(Default)]
struct Lane {
    comparisons: Tally,
    page_reads: Tally,
}

impl Lane {
    fn add(&mut self, trace: &Trace) {
        self.comparisons.add(trace.comparisons);
        self.page_reads.add(trace.page_reads);
    }
}

fn race(w: &mut String) -> Result<(), Failure> {
    writeln!(
        w,
        "\n== 3. Race: {RACE_KEYS} keys, {RACE_LOOKUPS} lookups =="
    )?;

    // Keys 10, 20, ..., 1000000 in a random order.
    let mut keys: Vec<u64> = (0..RACE_KEYS).map(|i| (i + 1) * 10).collect();
    let mut rng = SplitMix64::new(2024);
    rng.shuffle(&mut keys);

    let unsorted: Vec<Entry> = keys
        .iter()
        .map(|&k| Entry {
            key: k,
            value: k + 1,
        })
        .collect();

    let array = SortedArrayMap::from_entries(&unsorted);
    let mut tree: Bst = Bst::new();
    for e in &unsorted {
        tree.put(e.key, e.value).map_err(|_| "out of nodes")?;
    }
    tree.validate()?;

    // The order of a node that fills one page: 170 entries + 171 pointers.
    let m = height::order_for_page(
        PAGE_SIZE as u64,
        size_of::<Entry>() as u64,
        size_of::<u64>() as u64,
    );

    let mut array_lane = Lane::default();
    let mut tree_lane = Lane::default();
    let mut wide_lane = Lane::default();
    let mut found = 0;
    for _ in 0..RACE_LOOKUPS {
        // Half of the lookups ask for a key that exists.
        let key = if rng.chance(1, 2) {
            (rng.below(RACE_KEYS) + 1) * 10
        } else {
            rng.below(RACE_KEYS * 10 + 10)
        };
        let mut a = Trace::new();
        let mut t = Trace::new();
        let mut b = Trace::new();
        let from_array = array.get_traced(key, &mut a);
        let from_tree = tree.get_traced(key, &mut t);
        let from_wide = wide::get_traced(array.items(), m as usize, key, &mut b);
        // Three structures, one answer.
        if from_array != from_tree || from_array != from_wide {
            return Err("structures disagree".into());
        }
        if from_array.is_some() {
            found += 1;
        }
        array_lane.add(&a);
        tree_lane.add(&t);
        wide_lane.add(&b);
    }
    writeln!(w, "lookups that found their key: {found}")?;
    writeln!(
        w,
        "                               comparisons      page reads"
    )?;
    writeln!(
        w,
        "structure                      avg      max     avg      max"
    )?;
    print_lane(w, "sorted array, 256 per page", &array_lane)?;
    print_lane(w, "BST, random insert order", &tree_lane)?;
    print_lane(w, "wide nodes, M = 171", &wide_lane)?;
    writeln!(
        w,
        "heights: BST {}, wide nodes {}; the sorted array spans {} pages",
        tree.height(),
        height::min_height(RACE_KEYS, m),
        RACE_KEYS.div_ceil(ENTRIES_PER_PAGE as u64)
    )?;

    // The same BST fed sorted keys is hopeless; 2000 keys are enough to see it.
    let mut chain: Bst = Bst::new();
    for i in 0..2000 {
        chain.put((i + 1) * 10, i).map_err(|_| "out of nodes")?;
    }
    let mut worst = Trace::new();
    chain.get_traced(2000 * 10, &mut worst);
    writeln!(
        w,
        "BST, 2000 keys in ascending order: height {}, get(largest) reads {} pages",
        chain.height(),
        worst.page_reads
    )?;
    Ok(())
}

fn print_lane(w: &mut String, name: &str, lane: &Lane) -> Result<(), Failure> {
    write!(w, "{name:<28}")?;
    print_average(w, lane.comparisons.total)?;
    write!(w, " {:>8}", lane.comparisons.max)?;
    print_average(w, lane.page_reads.total)?;
    writeln!(w, " {:>8}", lane.page_reads.max)?;
    Ok(())
}

/// Print total / RACE_LOOKUPS with two decimals, using integers only so that
/// Zig and Rust cannot round differently.
fn print_average(w: &mut String, total: u64) -> Result<(), Failure> {
    let hundredths = total * 100 / RACE_LOOKUPS;
    write!(w, " {:>5}.{:02}", hundredths / 100, hundredths % 100)?;
    Ok(())
}

// ---- 4 --------------------------------------------------------------------

fn price_of_inserts(w: &mut String) -> Result<(), Failure> {
    writeln!(
        w,
        "\n== 4. The price of one flat array: a single put into {RACE_KEYS} keys =="
    )?;
    let unsorted: Vec<Entry> = (0..RACE_KEYS)
        .map(|i| Entry {
            key: (i + 1) * 10,
            value: i,
        })
        .collect();
    let mut array = SortedArrayMap::from_entries(&unsorted);

    let cases = [
        ("larger than every key", RACE_KEYS * 10 + 5),
        ("in the middle", RACE_KEYS * 5 + 5),
        ("smaller than every key", 5),
    ];
    for (name, key) in cases {
        let moves_before = array.moves;
        let writes_before = array.page_writes;
        array.put(key, 0).map_err(|_| "sorted array is full")?;
        writeln!(
            w,
            "sorted array, new key {name:<23}: {:>6} entries shifted, {:>3} pages rewritten",
            array.moves - moves_before,
            array.page_writes - writes_before
        )?;
        array.delete(key); // back to exactly RACE_KEYS entries
    }
    writeln!(
        w,
        "BST, any new key: 1 node written, 1 pointer changed (after the page reads to find the place)"
    )?;

    // A one-level fix: cut the array into page-sized chunks and keep a
    // directory with one slot per chunk. Inserting now shifts one chunk only,
    // but the directory is itself a sorted array with one slot per page.
    writeln!(
        w,
        "one level of chunks plus a directory (8 bytes per chunk):"
    )?;
    writeln!(w, "          keys       chunks  directory pages")?;
    let mut n: u64 = 1000;
    while n <= 1_000_000_000_000 {
        let chunks = n.div_ceil(ENTRIES_PER_PAGE as u64);
        let directory_pages = (chunks * 8).div_ceil(PAGE_SIZE as u64);
        writeln!(w, "{n:>14} {chunks:>12} {directory_pages:>16}")?;
        n *= 1000;
    }
    Ok(())
}

// ---- 5 --------------------------------------------------------------------

fn height_table(w: &mut String) -> Result<(), Failure> {
    writeln!(w, "\n== 5. Height calculator: page reads per lookup ==")?;
    writeln!(
        w,
        "          keys   binary best   M = 4 best   worst   M = 171 best   worst"
    )?;
    let mut n: u64 = 1000;
    while n <= 1_000_000_000_000 {
        writeln!(
            w,
            "{n:>14} {:>13} {:>12} {:>7} {:>14} {:>7}",
            height::min_height(n, 2),
            height::min_height(n, 4),
            height::max_height(n, 4),
            height::min_height(n, 171),
            height::max_height(n, 171)
        )?;
        n *= 1000;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    #[test]
    fn run_prints_exactly_expected_output_txt() {
        assert_eq!(
            super::report().unwrap(),
            include_str!("../../expected_output.txt")
        );
    }
}
