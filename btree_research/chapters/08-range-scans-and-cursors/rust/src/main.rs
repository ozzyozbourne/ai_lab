//! Demo program of chapter 08. Its stdout is exactly ../expected_output.txt
//! (checked by the test at the bottom) and is identical to the Zig program's.

use std::io::{self, Write};
use std::ops::Bound::{self, Excluded, Included, Unbounded};

use ch08_range_scans_and_cursors::bounds::prefix_range;
use ch08_range_scans_and_cursors::{
    Cursor, Direction, Entry, LinkCursor, LinkPosition, Position, Scan, Seek, StackCursor,
    StackPosition, Stats, Tree, base_dump, model,
};

/// Canonical hand example of chapters 03 to 08.
const CANONICAL: [u64; 12] = [10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15];

/// No node budget is set in this program, so `put` cannot fail.
const NO_BUDGET: &str = "no node budget set";

fn main() -> io::Result<()> {
    let mut out = io::BufWriter::new(io::stdout().lock());
    run(&mut out)?;
    out.flush()
}

fn run(w: &mut dyn Write) -> io::Result<()> {
    let mut tree = build_canonical();

    writeln!(w, "== 1. The tree: canonical keys, order M = 4 ==")?;
    base_dump::dump(&tree.base, w)?;

    writeln!(
        w,
        "\n== 2. Bounds matrix: every combination for the bounds 6 and 17 =="
    )?;
    let lows = [Unbounded, Included(6), Excluded(6)];
    let highs = [Unbounded, Included(17), Excluded(17)];
    for lo in lows {
        for hi in highs {
            print_range(w, &tree, lo, hi, Direction::Forward, "")?;
        }
    }
    writeln!(w, "edge cases:")?;
    let max = u64::MAX;
    let forward = Direction::Forward;
    print_range(w, &tree, Included(12), Included(12), forward, "one key")?;
    print_range(
        w,
        &tree,
        Excluded(12),
        Excluded(15),
        forward,
        "neighbours, both excluded",
    )?;
    print_range(
        w,
        &tree,
        Included(13),
        Included(14),
        forward,
        "both bounds in one gap",
    )?;
    print_range(w, &tree, Included(17), Included(6), forward, "inverted")?;
    print_range(
        w,
        &tree,
        Included(12),
        Excluded(12),
        forward,
        "half open, same key",
    )?;
    print_range(
        w,
        &tree,
        Unbounded,
        Excluded(0),
        forward,
        "below the smallest u64",
    )?;
    print_range(
        w,
        &tree,
        Excluded(max),
        Unbounded,
        forward,
        "above the largest u64, no overflow",
    )?;

    writeln!(
        w,
        "\n== 3. Backward: seek to the upper bound, step with prev =="
    )?;
    let backward = Direction::Backward;
    print_range(w, &tree, Unbounded, Unbounded, backward, "")?;
    print_range(w, &tree, Included(6), Excluded(17), backward, "")?;
    print_range(w, &tree, Excluded(6), Included(17), backward, "")?;
    print_range(w, &tree, Included(13), Unbounded, backward, "")?;

    writeln!(w, "\n== 4. Two cursor designs, one result ==")?;
    trace_both(w, &tree)?;
    writeln!(w, "node visits (every move of a cursor to another node):")?;
    compare_costs(w, &tree, Included(5), Included(20), forward)?;
    compare_costs(w, &tree, Included(5), Included(20), backward)?;
    compare_costs(w, &tree, Unbounded, Unbounded, forward)?;
    compare_costs(w, &tree, Included(12), Included(12), forward)?;

    prefix_demo(w)?;

    writeln!(w, "\n== 6. The tree changes under the cursor ==")?;
    change_demo(w, &mut tree)?;
    writeln!(
        w,
        "delete every even key while scanning the whole tree forward:"
    )?;
    delete_while_scanning(w, "link ", LinkPosition::new())?;
    delete_while_scanning(w, "stack", StackPosition::new())?;

    writeln!(
        w,
        "\n== 7. Model run: 20000 random operations, two long-lived cursors stepping in between =="
    )?;
    for order in [3, 4, 16] {
        let r = model::run(model::Config {
            order,
            seed: 8,
            count: 20_000,
            key_space: 500,
        });
        writeln!(
            w,
            "M={order:<2} keys={} height={} scans={} cursor steps={} re-seeks={} | node visits: link={} stack={} | mismatches={}",
            r.keys,
            r.height,
            r.scans,
            r.cursor_steps,
            r.link.reseeks,
            r.link.node_visits,
            r.stack.node_visits,
            r.mismatches,
        )?;
        assert_eq!(r.link.reseeks, r.stack.reseeks);
    }
    Ok(())
}

fn build_canonical() -> Tree {
    let mut tree = Tree::new(4);
    for key in CANONICAL {
        tree.put(key, key * 100).expect(NO_BUDGET);
    }
    tree.validate().expect("valid tree");
    tree
}

