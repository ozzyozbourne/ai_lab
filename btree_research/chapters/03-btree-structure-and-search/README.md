# Chapter 03: B-tree structure and search

## What you will learn

- What a B-tree is: the definition, written as six invariants.
- The word "order" and why three textbooks use three different numbers for the same tree.
- What a 2-3-4 tree is, and why it is the same thing as a red-black tree.
- Why a B-tree with n keys cannot be tall: the height bound, with its proof.
- How `get` walks from the root to a leaf, and how an in-order traversal lists all keys.
- A first look at `validate`, the function that turns the invariants into code, and at
  testing against an oracle. [Chapter 06](../06-testing-a-btree/README.md) goes deep.
- The simplest allocator there is, a bump allocator, written by hand; then
  `std.heap.ArenaAllocator`, which does the same job.

Prerequisites: [chapter 01](../01-why-btrees/README.md) (why wide nodes: count node reads,
not comparisons) and [chapter 02](../02-searching-a-sorted-node/README.md) (lower bound
inside one sorted node).

This chapter has no insert and no delete. Trees are built by hand, node by node, so that
the structure can be studied on its own. Insertion is
[chapter 04](../04-insertion-and-splitting/README.md), deletion is
[chapter 05](../05-deletion-and-rebalancing/README.md).

## The idea in plain words

A binary search tree has one key per node and two children. A B-tree has several sorted
keys per node and one more child than keys. The keys of a node cut the key space into
ranges, and each child holds one range:

```
              [6 10 20]
             /   |   |  \
   below 6   6..10  10..20   above 20
```

A B-tree of **order M** is a tree whose nodes hold `u64` keys (each with a value) and
obey these rules. In this guide M is the maximum number of children.

1. **Order inside a node.** The keys of a node are strictly ascending.
2. **Search-tree property.** In an interior node with keys k0 < k1 < ... , every key in
   child i is larger than k(i-1) and smaller than k(i). A child's range is passed down:
   its own children must stay inside it.
3. **Capacity.** A node holds at most M - 1 keys.
4. **Minimum fill.** Every node except the root holds at least ceil(M/2) - 1 keys. The
   root holds at least 1 key. (An empty tree has no root at all.)
5. **Children.** An interior node with n keys has exactly n + 1 children. A leaf has none.
6. **Balance.** All leaves are at the same depth.

This is the plain B-tree: every key is stored exactly once, in a leaf or in an interior
node, together with its value. The B+tree, which keeps all values in the leaves, is
[chapter 07](../07-bplus-trees/README.md).

Rules 1 and 2 make search possible. Rules 3 and 4 say how wide a node is. Rules 4 and 6
together make the tree short, which is the whole point (see the height bound below).

### Order: one tree, three vocabularies

Textbooks do not agree on the parameter. The tree is the same; only the number that
names it differs.

| Source | Parameter | Keys per node (non-root) | Children per interior node (non-root) | Our M |
|---|---|---|---|---|
| Knuth, *The Art of Computer Programming* vol. 3 (this guide) | order **M** = maximum children | ceil(M/2) - 1 to M - 1 | ceil(M/2) to M | M |
| Cormen, Leiserson, Rivest, Stein (CLRS) | minimum degree **t** = minimum children | t - 1 to 2t - 1 | t to 2t | 2t |
| Bayer and McCreight (1972) | **k** = minimum keys | k to 2k | k + 1 to 2k + 1 | 2k + 1 |
| Real storage engines | page size in **bytes** | as many as fit; "underfull" is a share of the page | follows from the bytes | varies per page |

The table is textbook material; none of these books is among the sources in `db_study/`.
Things to remember:

- CLRS can only describe even M (M = 2t). Bayer and McCreight can only describe odd M
  (M = 2k + 1). Knuth's M covers both.
- The default of this guide, M = 4, is t = 2 in CLRS and has no k.
- "A B-tree of order 5" in a Bayer-and-McCreight text has up to 11 children. Always check
  which definition a text uses before comparing numbers.
- CLRS counts height in edges (a single leaf has height 0). This guide counts levels (a
  single leaf has height 1), as `shape.height` in the code does.

