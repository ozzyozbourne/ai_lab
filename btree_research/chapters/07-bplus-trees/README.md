# Chapter 07: B+trees

## What you will learn

- What changes when values are stored only in the leaves, and why most
  database B-trees are built that way.
- The difference between **copy-up** (leaf split) and **push-up** (internal
  split), and why a separator is a signpost rather than a key.
- How the leaves are chained into a doubly linked list, and how insert and
  delete keep that chain correct.
- How to allow duplicate keys by adding a tie-breaker.
- How to build a tree from 32-bit **handles** into one array instead of
  pointers, with a free list that recycles nodes.

Prerequisites: chapters 03 to 05 (B-tree structure, splitting, borrowing and
merging) and chapter 02 (lower bound and upper bound). Chapter 06 explains the
testing style used here.

The code in this chapter is the base that chapters 08, 18, 19, 20, 23, 24 and
27 copy, so it is split into one file per concern.

## The idea in plain words

In the classic B-tree of chapters 03 to 05 every key lives in exactly one
place, and that place may be an internal node. A B+tree makes one change:

> Every entry (key and value) lives in a leaf. Internal nodes hold only
> separator keys and child links.

Three things follow from that.

**Internal nodes get smaller, so the tree gets wider.** An internal node no
longer carries values. With real page sizes this is the main benefit: more
separators fit in a page, each node has more children, and the tree is
shorter. The small fixed-size nodes of this chapter cannot show it: here the
B+tree uses more nodes than the B-tree for the same keys, because the
separators are extra copies.

**A separator is a signpost, not a key.** When a leaf splits, the first key of
the new right leaf is *copied* into the parent. The entry stays in the leaf.
The copy in the parent only says "keys greater than or equal to me are to the
right". It follows that:

- a lookup never stops in an internal node, even when the key equals a
  separator. It always continues to a leaf;
- deleting a key does not have to touch the internal nodes. If the key was
  also a separator, the separator stays behind. It is still a correct
  signpost, it just no longer names an existing key;
- a separator does not need to be a real key at all. Any value that separates
  the two children works. Chapter 17 uses this to shorten separators.

**The leaves can be chained.** All entries are in the leaves, in key order, so
linking each leaf to its neighbours gives a sorted list of everything in the
tree. An ordered scan finds its first leaf by one descent and then walks
sideways. It never climbs back into the internal nodes. This chapter builds
and validates the chain and walks it in the simplest possible way; chapter 08
builds real range scans and cursors on top of it.

### Copy-up and push-up

A leaf split and an internal split are different operations:

| | What goes to the parent | What stays below |
|---|---|---|
| Leaf split: **copy-up** | a copy of the right half's first key | all entries, including that key |
| Internal split: **push-up** | the middle separator itself | the separators left and right of it |

An internal split is the same as in a classic B-tree: the middle key moves up
and is in neither half. A separator only needs to exist once per boundary, so
there is no reason to keep a copy below.

### The rules, for working by hand

Order M: a node holds at most M - 1 keys and, except the root, at least
ceil(M/2) - 1.

**Insert.** Walk down: in an internal node follow child number *i*, where *i*
is the number of separators less than or equal to the key. Put the entry into
the leaf in key order. A node that now holds M keys splits: the first
floor(M/2) keys stay and the rest go to a new node on its right. From a leaf,
the new node's first key is copied up. From an internal node, the key at
position floor(M/2) moves up and only the keys after it go to the new node. A
root that splits gets a new root above it.

**Delete.** Remove the entry from its leaf and leave the separators alone. If
the leaf now has fewer keys than the minimum, repair it with the first of
these steps that applies. Only siblings under the same parent count.

1. The left sibling has more than the minimum: borrow its last entry.
2. The right sibling has more than the minimum: borrow its first entry.
3. There is a left sibling: merge with it.
4. Otherwise the node is the leftmost child: merge with the right sibling.