/// "[6, 17)" in interval notation: square = included, round = excluded.
fn range_label(lo: Bound<u64>, hi: Bound<u64>) -> String {
    let left = match lo {
        Unbounded => "(-inf".to_string(),
        Included(k) => format!("[{k}"),
        Excluded(k) => format!("({k}"),
    };
    let right = match hi {
        Unbounded => "+inf)".to_string(),
        Included(k) => format!("{k}]"),
        Excluded(k) => format!("{k})"),
    };
    format!("{left}, {right}")
}

fn print_range(
    w: &mut dyn Write,
    tree: &Tree,
    lo: Bound<u64>,
    hi: Bound<u64>,
    direction: Direction,
    note: &str,
) -> io::Result<()> {
    write!(w, "{:<12} :", range_label(lo, hi))?;
    let it = match direction {
        Direction::Forward => tree.range((lo, hi)),
        Direction::Backward => tree.range_backward((lo, hi)),
    };
    let mut n = 0;
    for e in it {
        write!(w, " {}", e.key)?;
        n += 1;
    }
    if n == 0 {
        write!(w, " (nothing)")?;
    }
    if !note.is_empty() {
        write!(w, "   <- {note}")?;
    }
    writeln!(w)
}

/// "#7.0 #2.1": in node #7 the path goes down child 0, in node #2 child 1.
fn path_label(pos: &StackPosition) -> String {
    let frames: Vec<String> = pos
        .path()
        .iter()
        .map(|f| format!("#{}.{}", f.node.index(), f.child))
        .collect();
    frames.join(" ")
}

/// Scans [5, 20] with both cursors side by side and prints where each one is.
fn trace_both(w: &mut dyn Write, tree: &Tree) -> io::Result<()> {
    writeln!(
        w,
        "scan [5, 20] forward; \"#0[2]\" = leaf #0, entry 2; \"#7.0\" = in node #7, down child 0"
    )?;
    writeln!(w, "key  link cursor  stack cursor")?;
    let mut link = Scan::new(Cursor::new(LinkPosition::new()), 5..=20, Direction::Forward);
    let mut stack = Scan::new(
        Cursor::new(StackPosition::new()),
        5..=20,
        Direction::Forward,
    );
    while let Some(a) = link.next(tree) {
        let b = stack
            .next(tree)
            .expect("both cursors return the same entries");
        assert_eq!(a, b);
        let lp = &link.cursor.pos;
        let sp = &stack.cursor.pos;
        writeln!(
            w,
            "{:<4} #{}[{}]        {} -> #{}[{}]",
            a.key,
            lp.leaf.index(),
            lp.index,
            path_label(sp),
            sp.leaf.index(),
            sp.index,
        )?;
    }
    assert_eq!(stack.next(tree), None);
    Ok(())
}

fn compare_costs(
    w: &mut dyn Write,
    tree: &Tree,
    lo: Bound<u64>,
    hi: Bound<u64>,
    direction: Direction,
) -> io::Result<()> {
    let mut link = Scan::new(Cursor::new(LinkPosition::new()), (lo, hi), direction);
    let mut stack = Scan::new(Cursor::new(StackPosition::new()), (lo, hi), direction);
    let (mut a, mut b) = (Vec::new(), Vec::new());
    link.collect_into(tree, &mut a);
    stack.collect_into(tree, &mut b);
    assert_eq!(a, b);
    let name = match direction {
        Direction::Forward => "forward",
        Direction::Backward => "backward",
    };
    writeln!(
        w,
        "{:<12} {:<8} : {:>2} entries, link {:>2}, stack {:>2}",
        range_label(lo, hi),
        name,
        a.len(),
        link.cursor.stats.node_visits,
        stack.cursor.stats.node_visits,
    )
}

fn composite(user_key: u64, row_id: u64) -> u64 {
    (user_key << 32) | row_id
}

/// Prefix scan as a range, on the composite keys of chapter 07, section 6.
fn prefix_demo(w: &mut dyn Write) -> io::Result<()> {
    writeln!(
        w,
        "\n== 5. Prefix scan as a range: key = (user key << 32) | row id =="
    )?;
    let mut tree = Tree::new(4);
    const LAST_USER: u64 = 0xFFFF_FFFF;
    let rows = [
        (7, 1),
        (3, 2),
        (7, 3),
        (9, 4),
        (7, 5),
        (3, 6),
        (7, 7),
        (LAST_USER, 8),
        (LAST_USER, 9),
    ];
    for (user_key, row_id) in rows {
        tree.put(composite(user_key, row_id), row_id)
            .expect(NO_BUDGET);
    }
    tree.validate().expect("valid tree");
    for user_key in [7, 3, 8, LAST_USER] {
        let (lo, hi) = prefix_range(user_key, 32);
        write!(
            w,
            "user key {user_key}: range {}, row ids:",
            range_label(lo, hi)
        )?;
        let mut n = 0;
        for e in tree.range((lo, hi)) {
            write!(w, " {}", e.value)?;
            n += 1;
        }
        if n == 0 {
            write!(w, " (nothing)")?;
        }
        writeln!(w)?;
    }
    Ok(())
}

fn optional_key(e: Option<Entry>) -> String {
    e.map_or("none".to_string(), |found| found.key.to_string())
}