> **History.** Rudolf Bayer and Edward McCreight described the B-tree at Boeing in 1970
> and published it in 1972 ("Organization and Maintenance of Large Ordered Indexes").
> They never said what the B stands for. Knuth's volume 3 (1973) introduced "order M"
> as the maximum number of children. In the same year, 1972, Bayer described "symmetric
> binary B-trees": a binary encoding of the B-tree with 2, 3 or 4 children per node.
> Guibas and Sedgewick (1978) drew the same structure with red and black links, which is
> the name that stuck. (Textbook history, not verified against the papers here.)

### 2-3-4 trees and red-black trees

With M = 4 a node has 1, 2 or 3 keys, so an interior node has 2, 3 or 4 children. Such a
tree is called a **2-3-4 tree**. It is the smallest B-tree in which a full node can be
split in the middle with one key left over, and it is small enough to draw.

Every 2-3-4 tree is a red-black tree in disguise. Draw each node as a small binary tree:
one black node on top, the other keys as red children.

```
 [b]        [a b]          [a b c]

  b           b               b            black
             /               / \
            a               a   c          red
```

A red node means "I share a 2-3-4 node with my parent". The subtrees hang below in the
same left-to-right order. (With two keys the red node could also go to the right; the
code always puts it on the left.) The red-black rules are the B-tree rules in this
encoding:

- A red node has no red child, because a 2-3-4 node has at most three keys: one black,
  two red.
- Every path from the root to a missing child passes the same number of black nodes,
  because every black node is one 2-3-4 node and all 2-3-4 leaves are at one depth.

So the number of black nodes on a path is the height of the 2-3-4 tree, and a path is at
most twice as long as another. `redblack.zig` / `redblack.rs` do the conversion and check
both rules. A red-black tree is what you get when a 2-3-4 tree has to live in memory with
one key per allocation; a B-tree is what you get when a node should fill a disk page.

### The height bound

**Claim.** A B-tree of order M with n >= 1 keys and h levels satisfies, with
t = ceil(M/2):

```
log_M(n + 1)  <=  h  <=  1 + log_t((n + 1) / 2)
```

**Proof of the upper bound.** Count the fewest keys a tree with h levels can hold.

- Level 1 is the root. It has at least 1 key (rule 4), so at least 2 children (rule 5).
- Level 2 therefore has at least 2 nodes. Each of them is not the root, so it has at
  least t - 1 keys (rule 4) and, if it is interior, at least t children (rule 5).
- By induction, level i (for i >= 2) has at least 2 * t^(i-2) nodes. Rule 6 guarantees
  that every level up to h is complete: no branch may stop early.

Add up the keys, t - 1 in every node below the root:

```
n  >=  1 + (t - 1) * (2 + 2t + 2t^2 + ... + 2t^(h-2))
    =  1 + (t - 1) * 2 * (t^(h-1) - 1) / (t - 1)
    =  2 * t^(h-1) - 1
```

So t^(h-1) <= (n + 1) / 2. Taking the logarithm to base t gives the upper bound.

**Proof of the lower bound.** A tree with h levels has at most M^(i-1) nodes on level i
and at most M - 1 keys per node (rule 3), so
n <= (M - 1)(1 + M + ... + M^(h-1)) = M^h - 1.

**Worked example.** One million keys.

- M = 4, so t = 2. Upper bound: 1 + log2(500000.5) = 1 + 18.93..., so h <= 19.
  Lower bound: log4(1000001) = 9.97..., so h >= 10.
- M = 256, so t = 128. 128^2 = 16384 and 128^3 = 2097152, so log128(500000.5) is between
  2 and 3 and h <= 3. Lower bound: 256^2 = 65536 < 1000001 <= 256^3, so h >= 3. The
  height is exactly 3.

Both results are printed by the programs (part 5 below) and asserted in a test. The
proof uses every rule except 1 and 2. Drop rule 4 or rule 6 and the bound is gone, which
is why `validate` checks them even though a lookup never notices when they are broken.

