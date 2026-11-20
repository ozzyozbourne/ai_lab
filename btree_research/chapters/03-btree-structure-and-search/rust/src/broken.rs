//! SECTION E: trees that are broken on purpose.
//!
//! Each case takes the canonical tree
//!
//! ```text
//!              [6 10 20]
//! [1 3 5]  [7]  [12 15 17]  [25 30]
//! ```
//!
//! and changes ONE thing, so that exactly one invariant is violated.
//! `validate` must name that invariant. There is one case for every variant
//! of `ValidateError`.
//!
//! Several of these trees still answer every `get` correctly. That is the
//! reason `validate` exists: a test that only looks at query results cannot
//! see such damage until a later insert or delete trips over it.
//!
//! A broken tree can still be inspected and dropped: `render` and `shape`
//! walk the `children` vectors as they are (a test below runs them on all
//! ten). Only `get` is not safe on case 7.

use crate::arena::OutOfNodes;
use crate::base_node::NodeId;
use crate::base_validate::ValidateError;
use crate::tree::{CANONICAL_KEYS, HandTree, value_of};

pub struct Case {
    /// The change, in words.
    pub what: &'static str,
    /// What `validate` must answer.
    pub expect: ValidateError,
    pub apply: fn(&mut HandTree) -> Result<(), OutOfNodes>,
    /// false: a search could follow a pointer that is not there.
    pub searchable: bool,
}

const fn case(
    what: &'static str,
    expect: ValidateError,
    apply: fn(&mut HandTree) -> Result<(), OutOfNodes>,
) -> Case {
    Case {
        what,
        expect,
        apply,
        searchable: true,
    }
}

pub const CASES: [Case; 10] = [
    case(
        "leaf [12 15 17] reordered to [12 17 15]",
        ValidateError::KeysOutOfOrder,
        swap_two_keys,
    ),
    case(
        "leaf [7] holds 11 instead: sorted, but on the wrong side of separator 10",
        ValidateError::KeyOutsideParentBounds,
        key_on_wrong_side,
    ),
    case(
        "leaf [12 15 17] gets a fourth key, 18",
        ValidateError::NodeOverfull,
        fourth_key,
    ),
    case(
        "leaf [7] loses its only key",
        ValidateError::NodeUnderfull,
        empty_leaf,
    ),
    case(
        "the root's key count is set to 0",
        ValidateError::EmptyRoot,
        empty_root,
    ),
    case(
        "leaf [12 15 17] becomes interior [15] above new leaves [12] and [17]",
        ValidateError::LeavesAtDifferentDepths,
        deeper_leaves,
    ),
    Case {
        what: "the root's last child pointer is erased",
        expect: ValidateError::MissingChild,
        apply: erase_child,
        searchable: false,
    },
    case(
        "leaf [7] gets a child pointer",
        ValidateError::UnexpectedChild,
        child_in_leaf,
    ),
    case(
        "key 5 vanishes from leaf [1 3 5], the tree still claims 12 keys",
        ValidateError::WrongKeyCount,
        lose_key,
    ),
    case(
        "a sixth node is allocated but nothing points to it",
        ValidateError::NodeCountMismatch,
        orphan_node,
    ),
];

fn root_of(t: &HandTree) -> NodeId {
    t.root.expect("the canonical tree has a root")
}

fn leaf_at(t: &HandTree, i: usize) -> NodeId {
    t.arena[root_of(t)].children[i]
}

fn swap_two_keys(t: &mut HandTree) -> Result<(), OutOfNodes> {
    let n = leaf_at(t, 2);
    t.arena[n].keys.swap(1, 2);
    t.arena[n].values.swap(1, 2);
    Ok(())
}

fn key_on_wrong_side(t: &mut HandTree) -> Result<(), OutOfNodes> {
    let n = leaf_at(t, 1);
    t.arena[n].keys[0] = 11; // must be between the separators 6 and 10
    t.arena[n].values[0] = value_of(11);
    Ok(())
}

fn fourth_key(t: &mut HandTree) -> Result<(), OutOfNodes> {
    let n = leaf_at(t, 2);
    t.arena[n].insert_entry(3, 18, value_of(18)); // a Vec does not know about M
    t.len += 1; // keep the count honest: only the node size is wrong
    Ok(())
}

fn empty_leaf(t: &mut HandTree) -> Result<(), OutOfNodes> {
    let n = leaf_at(t, 1);
    t.arena[n].remove_entry(0);
    t.len -= 1;
    Ok(())
}

fn empty_root(t: &mut HandTree) -> Result<(), OutOfNodes> {
    let root = root_of(t);
    t.arena[root].keys.clear();
    t.arena[root].values.clear();
    Ok(())
}

fn deeper_leaves(t: &mut HandTree) -> Result<(), OutOfNodes> {
    // Same 12 keys, still sorted, every node within its size limits: only
    // the level of two leaves changes.
    let low = t.leaf(&[12])?;
    let high = t.leaf(&[17])?;
    t.len -= 2; // 12 and 17 were counted before
    let n = leaf_at(t, 2);
    let node = &mut t.arena[n];
    node.leaf = false;
    node.keys = vec![15];
    node.values = vec![value_of(15)];
    node.children = vec![low, high];
    Ok(())
}

fn erase_child(t: &mut HandTree) -> Result<(), OutOfNodes> {
    let root = root_of(t);
    t.arena[root].children.pop();
    Ok(())
}

fn child_in_leaf(t: &mut HandTree) -> Result<(), OutOfNodes> {
    let (first, second) = (leaf_at(t, 0), leaf_at(t, 1));
    t.arena[second].children.push(first);
    Ok(())
}