/// A split and a merge between two steps of the same cursors.
fn change_demo(w: &mut dyn Write, tree: &mut Tree) -> io::Result<()> {
    let mut link: LinkCursor = Cursor::new(LinkPosition::new());
    let mut stack: StackCursor = Cursor::new(StackPosition::new());
    link.seek(tree, Seek::Ge(10));
    stack.seek(tree, Seek::Ge(10));
    let on_link = link.next(tree).expect("12 follows 10");
    let on_stack = stack.next(tree).expect("12 follows 10");
    writeln!(
        w,
        "both cursors: seek >= 10, next. link on {} at #{}[{}], stack on {} at {} -> #{}[{}]",
        on_link.key,
        link.pos.leaf.index(),
        link.pos.index,
        on_stack.key,
        path_label(&stack.pos),
        stack.pos.leaf.index(),
        stack.pos.index,
    )?;

    write!(w, "put 11, 13, 14: leaf #1 fills up and splits\n  ")?;
    for key in [11, 13, 14] {
        tree.put(key, key * 100).expect(NO_BUDGET);
    }
    tree.validate().expect("valid tree");
    base_dump::dump(&tree.base, w)?;
    // What a cursor WITHOUT the version check would do: trust (leaf, index).
    let mut naive = link.pos.clone();
    let mut ignored = Stats::default();
    let now_there = naive.entry(&tree.base).key;
    let stepped = naive.next(&tree.base, &mut ignored).expect("a next entry");
    writeln!(
        w,
        "  the old position #{}[{}] now holds {}; stepping from it would return {} a second time",
        link.pos.leaf.index(),
        link.pos.index,
        now_there,
        stepped.key,
    )?;
    let next = link.next(tree).expect("13 follows 12");
    writeln!(
        w,
        "  link  next -> {} (re-seek: first key > 12), now at #{}[{}]",
        next.key,
        link.pos.leaf.index(),
        link.pos.index,
    )?;
    let next = stack.next(tree).expect("13 follows 12");
    writeln!(
        w,
        "  stack next -> {} (re-seek: first key > 12), now at {} -> #{}[{}]",
        next.key,
        path_label(&stack.pos),
        stack.pos.leaf.index(),
        stack.pos.index,
    )?;

    let before = tree.base.stats;
    for key in [13, 14, 15, 17] {
        tree.delete(key);
    }
    tree.validate().expect("valid tree");
    write!(
        w,
        "delete 13 (the entry under both cursors), 14, 15, 17: {} borrow, {} merges\n  ",
        tree.base.stats.borrows - before.borrows,
        tree.base.stats.merges - before.merges,
    )?;
    base_dump::dump(&tree.base, w)?;
    write!(w, "  link  entry -> {}", optional_key(link.entry(tree)))?;
    write!(w, " (deleted), next -> {}", optional_key(link.next(tree)))?;
    write!(w, ", prev -> {}", optional_key(link.prev(tree)))?;
    write!(w, "\n  stack entry -> {}", optional_key(stack.entry(tree)))?;
    write!(w, " (deleted), prev -> {}", optional_key(stack.prev(tree)))?;
    write!(w, ", next -> {}", optional_key(stack.next(tree)))?;
    // An overwrite moves nothing, so it does not invalidate the position.
    let on_12 = link.seek(tree, Seek::Ge(12)).expect("12 is present");
    let reseeks_before = link.stats.reseeks;
    tree.put(12, 1212).expect(NO_BUDGET);
    let after = link.entry(tree).expect("12 is present");
    writeln!(
        w,
        "\n  link on {}={}; put 12=1212 (overwrite); entry -> {}={}, re-seeks caused: {}",
        on_12.key,
        on_12.value,
        after.key,
        after.value,
        link.stats.reseeks - reseeks_before,
    )?;
    writeln!(
        w,
        "  re-seeks so far: link {}, stack {}",
        link.stats.reseeks, stack.stats.reseeks
    )
}

/// The classic use: delete rows while scanning them. `Scan` does not borrow
/// the tree, so the `delete` between two `next` calls compiles.
fn delete_while_scanning<P: Position>(w: &mut dyn Write, name: &str, pos: P) -> io::Result<()> {
    let mut tree = build_canonical();
    let mut scan = Scan::new(Cursor::new(pos), .., Direction::Forward);
    write!(w, "  {name} returned:")?;
    while let Some(e) = scan.next(&tree) {
        write!(w, " {}", e.key)?;
        if e.key % 2 == 0 {
            tree.delete(e.key);
        }
    }
    tree.validate().expect("valid tree");
    write!(w, " | re-seeks {} | left:", scan.cursor.stats.reseeks)?;
    for e in tree.range(..) {
        write!(w, " {}", e.key)?;
    }
    writeln!(w)
}

#[cfg(test)]
mod tests {
    #[test]
    fn run_prints_exactly_expected_output_txt() {
        let mut out = Vec::new();
        super::run(&mut out).unwrap();
        assert_eq!(
            String::from_utf8(out).unwrap(),
            include_str!("../../expected_output.txt")
        );
    }
}