## A worked example by hand

The canonical tree of this guide is what inserting 10, 20, 5, 6, 12, 30, 7, 17, 3, 25,
1, 15 in that order produces at M = 4 (chapter 04 shows the steps). Here it is built
directly:

```
                 [6 10 20]
    [1 3 5]  [7]  [12 15 17]  [25 30]
```

Check the rules: each node is sorted (1). The leaf `[7]` lies between 6 and 10, the
leaf `[12 15 17]` between 10 and 20 (2). No node has more than 3 keys (3) or fewer than
1 (4). The root has 3 keys and 4 children (5). All leaves are on level 2 (6).

**Search for 17.** In the root, find the first key that is not smaller than 17
(the lower bound of chapter 02). That is 20, at index 2. It is not 17, and the node is
not a leaf, so go to child 2. Why child 2? Two keys of the root (6 and 10) are smaller
than 17, so 17 can only be in the range between 10 and 20. In the leaf `[12 15 17]` the
lower bound is index 2, and the key there is 17. Found, after reading 2 nodes.

**Search for 8.** Root: the lower bound is 10 at index 1, not equal, go to child 1. Leaf
`[7]`: the lower bound is index 1, past the end. A leaf has no children, so 8 is absent.

**Search for 10.** Root: the lower bound is 10 itself. Found after reading 1 node. In a
plain B-tree a search can end in an interior node.

**In-order traversal.** Visit child 0, key 0, child 1, key 1, ..., last child:
`[1 3 5]`, 6, `[7]`, 10, `[12 15 17]`, 20, `[25 30]`. The keys come out sorted, and that
is rule 2 at work.

**The 2-3-4 tree as a red-black tree.** The root `[6 10 20]` becomes black 10 with red
children 6 and 20. `[1 3 5]` becomes black 3 with red 1 and 5, `[7]` becomes black 7,
`[12 15 17]` becomes black 15 with red 12 and 17, `[25 30]` becomes black 30 with red
left child 25. Every path passes 2 black nodes; the longest has 4 nodes, the shortest 3.

## Code walk-through

Both programs print the same text (`expected_output.txt`); a test in each language
compares. Run them with `zig build run` and `cargo run`.

### Zig (`zig/src/`)

| File | Content |
|---|---|
| `base_node.zig`, `base_search.zig`, `base_validate.zig`, `base_stats.zig`, `base_pool.zig` | Copied from chapter 05 (the complete tree), trimmed to what a read-only tree needs |
| `bump.zig` | `BumpAllocator`, a hand-written `std.mem.Allocator` |
| `tree.zig` | `HandTree(M, PoolFn)`: `leaf`, `interior`, `fromSorted`, `get`, `inOrder`, `validate`, `deinit`; `canonical` |
| `trace.zig` | `explainGet`: `get` with one printed phrase per decision |
| `height.zig` | `minKeys`, `maxKeys`, `minHeight`, `maxHeight` |
| `broken.zig` | Ten corruptions, one per error of `validate` |
| `redblack.zig` | `fromTree`, `check` |
| `scenario.zig` | What `zig build run` prints |

**The node** (`base_node.zig`). `Node(M)` is a struct with `len`, `leaf`, and three
fixed arrays: `keys: [M]u64`, `values: [M]u64`, `children: [M + 1]?*Node`. The arrays
have one slot more than a legal node needs. Chapter 04 uses the spare slot to overflow a
node before splitting it; here it lets `broken.zig` build an overfull node.

**Building by hand** (`tree.zig`).

```zig
var t: Tree4 = .empty;
const a = try t.leaf(gpa, &.{ 1, 3, 5 });
const b = try t.leaf(gpa, &.{7});
const c = try t.leaf(gpa, &.{ 12, 15, 17 });
const d = try t.leaf(gpa, &.{ 25, 30 });
t.root = try t.interior(gpa, &.{ 6, 10, 20 }, &.{ a, b, c, d });
```