So the left sibling is always tried first, for borrowing and for merging. A
borrow between leaves rewrites the separator between the two as a copy of the
right one's first key. A merge empties the right node of the pair into the
left one and frees the right one. The parent loses the separator between
them: between leaves it is dropped, between internal nodes it is pulled down
into the merged node. If the parent is now below the minimum, the same four
steps repair it one level up; a borrow between internal nodes is the rotation
through the parent from chapter 05. A root left with no separator is replaced
by its only child.

**Handles** are given out in allocation order: `#0`, `#1`, and so on. The
left half of a split keeps its handle, the new right node gets the next one,
and a new root is allocated after the split below it. Once nodes have been
freed, the handle freed last is reused first.

### Duplicate keys and tie-breakers

The tree in this chapter keeps the rule from Part I: keys are unique and `put`
overwrites. Real indexes often need many rows with the same key (an index on
`city`, for example). There are three common answers:

1. **Tie-breaker.** Make the tree key the pair (user key, row id). The row id
   is unique, so the pair is unique, and all rows of one user key sit next to
   each other in the leaf chain. This is the approach to prefer: every entry
   has exactly one position, so it can be found and deleted by a normal
   descent, and a split between two equal user keys is well defined.
2. **A list of row ids per key** (a posting list). Chapter 17 covers it.
3. **Allow equal keys in the tree.** This looks simplest and is the hardest to
   get right: "left child holds smaller keys, right child holds greater or
   equal keys" stops being enough to find a specific entry.

Section 6 of the demo program implements the first option by packing
(user key, row id) into one `u64`, 32 bits each. Larger values would collide,
so the demo asserts that both parts fit.

### Handles instead of pointers

The nodes of this tree do not point at each other. They all live in one
array (the *arena*) and refer to each other by index. A 32-bit index used
this way is called a handle. Reasons:

- A handle stays valid when the array grows and moves. A pointer into the
  array does not.
- A handle is 4 bytes; a pointer is 8. Internal nodes are mostly child links.
- A handle is what an on-disk tree stores: a page number. Code written
  against handles keeps its shape when nodes become pages in chapter 12.
- The whole tree is freed by freeing one array.

A freed node is not returned to the operating system. Its slot is put on a
**free list**: the slot stores the handle of the next free slot, and the arena
remembers the head. Allocation pops the head; freeing pushes. Both are O(1).

## A worked example by hand

Order M = 4: a node holds at most 3 keys and, except the root, at least 1.
A node is allowed to overflow to 4 keys for a moment and is then split with
`mid = 4 / 2 = 2`. Insert 10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15.
`#n` is a node handle, `[..]` an internal node, `(..)` a leaf.

**10, 20, 5, 6**: the first leaf fills to `#0(5 10 20)`; 6 makes it
`5 6 10 20`, one too many. `5 6` stay in `#0`, `10 20` move to a new leaf
`#1`, and the first key of the right half, 10, is *copied* up into a new root:

```
        #2[10]
#0(5 6) <-> #1(10 20)
```

10 is now in two places: as a separator in `#2` and as an entry in `#1`.

**12, 30, 7, 17, 3, 25, 1**: two more leaf splits copy up 20 and then 6. The
root is now full, `#2[6 10 20]`, over the leaves
`#0(1 3 5) #4(6 7) #1(10 12 17) #3(20 25 30)`.

**15**: goes to `#1`, which overflows (`10 12 15 17`). `15 17` move to `#5` and
15 is copied up into the root, which now holds `6 10 15 20`: one too many. The
root is an internal node, so this split is a push-up: `6 10` stay in `#2`,
`20` moves to a new node `#6`, and 15 moves up into a new root `#7`:

```
                         #7[15]
            #2[6 10]                 #6[20]
#0(1 3 5) <-> #4(6 7) <-> #1(10 12) <-> #5(15 17) <-> #3(20 25 30)
```

15 was first copied up (it is still in leaf `#5`) and then pushed up (it is in
`#7` and no longer in `#2`). Separators 6, 10 and 20 are copies of leaf keys.

