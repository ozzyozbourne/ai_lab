//! Chapter 26: allocators, handles and static memory.
//!
//! `cargo run` prints the fixed scenario of the chapter (identical to the Zig program
//! and to ../expected_output.txt):
//!   1. a bitmap slab pool with 32-bit handles
//!   2. a B-tree whose nodes live in two such pools (two size classes)
//!   3. holes after deletes, and vacuum
//!   4. static memory: reserve, freeze, run, exhaust
//!   5. a buddy allocator
//!
//! `idioms.rs` (the counterpart of the Zig allocator tour) is tests only.

mod btree;
mod buddy;
#[cfg(test)]
mod idioms;
#[allow(dead_code)] // the oracle is used by the model test only
mod ops;
#[allow(dead_code)] // only the tests draw random numbers directly
mod prng;
mod slab;

use btree::{BTree, CANONICAL_KEYS};
use ops::{Config, Op, OpStream, Weights};
use slab::{Handle, SlabPool};
use std::io::{self, Write};

fn print_pools<const M: usize, const K: usize, const S: usize>(
    w: &mut impl Write,
    tree: &BTree<M, K, S>,
) -> io::Result<()> {
    writeln!(w, "leaf slabs:     {}", tree.leaves.map())?;
    writeln!(w, "interior slabs: {}", tree.interiors.map())
}