`leaf` and `interior` check nothing about the six rules. The same builder makes valid
trees and broken ones, and `validate` is the only judge. `fromSorted` builds a valid tree
of minimal height from sorted keys by dealing them out top-down; it exists so that tests
can check big trees (bulk loading done properly is
[chapter 16](../16-bulk-loading/README.md)).

**Search** (`base_search.zig`). The whole algorithm:

```zig
pub fn get(comptime M: usize, root: ?*const Node(M), key: u64) ?u64 {
    var node = root orelse return null;
    while (true) {
        const i = lowerBound(node.keySlice(), key);
        if (i < node.len and node.keys[i] == key) return node.values[i];
        if (node.leaf) return null;
        node = node.children[i].?;
    }
}
```

One call of `lowerBound` answers two questions: where the key would be in this node,
and which child to follow if it is not here. The loop runs once per level, so a search
reads at most h nodes and makes about log2(M) comparisons in each. `inOrder` is the
recursive walk "child i, then key i".

**Validate** (`base_validate.zig`). `check(node, lo, hi, is_root, depth)` receives the
open interval (lo, hi) that the node's keys must lie in. It checks the node's size, its
order and the interval, then calls itself for child i with the interval narrowed to
(keys[i-1], keys[i]). The first leaf sets the expected depth; every later leaf is
compared with it. After the walk, the number of keys met is compared with `tree.len`,
and the number of nodes reached with the number of nodes created. It returns the first
violation as an error.

Checking only "each child key is on the correct side of its parent key" would not be
enough. A key deep in the tree must respect the separators of all its ancestors, which
is why the bounds are passed down.

**Broken trees** (`broken.zig`). Each case changes one thing in the canonical tree.
Part 4 of the output shows what `validate` says and how many of the 12 keys `get` still
finds. Three cases still answer every lookup correctly (an overfull node, leaves at
different depths, an unreachable node), and case 2 hides a key that is physically in
the tree. Query tests alone would not find these.

**Oracle test** (`tree.zig`, "seeded model test"). An oracle is a second implementation
that is too simple to be wrong. Here it is one `bool` per possible key, filled from the
shared SplitMix64 generator. The tree is built from the same keys, and `get` must agree
with the oracle for every possible key, present or absent, for several orders and seeds.

### Rust (`rust/src/`)

The files have the same names and the tests the same names, with these differences.

- **No pointers.** A node is named by its index, `NodeId(u32)`, into a typed arena
  (`arena.rs`: a `Vec<Node>` that is only pushed to). A parent holds the ids of its
  children. Indices are `Copy`, stay valid when the `Vec` grows, and need no lifetimes.
- **Order at run time.** Stable Rust cannot size an array from a const generic
  expression (`[u64; M - 1]`), so `order` is a field of the tree and a node holds three
  `Vec`s. An overfull node needs no spare slot: a `Vec` does not know about M.
- **No allocator parameter and no `deinit`.** The tree owns its arena; dropping the tree
  frees every node. There is no `bump.rs`: the arena is the bump allocator.
- **Out of memory.** Rust aborts when the global allocator fails, so the arena has a
  node budget and `alloc` returns `Err(OutOfNodes)`. Zig tests real allocation failure
  with `std.testing.checkAllAllocationFailures`.
- **Missing child.** In Zig a missing child is a null pointer in the array. In Rust it
  is a `children` vector that is too short. For a tree with two defects this changes
  which one `validate` reports (see Pitfalls).
- **Visitors.** `in_order` takes a closure; Zig takes any value with a `visit` method.

### Output