For comparison, the classic B-tree of chapter 05 with the same keys and the
same split rule ends as:

```
            [6 10 20]
[1 3 5]  [7]  [12 15 17]  [25 30]
```

Height 2 and 5 nodes against height 3 and 8 nodes: 6, 10 and 20 are stored
once, in the root, with their values. The B+tree pays for its copies here
because both trees have the same number of keys per node; in a real page its
internal nodes would hold many more separators than a B-tree node holds
entries.

**Deleting.** Delete 15: the entry leaves `#5`, and that is all. The root
still says 15, and a later search for 16 still goes right and arrives in the
correct leaf. Delete 17: leaf `#5` is now empty. Its right sibling
`#3(20 25 30)` can spare a key, so 20 moves over and the separator between
them becomes a copy of the sibling's new first key, 25 (step 2 of the rules;
`#5` is a leftmost child, so step 1 does not apply). The program output below
continues through a leaf merge, an internal rotation, an internal merge and
the loss of a level.

**A merge in the middle.** Start again from the final tree and delete 3, 5,
12 and 7. No leaf goes below the minimum, but the three children of `#2` are
now at it: `#0(1)`, `#4(6)`, `#1(10)`. Delete 6: `#4` is empty. Neither
sibling can spare a key, so steps 1 and 2 fail, and `#4` has a left sibling,
so step 3 merges it with `#0`. `#4` is the right node of that pair: it is
freed, and separator 6 is dropped. `#2[10]` is left over `#0(1) <-> #1(10)`.
A test in both languages checks this case.

## Code walk-through

Both languages have the same files, names and output, and the same tests
except for the few named in the Rust section.

Files, in both `zig/src` and `rust/src`: `arena` (handles, slots, free list),
`node` (layout, in-node inserts and removes), `tree` (fields and the list of
invariants), `search`, `insert`, `delete`, `walk` (the minimal leaf walk),
`validate`, `dump` (the text rendering), `tests`, and `ops` (copied from
`common/`).

### Zig

**Arena** (`arena.zig`). `NodeId` is `enum(u32) { nil = maxInt(u32), _ }`: a
distinct type, so a handle cannot be confused with an index or a count. A slot
is `union(enum) { used: T, free: NodeId }`. The tag makes a double free and a
dangling handle detectable. `reserve(gpa, n)` is the only function that
allocates. After it succeeds, `allocAssumeCapacity` cannot fail and does not
move the array.

**Node** (`node.zig`). The order M is a runtime field of the tree, and the
arrays inside a node are sized for `max_order = 16`. That wastes memory for
small M but keeps the code free of generics. The arrays have one spare slot
so a node can overflow by one key before it is split. The `kind` union is the
chapter in one line: `leaf` has `values`, `prev`, `next`; `internal` has
`children`.

**Search** (`search.zig`). In an internal node the child to follow is
`upperBound(separators, key)`: the number of separators less than or equal to
the key. A key equal to a separator therefore goes right, which matches
copy-up (the separator is the first key of the right leaf).

**Insert** (`insert.zig`). `put` first reserves `height + 1` nodes: one per
level in case every node on the path splits, plus a new root. If that fails
the tree has not been touched. Then `insertInto` recurses to the leaf and
returns `replaced`, `inserted` or `split`; a parent that receives `split`
inserts the separator and may split in turn. The left half of a split keeps
its handle, so the parent's child link and the left neighbour's `next` link
need no update. `splitLeaf` returns `right.keys[0]` without removing it
(copy-up) and splices the new leaf into the chain. `splitInternal` returns
`left.keys[mid]` and keeps it in neither half (push-up).

**Delete** (`delete.zig`). There is no "delete from an internal node" case.
`deleteFrom` removes the entry from its leaf; on the way back up each parent
checks whether its child fell below the minimum and calls `rebalance`, which
is the four steps of the delete rule above as one `if` chain. A leaf merge
*drops* the separator because it was a copy; an internal merge *pulls it
down* because it is real routing information for the children being joined.
Merging is always right into left, so `first_leaf` never changes after the
first insert. Delete never allocates.

