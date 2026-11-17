//! Chapter 02 demo program. `cargo run` prints exactly
//! ../expected_output.txt (a test below checks that), and the Zig program in
//! ../zig prints the same bytes.

use std::io::{self, Write};
use std::ops::Bound;

use ch02_searching_a_sorted_node::prng::SplitMix64;
use ch02_searching_a_sorted_node::{node, search, trace};

/// The canonical keys of chapters 03 to 08, in sorted order: one node.
const NODE_KEYS: [u64; 12] = [1, 3, 5, 6, 7, 10, 12, 15, 17, 20, 25, 30];
/// A node with duplicates, to tell lower bound and upper bound apart.
const DUP_KEYS: [u64; 8] = [3, 7, 7, 7, 12, 15, 15, 20];

/// Number of u64 slots of scratch memory `run` needs: 4096 keys plus up to
/// 4096 probes.
const SCRATCH_KEYS: usize = 2 * 4096;

fn main() -> io::Result<()> {
    let mut out = io::BufWriter::new(io::stdout().lock());

    // All memory the program needs, reserved on the stack, like the Zig
    // version's buffer behind a FixedBufferAllocator. No heap.
    let mut scratch = [0u64; SCRATCH_KEYS];

    run(&mut out, &mut scratch)?;
    out.flush()
}

/// Writes the whole demo to `w`. `scratch` is used for the two large arrays
/// of section 7 only; everything else works on constant arrays.
fn run(w: &mut impl Write, scratch: &mut [u64]) -> io::Result<()> {
    writeln!(w, "chapter 02: searching a sorted node")?;

    writeln!(w, "\n[1] one node: the canonical keys of chapters 03-08, sorted")?;
    write!(w, "index:")?;
    for i in 0..NODE_KEYS.len() {
        write!(w, " {i:>3}")?;
    }
    write!(w, "\nkey:  ")?;
    for k in NODE_KEYS {
        write!(w, " {k:>3}")?;
    }
    writeln!(w)?;

    writeln!(w, "\n[2] search(key) -> {{found, index}}: where the key is, or where it would be inserted")?;
    writeln!(w, "key  found  index")?;
    for key in [0, 1, 12, 13, 30, 31] {
        let r = search::search(&NODE_KEYS, key);
        writeln!(w, "{key:>3}  {:<5}  {:>5}", yes_no(r.found), r.index)?;
    }

    writeln!(w, "\n[3] trace of lowerBound(13); invariant: keys[0..lo] < 13 <= keys[hi..]")?;
    write_trace(w, &NODE_KEYS, 13, trace::Mode::Lower)?;
    writeln!(w, "trace of upperBound(12); invariant: keys[0..lo] <= 12 < keys[hi..]")?;
    write_trace(w, &NODE_KEYS, 12, trace::Mode::Upper)?;

    writeln!(w, "\n[4] duplicates: lower bound, upper bound, count = upper - lower")?;
    write!(w, "keys:")?;
    for k in DUP_KEYS {
        write!(w, " {k}")?;
    }
    writeln!(w, "\nkey  lower  upper  count")?;
    for key in [2, 3, 7, 8, 15, 20, 21] {
        let span = search::equal_range(&DUP_KEYS, key);
        writeln!(w, "{key:>3}  {:>5}  {:>5}  {:>5}", span.start, span.end, span.len())?;
    }

    writeln!(w, "\n[5] range bounds on the node of [1]: key range -> index range [start, end)")?;
    use Bound::{Excluded, Included, Unbounded};
    let ranges = [
        ("[5, 17]", Included(5), Included(17)),
        ("(5, 17]", Excluded(5), Included(17)),
        ("[5, 17)", Included(5), Excluded(17)),
        ("(5, 17)", Excluded(5), Excluded(17)),
        ("[4, 16]", Included(4), Included(16)),
        ("(4, 16)", Excluded(4), Excluded(16)),
        ("[8, 9]", Included(8), Included(9)),
        ("(7, 7)", Excluded(7), Excluded(7)),
        ("(20, +inf)", Excluded(20), Unbounded),
        ("(-inf, 5)", Unbounded, Excluded(5)),
    ];
    for (text, lo, hi) in ranges {
        let span = search::range_span(&NODE_KEYS, lo, hi);
        write!(w, "{text:<10} -> [{:>2}, {:>2})  {} keys:", span.start, span.end, span.len())?;
        for k in &NODE_KEYS[span] {
            write!(w, " {k}")?;
        }
        writeln!(w)?;
    }

    writeln!(w, "\n[6] neighbours (bound minus one; 'none' instead of index -1)")?;
    writeln!(w, "key  last <  last <=")?;
    for key in [0, 1, 12, 13, 31] {
        write!(w, "{key:>3}")?;
        write_optional_index(w, search::last_less(&NODE_KEYS, key))?;
        write_optional_index(w, search::last_less_or_equal(&NODE_KEYS, key))?;
        writeln!(w)?;
    }

    writeln!(w, "\n[7] sorted batch of probes against 4096 sorted keys (seed 2): comparisons")?;
    let mut rng = SplitMix64::new(2);
    let (keys, rest) = search::make_sorted(scratch, &mut rng, 4096, 16).ok_or_else(out_of_scratch)?;
    let keys = &*keys; // read-only from here on
    let top = keys[keys.len() - 1] + 1;
    writeln!(w, "probes  binary from 0  gallop from cursor")?;
    for m in [4, 64, 1024, 4096] {
        let probes = rest.get_mut(..m).ok_or_else(out_of_scratch)?;
        for p in probes.iter_mut() {
            *p = rng.below(top);
        }
        probes.sort_unstable();

        let mut binary_total = 0;
        let mut gallop_total = 0;
        // The cursor is where the previous (smaller or equal) probe landed,
        // so the next answer cannot be left of it.
        let mut cursor = 0;
        for &p in probes.iter() {
            let b = trace::lower_bound_counted(keys, p);
            let g = trace::gallop_lower_bound_counted(keys, cursor, p);
            assert_eq!(b.index, g.index);
            binary_total += b.comparisons;
            gallop_total += g.comparisons;
            cursor = g.index;
        }
        writeln!(w, "{m:>6}  {binary_total:>13}  {gallop_total:>18}")?;
    }

    writeln!(w, "\n[8] a node of capacity 4 driven by search results")?;
    let mut n: node::Node<4> = node::Node::new();
    for key in [10, 20, 5, 6, 12, 20] {
        let r = search::search(n.key_slice(), key);
        write!(w, "put {key:>2}: search -> found={:<3} index={}; ", yes_no(r.found), r.index)?;
        let outcome = match n.put(key, key * 100 + 1) {
            Ok(None) => "inserted;    ",
            Ok(Some(_)) => "overwritten; ",
            Err(node::NodeFull) => "NodeFull;    ",
        };
        write!(w, "{outcome}")?;
        write_keys(w, n.key_slice())?;
    }
    writeln!(w, "get 6 -> {}, get 7 -> {}", optional(n.get(6)), optional(n.get(7)))?;
    write!(w, "delete 6 -> {}; ", optional(n.delete(6)))?;
    write_keys(w, n.key_slice())?;
    // The node has room again, so this put cannot fail.
    let old = n.put(12, 1201).expect("node has a free slot");
    write!(w, "put 12 -> {}; ", optional(old))?;
    write_keys(w, n.key_slice())?;
    n.validate().expect("node is sorted and unique");
    writeln!(w, "validate: ok")
}