```
== 1. The canonical tree, built by hand (M = 4: 1 to 3 keys per node) ==
  [6 10 20]
  [1 3 5] [7] [12 15 17] [25 30]
shape: height=2 nodes=5 leaves=4 keys=12 fill=80%
validate: ok
node storage: 5 nodes created, 0 freed one by one, all released together

== 2. Search reads one node per level ==
get 10: [6 10 20] has it at index 1 -> value 100 (1 node read)
get 17: [6 10 20] child 2 -> [12 15 17] has it at index 2 -> value 170 (2 nodes read)
get 1: [6 10 20] child 0 -> [1 3 5] has it at index 0 -> value 10 (2 nodes read)
get 8: [6 10 20] child 1 -> [7] is a leaf without it -> absent (2 nodes read)
get 31: [6 10 20] child 3 -> [25 30] is a leaf without it -> absent (2 nodes read)

== 3. In-order traversal visits the keys in ascending order ==
1 3 5 6 7 10 12 15 17 20 25 30

== 4. Break the canonical tree on purpose: one change, one broken invariant ==
 1. leaf [12 15 17] reordered to [12 17 15]
    validate: KeysOutOfOrder; get finds 11 of 12 keys
 2. leaf [7] holds 11 instead: sorted, but on the wrong side of separator 10
    validate: KeyOutsideParentBounds; get finds 11 of 12 keys
 3. leaf [12 15 17] gets a fourth key, 18
    validate: NodeOverfull; get finds 12 of 12 keys
 4. leaf [7] loses its only key
    validate: NodeUnderfull; get finds 11 of 12 keys
 5. the root's key count is set to 0
    validate: EmptyRoot; get finds 3 of 12 keys
 6. leaf [12 15 17] becomes interior [15] above new leaves [12] and [17]
    validate: LeavesAtDifferentDepths; get finds 12 of 12 keys
 7. the root's last child pointer is erased
    validate: MissingChild; get not tried (it could follow the erased pointer)
 8. leaf [7] gets a child pointer
    validate: UnexpectedChild; get finds 12 of 12 keys
 9. key 5 vanishes from leaf [1 3 5], the tree still claims 12 keys
    validate: WrongKeyCount; get finds 11 of 12 keys
10. a sixth node is allocated but nothing points to it
    validate: NodeCountMismatch; get finds 12 of 12 keys

== 5. Height: how few and how many keys fit ==
sparsest tree with 3 levels at M = 4 (7 keys):
  [4]
  [2] [6]
  [1] [3] | [5] [7]
fullest tree with 2 levels at M = 4 (15 keys):
  [4 8 12]
  [1 2 3] [5 6 7] [9 10 11] [13 14 15]
keys in a tree of h levels: 2*t^(h-1) - 1 up to M^h - 1, with t = ceil(M/2)
  M=4: h=1: 1..3 h=2: 3..15 h=3: 7..63 h=4: 15..255
  M=256: h=1: 1..255 h=2: 255..65535 h=3: 32767..16777215 h=4: 4194303..4294967295
possible heights for n keys (shortest..tallest):
  n=12: M=4: 2..3 M=16: 1..1 M=256: 1..1 M=1024: 1..1
  n=1000: M=4: 5..9 M=16: 3..3 M=256: 2..2 M=1024: 1..1
  n=1000000: M=4: 10..19 M=16: 5..7 M=256: 3..3 M=1024: 2..3
  n=1000000000: M=4: 15..29 M=16: 8..10 M=256: 4..5 M=1024: 3..4

== 6. The 2-3-4 tree as a red-black tree ==
  [6 10 20] -> 10 black, red children 6 and 20
  [1 3 5] -> 3 black, red children 1 and 5
  [7] -> 7 black
  [12 15 17] -> 15 black, red children 12 and 17
  [25 30] -> 30 black, red left child 25
red-black tree: 12 nodes, 2 black nodes on every path (B-tree height 2), paths of 3 to 4 nodes

== 7. Oracle check: 608 of the keys 0..1999 (seed 3), several orders ==
  M=3: height=6 (bounds 6..9) nodes=364 fill=83% validate ok, 2000 of 2000 lookups agree
  M=4: height=5 (bounds 5..9) nodes=241 fill=84% validate ok, 2000 of 2000 lookups agree
  M=5: height=4 (bounds 4..6) nodes=156 fill=97% validate ok, 2000 of 2000 lookups agree
  M=8: height=4 (bounds 4..5) nodes=93 fill=93% validate ok, 2000 of 2000 lookups agree
```

In part 5, "the sparsest tree with 3 levels" has 7 keys and "the fullest tree with 2
levels" has 15: more keys, fewer levels. Part 7 uses `fromSorted`, which always produces
the shortest tree, so the heights sit on the lower bound. Trees grown by insertion
(chapter 04) land between the bounds.