fn demo(w: &mut impl Write) -> io::Result<()> {
    // ---- 1 -----------------------------------------------------------------------------
    writeln!(w, "== 1. bitmap slab, 32-bit handles ==")?;
    {
        let mut pool: SlabPool<u64, 4> = SlabPool::new(0, true, 0);
        let hs: Vec<Handle> = (0..6)
            .map(|_| pool.create().expect("unlimited budget"))
            .collect();
        writeln!(w, "create x6:      {}", pool.map())?;
        writeln!(
            w,
            "last handle:    {} = 0x{:08x} ({} bytes)",
            hs[5],
            hs[5].to_int(),
            size_of::<Handle>()
        )?;
        pool.destroy(hs[1]);
        pool.destroy(hs[3]);
        writeln!(w, "destroy 2:      {}", pool.map())?;
        let again = pool.create().expect("unlimited budget");
        writeln!(w, "create:         {again} (lowest hole first)")?;
        pool.destroy(hs[4]);
        pool.destroy(hs[5]);
        writeln!(
            w,
            "empty slab 1:   {} (given back: slab 0 has room)",
            pool.map()
        )?;
        for h in [hs[0], again, hs[2]] {
            pool.destroy(h);
        }
        writeln!(
            w,
            "empty slab 0:   {} (kept: the only free space)",
            pool.map()
        )?;
    }

    // ---- 2 -----------------------------------------------------------------------------
    writeln!(
        w,
        "\n== 2. B-tree on two slab pools (M = 4, 4 slots per slab) =="
    )?;
    let mut tree: BTree<4, 3, 4> = BTree::new(true);
    writeln!(w, "put 10 20 5 6 12 30 7 17 3 25 1 15")?;
    for k in CANONICAL_KEYS {
        tree.put(k, k * 10).expect("unlimited budget");
    }
    write!(w, "{}", tree.dump())?;
    print_pools(w, &tree)?;
    writeln!(
        w,
        "node sizes:     leaf {} bytes, interior {} bytes",
        size_of::<btree::Leaf<3>>(),
        size_of::<btree::Interior<4, 3>>()
    )?;
    writeln!(
        w,
        "get 17 = {}, get 18 = {}",
        show(tree.get(17)),
        show(tree.get(18))
    )?;
    let mut found = Vec::new();
    tree.range(6, 20, &mut found);
    let keys: Vec<String> = found.iter().map(|e| e.key.to_string()).collect();
    writeln!(w, "range [6, 20) = {}", keys.join(" "))?;

    // ---- 3 -----------------------------------------------------------------------------
    writeln!(w, "\n== 3. holes and vacuum ==")?;
    for k in 31..=60 {
        tree.put(k, k * 10).expect("unlimited budget");
    }
    writeln!(
        w,
        "put 31..60:     {} keys, height {}",
        tree.count, tree.height
    )?;
    print_pools(w, &tree)?;
    for k in (1..=60).filter(|k| k % 5 != 0) {
        tree.delete(k);
    }
    writeln!(
        w,
        "delete all but multiples of 5: {} keys, height {}",
        tree.count, tree.height
    )?;
    print_pools(w, &tree)?;
    for pass in 1.. {
        let moved = tree.vacuum();
        if moved == 0 {
            break;
        }
        writeln!(w, "vacuum pass {pass}:  moved {moved} node(s)")?;
        print_pools(w, &tree)?;
    }
    write!(w, "{}", tree.dump())?;
    tree.validate().expect("valid tree");
    writeln!(w, "validate: ok")?;

    // ---- 4 -----------------------------------------------------------------------------
    writeln!(w, "\n== 4. static memory: reserve, freeze, run ==")?;
    {
        // Zig stacks buddy allocator -> freeze wrapper -> slab pools -> tree. Here the
        // pools own their memory, so "freeze" is a property of the pool itself.
        let mut fixed: BTree<4, 3, 32> = BTree::new(false);
        fixed.leaves.reserve(3).expect("init may allocate");
        fixed.interiors.reserve(2).expect("init may allocate");
        fixed.leaves.freeze();
        fixed.interiors.freeze();
        writeln!(
            w,
            "reserved:       {} leaf slabs, {} interior slabs of 32 slots; frozen",
            fixed.leaves.slab_count, fixed.interiors.slab_count
        )?;

        let mut failed_puts = 0;
        for op in OpStream::new(Config {
            seed: 26,
            count: 5000,
            key_space: 100,
            weights: Weights::default(),
        }) {
            match op {
                Op::Put { key, value } => failed_puts += u32::from(fixed.put(key, value).is_err()),
                Op::Delete { key } => {
                    fixed.delete(key);
                }
                _ => {}
            }
        }
        fixed.validate().expect("valid tree");
        writeln!(
            w,
            "5000 ops:       {} keys, {} leaves + {} interior nodes live, failed puts {}",
            fixed.count, fixed.leaves.live, fixed.interiors.live, failed_puts
        )?;
        writeln!(
            w,
            "slabs now:      {} leaf, {} interior (unchanged)",
            fixed.leaves.slab_count, fixed.interiors.slab_count
        )?;

        // Ascending inserts until the pool runs dry.
        let mut key = 1000;
        while fixed.put(key, key).is_ok() {
            key += 1;
        }
        fixed.validate().expect("valid tree");
        writeln!(
            w,
            "fill:           put {} failed with OutOfMemory at {} keys",
            key, fixed.count
        )?;
        let refusals = fixed.leaves.grow_failures + fixed.interiors.grow_failures;
        writeln!(
            w,
            "pool refusals:  {}; tree still valid, get {} = {}",
            refusals,
            key,
            show(fixed.get(key))
        )?;
        writeln!(
            w,
            "free slots:     {} leaf, {} interior",
            fixed.leaves.free_slots(),
            fixed.interiors.free_slots()
        )?;
    }

    // ---- 5 -----------------------------------------------------------------------------
    writeln!(
        w,
        "\n== 5. buddy allocator (1024-byte heap, 64-byte minimum block) =="
    )?;
    {
        let mut heap = buddy::Buddy::new(10, 6);
        let mut blocks = Vec::new();
        for (name, len) in [("a", 100), ("b", 60), ("c", 200)] {
            blocks.push((name, heap.alloc(len).expect("fits")));
            writeln!(w, "alloc {name} = {len:>3}:  {}", heap.map())?;
        }
        writeln!(
            w,
            "requested {} bytes, granted {}: {} lost to rounding",
            heap.requested,
            heap.granted,
            heap.granted - heap.requested
        )?;
        let big = if heap.alloc(600).is_some() {
            "ok"
        } else {
            "OutOfMemory"
        };
        writeln!(
            w,
            "free {} bytes, largest block {}; alloc 600 -> {}",
            heap.free_bytes(),
            heap.largest_free(),
            big
        )?;
        for (name, offset) in blocks {
            heap.free(offset);
            writeln!(w, "free {name}:         {}", heap.map())?;
        }
        heap.validate().expect("valid heap");
    }
    Ok(())
}

/// Formats like Zig's `{?d}`.
fn show(value: Option<u64>) -> String {
    value.map_or("null".to_string(), |v| v.to_string())
}

fn main() -> io::Result<()> {
    let mut out = io::BufWriter::new(io::stdout().lock());
    demo(&mut out)?;
    out.flush()
}

#[cfg(test)]
mod tests {
    #[test]
    fn run_output_matches_expected_output_txt() {
        let mut out = Vec::new();
        super::demo(&mut out).unwrap();
        assert_eq!(
            String::from_utf8(out).unwrap(),
            include_str!("../../expected_output.txt")
        );
    }
}