**Validate** (`validate.zig`). One recursive pass checks key order, key
bounds from the separators, node sizes, leaf depth, and that the leaves in
tree order are exactly the leaves in chain order, with matching `prev` links.
It also checks the arena: every live slot is reachable and the free list
accounts for the rest. A node's length is checked before it is used to slice
the node's arrays, so a corrupt length is reported, not followed.

### Rust

The structure is the same. The differences come from ownership:

- **No pointers held across calls.** Zig's `insertInto` keeps `n: *Node`
  across the recursive call, which is safe only because of the `reserve` at
  the top of `put`. In Rust the borrow of the node must end before
  `self.insert_into(child, ...)`, so the code copies the child handle out,
  recurses, and fetches the node again. The rule that Zig states in a comment
  is enforced by the compiler.
- **Two nodes at once.** Splits, borrows and merges need two nodes mutably.
  Zig takes two pointers. Rust uses `Arena::pair_mut`, built on
  `slice::get_disjoint_mut`, which checks that the two indices differ.
  Operations with three nodes (parent and two children) read the old
  separator from the parent first and write the new one last.
- **Failure model.** A Rust `Vec` aborts the process when memory runs out, so
  allocation failure is modelled with a node budget:
  `BPlusTree::with_node_budget(order, n)` makes `put` return
  `Err(OutOfNodes)` instead of exceeding `n` nodes.
- **A few tests have no twin.** Zig's `checkAllAllocationFailures` test fails
  each allocation of a build in turn; Rust has no failing allocator to do
  that with, so only the budget test covers failure there (for the same
  reason the copied `ops.zig` has one allocation-failure test more than
  `ops.rs`). Rust adds `pair_mut_gives_two_nodes_at_once` and
  `double_free_panics` for the arena; Zig has no `pair_mut`, and its double
  free is an `assert`.
- **The walker borrows the tree**, so using it across a `put` is a compile
  error. In Zig the same rule is a comment.
- `kind` is an `enum Kind { Leaf(Leaf), Internal(Internal) }`; the accessors
  `leaf()` / `internal()` panic on the wrong kind, as Zig's `n.kind.leaf`
  does in a safe build. `NodeId` is a newtype with a `NIL` constant.

### Output

Both programs print exactly the 87 lines of
[expected_output.txt](expected_output.txt); a test in each language checks
it. Sections 1 to 3 are the build of the worked example above, the chain
walked in both directions, and three lookups. Section 6 is the tie-breaker
example and section 7 a model run of 20000 random operations for M = 3, 4
and 16 with 0 mismatches. Sections 4 and 5 start from the final tree of the
worked example:

```
== 4. Delete: stale separator, borrow, merge, shrink ==
delete 15: no structural change
  get 15 = null, but separators: 6 10 15(stale) 20
delete 17: borrow
  height 3, 10 keys, 8 nodes
  level 0: #7[15]
  level 1: #2[6 10] #6[25]
  leaves : #0(1 3 5) <-> #4(6 7) <-> #1(10 12) <-> #5(20) <-> #3(25 30)
delete 20: borrow
  height 3, 9 keys, 8 nodes
  level 0: #7[15]
  level 1: #2[6 10] #6[30]
  leaves : #0(1 3 5) <-> #4(6 7) <-> #1(10 12) <-> #5(25) <-> #3(30)
delete 25: merge, borrow
  height 3, 8 keys, 7 nodes
  level 0: #7[10]
  level 1: #2[6] #6[15]
  leaves : #0(1 3 5) <-> #4(6 7) <-> #1(10 12) <-> #5(30)
delete 30: borrow
  height 3, 7 keys, 7 nodes
  level 0: #7[10]
  level 1: #2[6] #6[12]
  leaves : #0(1 3 5) <-> #4(6 7) <-> #1(10) <-> #5(12)
delete 12: merge x2, root removed
  height 2, 6 keys, 4 nodes
  level 0: #2[6 10]
  leaves : #0(1 3 5) <-> #4(6 7) <-> #1(10)

== 5. Handles: freed slots are reused ==
arena: 8 slots, 4 live, 4 free; free list: #7 #6 #5 #3
put 11: no structural change
put 13: no structural change
put 14: leaf split (copy-up)
  height 2, 9 keys, 5 nodes
  level 0: #2[6 10 13]
  leaves : #0(1 3 5) <-> #4(6 7) <-> #1(10 11) <-> #7(13 14)
arena: 8 slots, 5 live, 3 free; free list: #6 #5 #3
```