## In real databases

- **A 2-3-4 tree in production code.** Milvus uses the Go library `google/btree` in two
  small in-memory places, both created with degree 2: `btree.New(2)` in
  `milvus/internal/kv/mem/mem_kv.go:51-55` and `btree.NewG(2, ...)` in
  `milvus/internal/streamingcoord/server/broadcaster/schema.go:90`. That degree 2 means
  1 to 3 items per node (CLRS t = 2, our M = 4) is the library's documented behaviour;
  the library source is not in the checkout, so this is **unverified** here.
- **Keys in interior nodes.** Turso's index B-tree is a plain B-tree like the one in
  this chapter. An interior cell carries a full payload, not just a routing key
  (`IndexInteriorCell`, `turso/core/storage/sqlite3_ondisk.rs:828-835`), and a forward
  scan that comes back up from a child must stop on that cell before entering the next
  child (`turso/core/storage/btree.rs:1875-1879`). That is our in-order traversal:
  child, key, child. Turso's table B-tree is a B+tree instead (chapter 07).
- **Order in bytes.** Real pages hold variable-size entries, so there is no M. Postgres
  says so directly: "there is not a fixed maximum number of keys per page; we just stuff
  in as many as will fit" (`postgres/src/backend/access/nbtree/README:158-164`). Its
  only hard rule is that three items must fit on a page, so one item is limited to a
  third of the page (`postgres/src/include/access/nbtree.h:155-173`). Turso treats a
  page as underfull when more than two thirds of its usable bytes are free
  (`turso/core/storage/btree.rs:3429-3430`, `:10836-10848`). The role of rule 4, a lower
  limit on fill that keeps the tree short, is the same; the unit is bytes.
- **Not B-trees.** DuckDB, TigerBeetle and FAISS have no B-tree (see PLAN.md); nothing
  in this chapter describes them.

## Allocator notes

**The lifetime.** A tree of this chapter is built once and never changes. No node dies
before the tree does. So the allocator never needs to take a single node back, and
"free everything at once" is all the freeing there is.

**First by hand: `BumpAllocator`** (`bump.zig`). It owns a chunk of memory and a cursor.
To allocate: round the cursor up to the alignment, return that address, advance the
cursor. When the chunk is full it asks its child allocator for another chunk. `free`
does nothing. `deinit` gives every chunk back. It implements the four functions of
`std.mem.Allocator` (`alloc`, `resize`, `remap`, `free`), so any code that takes an
`Allocator` runs on it; a test appends 1000 items to an `ArrayList` on it.

**Used as the node pool.** The tree gets nodes from a pool (`base_pool.zig`, the
contract that chapters 04 and 05 fill with other pools). `DirectNodes` calls
`gpa.create` once per node, so the allocator handed to `leaf` and `interior` decides
where nodes live:

| Allocator passed in | Where nodes live | Teardown |
|---|---|---|
| `std.testing.allocator` | one tracked allocation each | `tree.deinit(gpa)` walks the tree and destroys node by node |
| `BumpAllocator` | next to each other in a chunk | `bump.deinit()`: one free per chunk, no walk |
| `std.heap.ArenaAllocator` | the same | `arena.deinit()`, or `arena.reset(.retain_capacity)` to reuse the memory |

The test "the same builder on three allocators" runs all three and gets the same tree.
Parts 1 to 3 of `zig build run` use the bump allocator; the rest uses one arena.

**Then `std.heap.ArenaAllocator`.** It is the same idea from the standard library, with
more care: it also takes back the most recent allocation, it can keep its memory across
a `reset`, and its `Allocator` is thread-safe when the child allocator is (see the
comment at the top of `lib/std/heap/ArenaAllocator.zig`). Use it; the hand-written one
is there to show that there is no magic.

**Why this fits.**

- *No walk at teardown.* Freeing node by node means visiting every node, which for a
  tree on disk-sized pages means touching all of it just to throw it away.
