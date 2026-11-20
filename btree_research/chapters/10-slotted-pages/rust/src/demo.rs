//! The fixed scenario printed by `cargo run`. It writes to any `io::Write`,
//! so a test can capture it and compare it with ../expected_output.txt (the
//! Zig program prints the same bytes).
use std::io::{self, Write};

use crate::ops::{Config, Op, OpStream, Weights};
use crate::slotted_page::{self as sp, SlottedPage};
use crate::workload;

pub fn run(w: &mut dyn Write) -> io::Result<()> {
    part_one(w)?;
    part_two(w)?;
    part_three(w)
}

enum Step {
    Put(&'static str, &'static str),
    Delete(&'static str),
    Compact,
}

/// One page, one operation at a time: the worked example of the README and
/// the default animation of the visualization.
fn part_one(w: &mut dyn Write) -> io::Result<()> {
    let mut buf = [0u8; sp::PAGE_SIZE];
    let mut page = SlottedPage::init(&mut buf);
    writeln!(w, "== Part 1: one page, step by step ==")?;
    writeln!(w, "init")?;
    describe(w, &page)?;

    let steps = [
        Step::Put("mango", "yellow"),
        Step::Put("apple", "red"),
        Step::Put("kiwi", "green"),
        Step::Put("cherry", "dark red"),
        Step::Put("fig", "purple"),
        Step::Delete("kiwi"),
        Step::Delete("apple"),
        Step::Put("banana", "yellow"),
        Step::Put("pea", "g"),
        Step::Delete("fig"),
        Step::Delete("mango"),
        Step::Compact,
    ];
    for step in steps {
        match step {
            Step::Put(key, value) => {
                let size = sp::cell_size(key.len(), value.len());
                writeln!(w, "put {key}={value} ({size}-byte cell)")?;
                page.put(key.as_bytes(), value.as_bytes())
                    .expect("the scenario never fills the page");
            }
            Step::Delete(key) => {
                writeln!(w, "delete {key}")?;
                assert!(page.delete(key.as_bytes()));
            }
            Step::Compact => {
                writeln!(w, "compact")?;
                page.compact();
            }
        }
        page.validate().expect("page is valid after every step");
        describe(w, &page)?;
    }

    writeln!(w, "header and slot array:")?;
    dump_rows(w, page.bytes(), 0, 32)?;
    writeln!(w, "content area:")?;
    dump_rows(
        w,
        page.bytes(),
        page.stats().content_start & !15,
        sp::PAGE_SIZE,
    )
}

fn name(i: usize) -> String {
    format!("k{i:03}")
}

/// Fragmentation under pressure: enough free bytes, but not in one piece.
fn part_two(w: &mut dyn Write) -> io::Result<()> {
    let mut buf = [0u8; sp::PAGE_SIZE];
    let mut page = SlottedPage::init(&mut buf);
    let filler = [b'.'; 96];
    writeln!(w, "\n== Part 2: fragmentation and automatic compaction ==")?;

    let mut n = 0;
    while page.fits(4, filler.len()) {
        page.put(name(n).as_bytes(), &filler)
            .expect("fits() said so");
        n += 1;
    }
    let size = sp::cell_size(4, filler.len());
    writeln!(
        w,
        "fill with {size}-byte cells until the next one does not fit"
    )?;
    describe_short(w, &page)?;

    for i in (0..n).step_by(2) {
        assert!(page.delete(name(i).as_bytes()));
    }
    writeln!(w, "delete every other cell")?;
    describe_short(w, &page)?;

    let big = [b'B'; 500];
    writeln!(
        w,
        "put big ({}-byte cell): no free block and no gap is large enough, so the page compacts first",
        sp::cell_size(3, big.len())
    )?;
    page.put(b"big", &big).expect("enough free bytes in total");
    describe_short(w, &page)?;

    let huge = [b'H'; 2000];
    write!(w, "put huge ({}-byte cell): ", sp::cell_size(4, huge.len()))?;
    let err = page.put(b"huge", &huge).expect_err("the page is too full");
    writeln!(w, "{err}, page unchanged")?;
    describe_short(w, &page)?;
    page.validate().expect("page is valid");
    Ok(())
}

/// The shared pseudo-random operation stream applied to one page. Zig and
/// Rust must agree on every counter and on a hash of the final page bytes.
fn part_three(w: &mut dyn Write) -> io::Result<()> {
    let mut buf = [0u8; sp::PAGE_SIZE];
    let mut page = SlottedPage::init(&mut buf);
    let config = Config {
        seed: 10,
        count: 3000,
        key_space: 300,
        weights: Weights::default(),
    };
    writeln!(w, "\n== Part 3: 3000 random operations on one page ==")?;
    writeln!(
        w,
        "seed={} count={} key_space={}",
        config.seed, config.count, config.key_space
    )?;

    let mut kb = [0u8; workload::MAX_KEY_LEN];
    let mut vb = [0u8; workload::MAX_VALUE_LEN];
    let (mut puts, mut page_full) = (0usize, 0usize);
    let (mut deletes, mut delete_hits) = (0usize, 0usize);
    let (mut gets, mut get_hits) = (0usize, 0usize);
    let (mut ranges, mut range_cells) = (0usize, 0usize);
    let (mut max_blocks, mut max_frag) = (0usize, 0usize);

    for op in OpStream::new(config) {
        match op {
            Op::Put { key, value } => {
                puts += 1;
                let k = workload::key_bytes(&mut kb, key);
                let v = workload::value_bytes(&mut vb, value);
                if page.put(k, v).is_err() {
                    page_full += 1;
                }
            }
            Op::Delete { key } => {
                deletes += 1;
                delete_hits += usize::from(page.delete(workload::key_bytes(&mut kb, key)));
            }
            Op::Get { key } => {
                gets += 1;
                get_hits += usize::from(page.get(workload::key_bytes(&mut kb, key)).is_some());
            }
            Op::Range { lo, hi } => {
                ranges += 1;
                let lo = page.search(workload::key_bytes(&mut kb, lo)).index;
                let hi = page.search(workload::key_bytes(&mut kb, hi)).index;
                range_cells += hi - lo;
            }
        }
        let s = page.stats();
        max_blocks = max_blocks.max(s.free_block_count);
        max_frag = max_frag.max(s.frag_bytes);
    }
    page.validate().expect("page is valid");
    writeln!(w, "put: {puts} ({page_full} refused with PageFull)")?;
    writeln!(w, "delete: {deletes} ({delete_hits} found)")?;
    writeln!(w, "get: {gets} ({get_hits} found)")?;
    writeln!(w, "range: {ranges} ({range_cells} cells visited)")?;
    writeln!(
        w,
        "most free blocks at once: {max_blocks}, most fragment bytes at once: {max_frag}"
    )?;
    describe_short(w, &page)?;
    writeln!(w, "fnv1a64 of the page: {:016x}", fnv1a64(page.bytes()))
}

fn describe_short(w: &mut dyn Write, page: &SlottedPage) -> io::Result<()> {
    let s = page.stats();
    writeln!(
        w,
        "  cells={} content_start={} gap={} free_blocks={} ({} bytes, largest {}) frag={} free={}",
        s.cell_count,
        s.content_start,
        s.gap,
        s.free_block_count,
        s.free_block_bytes,
        s.largest_free_block,
        s.frag_bytes,
        s.free_bytes
    )
}

fn describe(w: &mut dyn Write, page: &SlottedPage) -> io::Result<()> {
    let s = page.stats();
    write!(
        w,
        "  cells={} content_start={} gap={} free_blocks=[",
        s.cell_count, s.content_start, s.gap
    )?;
    for (i, b) in page.free_blocks().iter().enumerate() {
        write!(
            w,
            "{}{}+{}",
            if i == 0 { "" } else { " " },
            b.offset,
            b.size
        )?;
    }
    write!(w, "] frag={} free={}\n  slots:", s.frag_bytes, s.free_bytes)?;
    if s.cell_count == 0 {
        write!(w, " (none)")?;
    }
    for i in 0..s.cell_count {
        let key = String::from_utf8_lossy(page.key(i));
        write!(w, " {key}@{}", page.cell_offset(i))?;
    }
    writeln!(w)
}

/// Hexdump rows with real page offsets (same row format as common/hexdump).
/// `start` must be a multiple of 16.
fn dump_rows(
    w: &mut dyn Write,
    buf: &[u8; sp::PAGE_SIZE],
    start: usize,
    end: usize,
) -> io::Result<()> {
    for off in (start..end).step_by(16) {
        let row = &buf[off..(off + 16).min(end)];
        write!(w, "{off:08x}  ")?;
        for i in 0..16 {
            match row.get(i) {
                Some(b) => write!(w, "{b:02x} ")?,
                None => write!(w, "   ")?,
            }
            if i == 7 {
                write!(w, " ")?;
            }
        }
        write!(w, " |")?;
        for &b in row {
            let c = if (0x20..=0x7e).contains(&b) {
                b as char
            } else {
                '.'
            };
            write!(w, "{c}")?;
        }
        writeln!(w, "|")?;
    }
    Ok(())
}

/// FNV-1a, 64 bit: a five-line hash, enough to compare two page images.
pub fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf29ce484222325;
    for &b in bytes {
        h ^= u64::from(b);
        h = h.wrapping_mul(0x100000001b3);
    }
    h
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fnv1a64_known_values() {
        assert_eq!(fnv1a64(b""), 0xcbf29ce484222325);
        assert_eq!(fnv1a64(b"a"), 0xaf63dc4c8601ec8c);
    }

    #[test]
    fn demo_output_equals_expected_output_txt() {
        let mut out = Vec::new();
        run(&mut out).unwrap();
        let expected = include_str!("../../expected_output.txt");
        assert_eq!(String::from_utf8(out).unwrap(), expected);
    }
}