In section 4, `delete 25` merges two leaves (separator 30 is dropped), which
empties internal node `#6`; `#6` then borrows through the root: the stale 15
comes down and 10 goes up. In section 5 the new leaf gets handle `#7`, the
slot of the old root, because it was freed last. In section 7 of the file,
`slots` minus `nodes` is the length of the free list at the end of the run.

## In real databases

**SQLite format (Turso): both kinds of tree in one file.** A table is a
B+tree keyed by rowid; an index is a classic B-tree. The four page types are
`IndexInterior = 2, TableInterior = 5, IndexLeaf = 10, TableLeaf = 13`
(`turso/core/storage/sqlite3_ondisk.rs:506-511`). The cell structs show the
difference: `TableInteriorCell` has only `left_child_page` and `rowid`, while
`IndexInteriorCell` carries a `payload` (`sqlite3_ondisk.rs:813-835`). So a
table interior cell is a pure separator, and an index interior cell is a real
entry that exists nowhere else. The scan code has to account for that: when
an index cursor comes back up from a child, it stops on the divider cell,
"because index interior cells have payloads, so unless we do this we will be
skipping an entry when traversing the tree" (`turso/core/storage/btree.rs:1875-1878`).
Table trees never stop there. When table leaves are rebalanced, the divider
that goes to the parent is built from the left page's id and a rowid read
from a leaf cell, which itself stays in a leaf (`btree.rs:4616-4629`): a
copy-up. The convention differs from ours: in Turso rowids less than or
*equal* to the separator are in the left child (`btree.rs:3106`); here keys
equal to the separator are in the right child. Both work.

**Turso has no sibling links.** The page header fields are page type, first
freeblock, cell count, cell content area, fragmented bytes and, on interior
pages, the right-most child pointer (`btree.rs:110-147`). There is no next or
previous leaf. A scan moves to the next leaf by going up and down a stack of
pages held by the cursor (`struct PageStack`, `btree.rs:8989`). Chapter 08
implements both cursor designs.

**Postgres links every level in both directions.** Each page ends with
`btpo_prev` and `btpo_next` (`postgres/src/include/access/nbtree.h:63-70`),
and "no page" is block 0, `P_NONE` (`nbtree.h:213`), the same idea as
`NodeId.nil`. A split splices the new right page into the chain the way
`splitLeaf` does: `lopaque->btpo_next = rightpagenumber`,
`ropaque->btpo_prev = origpagenumber`, and the old right sibling's
`btpo_prev` is updated last (`postgres/src/backend/access/nbtree/nbtinsert.c:1760, 1769, 1977`).
In Postgres the right link also carries the concurrency scheme; that is
chapter 20.

**Postgres makes every key unique with a tie-breaker.** "The requirement that
all btree keys be unique is satisfied by treating heap TID as a tiebreaker
attribute. Logical duplicates are sorted in heap TID order."
(`postgres/src/backend/access/nbtree/README:42-44`). The heap TID is the
address of the row in the table, which is exactly the "row id" of section 6.

**Handles.** DuckDB's ART index (not a B-tree) refers to nodes by a 64-bit
`IndexPointer` made of a 32-bit buffer id, a 24-bit offset and 8 bits of
metadata (`duckdb/src/include/duckdb/execution/index/index_pointer.hpp:87-93`)
instead of a memory address. Chapter 26 looks at that allocator.