- *A broken or half-built tree can still be freed.* `deinit` follows child pointers, so
  it needs a valid tree. The ten broken trees cannot be freed that way, and neither can
  a build that failed half-way: there is no root yet. With an arena both are one call.
  `checkAllAllocationFailures` fails every allocation of a build in turn and finds no
  leak.
- *Neighbours in memory.* Nodes created one after the other are adjacent (a test checks
  the addresses; a `Node(4)` is 120 bytes on the 64-bit target used here), with no
  per-node header between them.

**What would go wrong with a different choice.**

- A bump allocator or arena in a tree that deletes: every merged node stays allocated
  until the tree dies. Memory use only grows. Chapter 05 uses a free list for that
  reason.
- A general-purpose allocator here: correct, but one bookkeeping entry per node, and the
  walk at teardown. In tests it is still the right choice once, because
  `std.testing.allocator` reports every node that was forgotten.
- Forgetting the lifetime: after `bump.deinit()` every node pointer dangles. The tree
  must not outlive its allocator. Zig does not check this; Rust's ownership does.

**Rust.** `Arena` is a `Vec<Node>` plus a budget. Dropping it frees all nodes. It is not
a single deallocation, though: each Rust node owns three small `Vec`s of its own, which
are freed one by one when the arena is dropped. The Zig node is one flat block.

## Pitfalls

- **"Order" without a definition.** Order 4 here is t = 2 in CLRS. Always say which
  parameter you mean (see the table).
- **Checking a child only against its parent.** A key must lie inside the range given by
  all its ancestors. `validate` passes (lo, hi) down for that reason.
- **Using `<=` for the bounds.** Keys are unique, so a key equal to a separator is a
  duplicate. The bounds are strict.
- **Assuming a search ends in a leaf.** In a plain B-tree it can end in any node. Code
  that scans "all leaves" misses the keys stored in interior nodes; an in-order
  traversal must emit a key between two children.
- **Trusting lookups as a test.** Three of the ten broken trees answer every `get`
  correctly. Run `validate` after every operation in tests.
- **Reading meaning into which error `validate` returns.** It returns the first
  violation its walk meets. For a tree with two defects the Zig and Rust versions can
  name different ones (a test in `broken.zig` / `broken.rs` shows a case). Any error
  means the tree is broken; fix, re-run.
- **Height in edges or in levels.** CLRS's bound is h <= log_t((n + 1) / 2) with h in
  edges; ours has "1 +" because we count levels.
- **Keeping node pointers after the arena is gone.** See Allocator notes.

## Exercises

1. (easy) On the canonical tree, trace `get(15)`, `get(26)` and `get(6)` by hand. For
   each, list the nodes read, the lower-bound index in each node, and the result.
2. (easy) A B-tree of order M = 5 holds 100 keys. What are the smallest and the largest
   possible height? Then: how many keys does a tree of order 5 need before it can have
   5 levels?
3. (medium) Take the canonical tree and apply two corruptions at once: leaf `[7]`
   becomes `[11]`, and leaf `[12 15 17]` becomes `[12 17 15]`. Which error does
   `validate` return, and why? Then find a pair of corruptions for which the Zig and the
   Rust `validate` return different errors, and explain the difference from the code.
4. (medium) The conversion puts the red node of a two-key node on the left. How many
   different red-black trees represent the canonical tree if the red node may go on
   either side? Give a formula for any 2-3-4 tree. Why does a three-key node offer no
   choice?
5. (harder) Write `successor(root, key)`: the smallest key that is strictly greater
   than `key`, or null. Use one walk from the root to a leaf, no allocation and no
   parent pointers. Which variable has to survive from the upper levels, and why?

Solutions: [solutions.md](solutions.md).

## Links

- Visualization: [viz/index.html](viz/index.html) (search and in-order traversal with a
  predict mode, the invariant checker on broken trees, the 2-3-4 tree unfolding into a
  red-black tree).
- Previous: [Chapter 02: Searching a sorted node](../02-searching-a-sorted-node/README.md)
- Next: [Chapter 04: Insertion and splitting](../04-insertion-and-splitting/README.md)