fn lose_key(t: &mut HandTree) -> Result<(), OutOfNodes> {
    let n = leaf_at(t, 0);
    t.arena[n].remove_entry(2); // t.len is NOT adjusted
    Ok(())
}

fn orphan_node(t: &mut HandTree) -> Result<(), OutOfNodes> {
    t.leaf(&[99])?;
    t.len -= 1; // the key count is right; one node too many exists
    Ok(())
}

/// How many of the 12 canonical keys `get` still finds, with the right value.
pub fn keys_found(t: &HandTree) -> usize {
    CANONICAL_KEYS
        .iter()
        .filter(|&&key| t.get(key) == Some(value_of(key)))
        .count()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tree::canonical;

    #[test]
    fn every_case_breaks_exactly_the_invariant_it_names() {
        let found_expected = [
            Some(11),
            Some(11),
            Some(12),
            Some(11),
            Some(3),
            Some(12),
            None,
            Some(12),
            Some(11),
            Some(12),
        ];
        for (case, found) in CASES.iter().zip(found_expected) {
            let mut t = HandTree::new(4);
            canonical(&mut t).unwrap();
            assert_eq!(t.validate(), Ok(())); // intact before ...
            (case.apply)(&mut t).unwrap();
            assert_eq!(t.validate(), Err(case.expect), "{}", case.what); // ... named after
            if case.searchable {
                assert_eq!(Some(keys_found(&t)), found, "{}", case.what);
            }
            assert_eq!(case.searchable, found.is_some());
        }
    }

    #[test]
    fn the_cases_cover_every_error_validate_can_return() {
        use ValidateError::*;
        // A match without a wildcard: adding a variant makes this test stop compiling.
        let index = |e: ValidateError| match e {
            KeysOutOfOrder => 0,
            KeyOutsideParentBounds => 1,
            NodeOverfull => 2,
            NodeUnderfull => 3,
            EmptyRoot => 4,
            LeavesAtDifferentDepths => 5,
            MissingChild => 6,
            UnexpectedChild => 7,
            WrongKeyCount => 8,
            NodeCountMismatch => 9,
        };
        let mut seen = [false; 10];
        for case in &CASES {
            seen[index(case.expect)] = true;
        }
        assert_eq!(seen, [true; 10]);
    }

    #[test]
    fn a_key_on_the_wrong_side_of_a_separator_is_stored_but_cannot_be_found() {
        let mut t = HandTree::new(4);
        canonical(&mut t).unwrap();
        key_on_wrong_side(&mut t).unwrap();
        assert_eq!(t.arena[leaf_at(&t, 1)].keys, [11]); // it is there ...
        assert_eq!(t.get(11), None); // ... but search goes to [12 15 17]
    }

    #[test]
    fn two_defects_validate_reports_the_one_its_walk_meets_first() {
        // Leaf [7] is visited before leaf [12 15 17], so its defect wins.
        let mut a = HandTree::new(4);
        canonical(&mut a).unwrap();
        swap_two_keys(&mut a).unwrap();
        key_on_wrong_side(&mut a).unwrap();
        assert_eq!(a.validate(), Err(ValidateError::KeyOutsideParentBounds));

        // A disordered first leaf and an erased last child pointer. The
        // walk compares the number of children of a node with its number
        // of keys before it descends into the first child, so the root's
        // defect wins although the leaf is further left. (The Zig twin
        // checks all child slots first as well, and agrees.)
        let mut b = HandTree::new(4);
        canonical(&mut b).unwrap();
        let first = leaf_at(&b, 0);
        b.arena[first].keys.swap(0, 1);
        erase_child(&mut b).unwrap();
        assert_eq!(b.validate(), Err(ValidateError::MissingChild));
    }

    #[test]
    fn every_broken_tree_can_be_printed_measured_validated_and_dropped() {
        // What `render` prints for each broken tree. Two lines differ from
        // the Zig twin, because a Rust node has no key count that also
        // limits its children: the root of case 5 keeps its four children
        // (Zig: a walk sees 1 child for 0 keys), and `shape` of case 8
        // counts the extra child of leaf [7] (6 nodes; Zig: 5).
        let rendered = [
            "[6 10 20]\n[1 3 5] [7] [12 17 15] [25 30]\n",
            "[6 10 20]\n[1 3 5] [11] [12 15 17] [25 30]\n",
            "[6 10 20]\n[1 3 5] [7] [12 15 17 18] [25 30]\n",
            "[6 10 20]\n[1 3 5] [] [12 15 17] [25 30]\n",
            "[]\n[1 3 5] [7] [12 15 17] [25 30]\n",
            // The height is measured along the leftmost path, so level 3 is not printed.
            "[6 10 20]\n[1 3 5] [7] [15] [25 30]\n",
            "[6 10 20]\n[1 3 5] [7] [12 15 17]\n",
            "[6 10 20]\n[1 3 5] [7] [12 15 17] [25 30]\n",
            "[6 10 20]\n[1 3] [7] [12 15 17] [25 30]\n",
            "[6 10 20]\n[1 3 5] [7] [12 15 17] [25 30]\n",
        ];
        let nodes = [5, 5, 5, 5, 5, 7, 4, 6, 5, 5];
        for ((case, text), nodes) in CASES.iter().zip(rendered).zip(nodes) {
            let mut t = HandTree::new(4);
            canonical(&mut t).unwrap();
            (case.apply)(&mut t).unwrap();
            let mut out = Vec::new();
            t.render(&mut out, "").unwrap(); // must not panic, whatever the damage
            assert_eq!(String::from_utf8(out).unwrap(), text, "{}", case.what);
            assert_eq!(t.shape().nodes, nodes, "{}", case.what);
            assert_eq!(t.validate(), Err(case.expect), "{}", case.what);
            // `t` is dropped here: the arena frees every node, reachable or not.
        }
    }
}