Textbook, not verified in these sources: the names "copy-up" and "push-up",
and the minimum-occupancy rule of ceil(M/2)-1 keys. Real engines measure
fullness in bytes (chapter 12) and several of them never merge (chapter 15).

## Allocator notes

The featured structure is an index arena over a `std.ArrayList` of slots plus
a free list.

- **Why this one.** The tree needs many objects of one size, freed in any
  order, all with the same lifetime as the tree. A slot array gives O(1)
  allocation and free, 4-byte links, and one `deinit` for everything.
- **Which allocator backs it.** Any `std.mem.Allocator`: it is passed to
  `put` and `deinit` and never stored. The array is the only thing that
  allocates, and it does so rarely because `ArrayList` grows geometrically.
  The tests pass `std.testing.allocator`, so a missing `deinit` fails the
  test.
- **Lifetime.** Nodes live until `delete` frees them or the tree is
  deinitialised. The array never shrinks: `slots` in the output is the
  largest number of nodes the tree ever had. Handles are reused, so a handle
  kept after its node was freed may later name a different node. That is the
  handle version of use-after-free; chapter 26 adds generation counters.
- **Allocation failure.** `put` reserves before it modifies anything, so
  `error.OutOfMemory` leaves the tree unchanged. One test proves it with a
  `FixedBufferAllocator` of every size from 0 to 80 slots; another runs
  `std.testing.checkAllAllocationFailures` over a whole build.
- **What would go wrong with others.** One `gpa.create(Node)` per node gives
  8-byte links and needs a tree walk to free everything. An `ArenaAllocator`
  cannot free single nodes, so deleted nodes would stay allocated until the
  tree dies. `MemoryPool` (chapter 05) recycles nodes as well, but hands out
  pointers, which do not carry over to disk pages.

## Pitfalls

- **Removing the separator on a leaf split.** That is push-up applied to a
  leaf: the key disappears from the tree. The copy-up test and the model
  tests catch it.
- **Sending a key equal to a separator to the left.** Use upper bound in
  internal nodes and lower bound in leaves.
- **"Fixing" stale separators.** Rewriting ancestors after every delete is
  work for no gain, and a validator that demands every separator to exist in
  a leaf is wrong.
- **Forgetting one of the four link updates.** A leaf split writes
  `left.next`, `right.prev`, `right.next` and `old_next.prev` (or
  `last_leaf`). A merge writes `left.next` and `next.prev` (or `last_leaf`).
  `validate` compares the chain with the tree in both directions for this
  reason.
- **Dropping the separator in an internal merge**, or keeping it in a leaf
  merge. The two cases are opposites.
- **Holding a `*Node` across an allocation** (Zig). The array may move. Here
  that is prevented by reserving at the top of `put`; if you add an
  allocation elsewhere, fetch the pointer again afterwards.
- **Using a handle after `free`.** It may already name a new node.

## Exercises

1. (easy) Insert 1 to 10 in ascending order with M = 4 by hand. Draw the final
   tree. How full are the leaves, and why?
2. (easy) In the final tree of the worked example, delete 6 and then 7. Which
   separators change, and which stale separator appears?
3. (medium) Write `min()` and `max()` that return the smallest and largest
   entry without descending from the root. Then write `countLeaves()` using
   only the chain.
4. (medium) `validate` accepts stale separators. Write a stricter
   `separatorsAreLeafKeys()` and find the shortest operation sequence from the
   demo program after which it returns false. Explain why the tree is still
   correct.
5. (hard) Change the leaf split so that it stores, as separator, any value `s`
   with `last key of left < s <= first key of right` (for example the midpoint
   of the two keys). Which functions need to change? Which tests still pass?

Solutions are in [solutions.md](solutions.md).

## Links

- Previous: [chapter 06, testing a B-tree](../06-testing-a-btree/README.md)
- Next: [chapter 08, range scans and cursors](../08-range-scans-and-cursors/README.md)
- Visualization: [viz/index.html](viz/index.html) (B-tree and B+tree side by
  side for the same keys)