/// The Rust counterpart of Zig's `error.OutOfMemory` from the fixed buffer.
fn out_of_scratch() -> io::Error {
    io::Error::new(io::ErrorKind::OutOfMemory, "scratch buffer too small")
}

fn yes_no(b: bool) -> &'static str {
    if b { "yes" } else { "no" }
}

/// Zig prints an optional with `{?d}` as the number or `null`; do the same.
fn optional(value: Option<u64>) -> String {
    value.map_or_else(|| "null".to_string(), |v| v.to_string())
}

fn write_keys(w: &mut impl Write, keys: &[u64]) -> io::Result<()> {
    write!(w, "keys:")?;
    for k in keys {
        write!(w, " {k}")?;
    }
    writeln!(w)
}

fn write_optional_index(w: &mut impl Write, index: Option<usize>) -> io::Result<()> {
    match index {
        Some(i) => write!(w, "  {i:>6}"),
        None => write!(w, "    none"),
    }
}

fn write_trace(w: &mut impl Write, keys: &[u64], key: u64, mode: trace::Mode) -> io::Result<()> {
    let mut buffer = [trace::Step::default(); trace::MAX_STEPS];
    let t = trace::trace_bound(keys, key, mode, &mut buffer);
    let op = if mode == trace::Mode::Lower { "< " } else { "<=" };
    writeln!(w, "step  lo  hi  mid  keys[mid]  decision")?;
    for (i, s) in t.steps.iter().enumerate() {
        write!(w, "{:>4}  {:>2}  {:>2}  {:>3}  {:>9}  ", i + 1, s.lo, s.hi, s.mid, s.probe)?;
        if s.go_right {
            writeln!(w, "{} {op} {key} is true:  lo = mid + 1 = {}", s.probe, s.mid + 1)?;
        } else {
            writeln!(w, "{} {op} {key} is false: hi = mid = {}", s.probe, s.mid)?;
        }
    }
    writeln!(w, "result: {} after {} comparisons", t.index, t.steps.len())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn run_prints_exactly_expected_output_txt() {
        let expected = include_str!("../../expected_output.txt");
        let mut scratch = vec![0u64; SCRATCH_KEYS];
        let mut out = Vec::new();
        run(&mut out, &mut scratch).unwrap();
        assert_eq!(String::from_utf8(out).unwrap(), expected);
    }

    #[test]
    fn run_fails_cleanly_when_the_scratch_buffer_is_too_small() {
        let mut small = [0u64; 128];
        let err = run(&mut io::sink(), &mut small).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::OutOfMemory);
    }
}
