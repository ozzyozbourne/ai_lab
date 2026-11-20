# Chapter 03: B-tree structure and search

## What you will learn

- What a B-tree is: the definition, written as six invariants.
- The word "order" and why three textbooks use three different numbers for the same tree.
- What a 2-3-4 tree is, and why it is the same thing as a red-black tree.
- Why a B-tree with n keys cannot be tall: the height bound, with its proof.
- How `get` walks from the root to a leaf, and how an in-order traversal lists all keys.
- A first look at `validate`, which turns the invariants into code, and at testing
  against an oracle ([chapter 06](../06-testing-a-btree/README.md) goes deep).
- A bump allocator written by hand, then `std.heap.ArenaAllocator`.

Prerequisites: [chapter 01](../01-why-btrees/README.md) (why wide nodes: count node reads,
not comparisons) and [chapter 02](../02-searching-a-sorted-node/README.md) (lower bound
inside one sorted node).

This chapter has no insert and no delete: trees are built by hand. Insertion is
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

Some words first.

- The **root** is the node without a parent. A **leaf** is a node without children; a
  node with children is an **interior node**. The root can be either.
- The **subtree** below a child is that child and everything reachable from it.
- **Levels** count from the top: the root is on level 1, its children on level 2. The
  **height** of a tree is its number of levels. The guide always says level; the code's
  `depth` starts at 0 in the root (depth = level - 1), hence the error name
  `LeavesAtDifferentDepths`.
- ceil(x) rounds up: ceil(5/2) = 3.

A B-tree of **order M** is a tree whose nodes hold `u64` keys (each with a value) and
obey these six rules. In this guide M is the maximum number of children.

1. **Order inside a node.** The keys of a node are strictly ascending.
2. **Search-tree property.** Take an interior node with n keys k(0) < ... < k(n-1) and
   its children 0 to n. Every key in the subtree below child i is larger than k(i-1)
   and smaller than k(i). The first child has no k(-1) and the last child has no k(n):
   on that side the limit is the one the node itself got from its ancestors. The root
   has no ancestors, so there the side is open.
3. **Capacity.** A node holds at most M - 1 keys.
4. **Minimum fill.** Every node except the root holds at least ceil(M/2) - 1 keys. The
   root holds at least 1 key. (An empty tree has no root at all.)
5. **Children.** An interior node with n keys has exactly n + 1 children. A leaf has none.
6. **Balance.** All leaves are on the same level.

What rules 3 to 5 allow for a node that is not the root:

| Order M | Keys | Children, if interior |
|---|---|---|
| 3 | 1 to 2 | 2 to 3 |
| 4 | 1 to 3 | 2 to 4 |
| 5 | 2 to 4 | 3 to 5 |
| 6 | 2 to 5 | 3 to 6 |

At M = 3 and M = 4 the minimum is one key, so rule 4 only forbids an empty node. From
M = 5 on it asks for more (the worked example shows a tree that fails it).

This is the plain B-tree: every key is stored exactly once, in a leaf or in an interior
node, with its value. Keys are unique, so the bounds in rule 2 are strict. The B+tree,
which keeps all values in the leaves, is [chapter 07](../07-bplus-trees/README.md).

Rules 1 and 2 make search possible. Rules 4 and 6 together make the tree short, which
is the whole point (see the height bound below).

### Order: one tree, three vocabularies

Textbooks do not agree on the parameter. The tree is the same; only its name differs.

| Source | Parameter | Keys per node (non-root) | Children per interior node (non-root) | Our M |
|---|---|---|---|---|
| Knuth, *The Art of Computer Programming* vol. 3 (this guide) | order **M** = maximum children | ceil(M/2) - 1 to M - 1 | ceil(M/2) to M | M |
| Cormen, Leiserson, Rivest, Stein (CLRS) | minimum degree **t** = minimum children | t - 1 to 2t - 1 | t to 2t | 2t |
| Bayer and McCreight (1972) | **k** = minimum keys | k to 2k | k + 1 to 2k + 1 | 2k + 1 |
| Real storage engines | page size in **bytes** | as many as fit; "underfull" is a share of the page | follows from the bytes | varies per page |

The table is textbook material (the books are not among the sources in `db_study/`).

- CLRS can only describe even M (M = 2t). Bayer and McCreight can only describe odd M
  (M = 2k + 1). Knuth's M covers both.
- The default of this guide, M = 4, is t = 2 in CLRS and has no k.
- CLRS counts height in edges (a single leaf has height 0). This guide counts levels (a
  single leaf has height 1), as `shape.height` in the code does.

> **History.** Bayer and McCreight published the B-tree in 1972 and never said what
> the B stands for. In the same year Bayer described a binary encoding of the B-tree
> with 2, 3 or 4 children per node; Guibas and Sedgewick (1978) drew it with red and
> black links, the name that stuck. (Textbook history, not verified here.)

### 2-3-4 trees and red-black trees

With M = 4 a node has 1, 2 or 3 keys, so an interior node has 2, 3 or 4 children. Such a
tree is called a **2-3-4 tree**.

A **red-black tree** is a binary search tree (one key and at most two children per
node) in which every node is red or black, kept balanced by three rules about the
colours. Every 2-3-4 tree is a red-black tree in disguise. Draw each node as a small
binary tree: one black node on top, the other keys as red children.

```
 [b]        [a b]          [a b c]

  b           b               b            black
             /               / \
            a               a   c          red
```

A red node means "I share a 2-3-4 node with my parent". The subtrees hang below in the
same left-to-right order. (With two keys the red node could also go to the right; the
code always puts it on the left.) The three rules are the B-tree rules in this encoding:

- The root is black, because the top of the root's 2-3-4 node is its black node.
- A red node has no red child, because a 2-3-4 node has at most three keys: one black,
  two red.
- Every path from the root to a missing child passes the same number of black nodes,
  because every black node is one 2-3-4 node and all 2-3-4 leaves are on one level.

So the number of black nodes on a path is the height of the 2-3-4 tree, and a path is at
most twice as long as another. `redblack.zig` / `redblack.rs` do the conversion and check
the three rules, plus the order of the keys as in any binary search tree.

### The height bound

Write d for ceil(M/2), the fewest children of an interior node that is not the root
(the table above). For even M, d is the t of CLRS; d also exists for odd M.

**Claim.** A B-tree of order M with n >= 1 keys and h levels satisfies:

```
log_M(n + 1)  <=  h  <=  1 + log_d((n + 1) / 2)
```

**Proof of the upper bound.** Count the fewest keys a tree with h levels can hold.

- Level 1 is the root. It has at least 1 key (rule 4), so at least 2 children (rule 5).
- Level 2 therefore has at least 2 nodes. Each of them is not the root, so it has at
  least d - 1 keys (rule 4) and, if it is interior, at least d children (rule 5).
- By induction, level i (for i >= 2) has at least 2 * d^(i-2) nodes. Rule 6 guarantees
  that every level up to h is complete: no branch may stop early.

Add up the keys, d - 1 in every node below the root:

```
n  >=  1 + (d - 1) * (2 + 2d + 2d^2 + ... + 2d^(h-2))
    =  1 + (d - 1) * 2 * (d^(h-1) - 1) / (d - 1)
    =  2 * d^(h-1) - 1
```

So d^(h-1) <= (n + 1) / 2. Taking the logarithm to base d gives the upper bound.

**Proof of the lower bound.** A tree with h levels has at most M^(i-1) nodes on level i
and at most M - 1 keys per node (rule 3), so
n <= (M - 1)(1 + M + ... + M^(h-1)) = M^h - 1.

**Worked example.** One million keys.

- M = 4, so d = 2. Upper bound: 1 + log2(500000.5) = 19.93..., so h <= 19.
  Lower bound: log4(1000001) = 9.97..., so h >= 10.
- M = 256, so d = 128. 128^2 = 16384 and 128^3 = 2097152, so h <= 3. Lower bound:
  256^2 = 65536 < 1000001, so h >= 3. The height is exactly 3.

The programs print both results (part 5) and a test asserts them. Drop rule 4 or
rule 6 and the bound is gone, which is why `validate` checks them although no lookup
notices when they are broken.

## A worked example by hand

The canonical tree of this guide is what inserting 10, 20, 5, 6, 12, 30, 7, 17, 3, 25,
1, 15 in that order produces at M = 4 (chapter 04 shows the steps). Here it is built
directly:

```
                 [6 10 20]
    [1 3 5]  [7]  [12 15 17]  [25 30]
```

Check the rules: every node is sorted (1). `[1 3 5]` is the first child, so its only
limit is "below 6"; `[7]` lies between 6 and 10; `[12 15 17]` between 10 and 20;
`[25 30]` is the last child, so its only limit is "above 20" (2). Every node has 1 to 3
keys (3, 4); the root has 3 keys and 4 children, the leaves have none (5); all leaves
are on level 2 (6).

**Search for 17.** In the root, find the first key that is not smaller than 17
(the lower bound of chapter 02). That is 20, at index 2. It is not 17, and the node is
not a leaf, so go to child 2. Why child 2? Two keys of the root (6 and 10) are smaller
than 17, so 17 can only be in the range between 10 and 20. In the leaf `[12 15 17]` the
lower bound is index 2, and the key there is 17. Found after 2 nodes.

**Search for 8.** Root: the lower bound is 10 at index 1, not equal, go to child 1. Leaf
`[7]`: the lower bound is index 1, past the end. A leaf has no children, so 8 is absent.

**Search for 10.** Root: the lower bound is 10 itself. Found after 1 node.

**In-order traversal.** Visit child 0, key 0, child 1, key 1, ..., last child:
`[1 3 5]`, 6, `[7]`, 10, `[12 15 17]`, 20, `[25 30]`. The keys come out sorted, and that
is rule 2 at work.

**An order where rule 4 bites.** Two trees of order 5 (2 to 4 keys below the root):

```
            [10 20]                            [10 20]
 [2 5]  [12 15 17]  [25 30 35 40]      [2 5]   [15]   [25 30 35]
```

The left tree is valid: its leaves show every legal size, 2, 3 and 4 keys. In the right
tree leaf `[15]` has one key, and ceil(5/2) - 1 = 2. Every other rule holds and every
lookup works; as a tree of order 4 the same picture would be legal. `validate` returns
`NodeUnderfull` (a test in `tree.zig` / `tree.rs`; figure 2 of the visualization).

## Code walk-through

Both programs print `expected_output.txt` (`zig build run`, `cargo run`); a test in
each language compares.

### Zig (`zig/src/`)

| File | Content |
|---|---|
| `base_node.zig`, `base_search.zig`, `base_validate.zig`, `base_stats.zig`, `base_pool.zig` | Copied from chapter 05 (the complete tree), trimmed to what a read-only tree needs |
| `bump.zig` | `BumpAllocator`, a hand-written `std.mem.Allocator` |
| `tree.zig` | `HandTree(M, PoolFn)`: `leaf`, `interior`, `fromSorted`, `get`, `inOrder`, `validate`, `deinit`; `canonical` |
| `trace.zig` | `explainGet`: `get` with one printed phrase per decision |
| `height.zig` | `minKeys(m, h)`, `maxKeys(m, h)`, `minHeight(m, n)`, `maxHeight(m, n)` |
| `broken.zig` | Ten corruptions, one per error of `validate` |
| `redblack.zig` | `fromTree`, `check` |
| `scenario.zig` | What `zig build run` prints |

Every function of `height.zig` takes the order first. Chapter 01's `minHeight` and
`maxHeight` take `(n, m)` instead, and both arguments are `u64`, so a swapped call
compiles: `minHeight(5, 100)` is 3 here, `minHeight(100, 5)` is 1. A test pins the order.

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

`leaf` and `interior` check none of the six rules: the same builder makes valid trees
and broken ones, and `validate` is the only judge. `fromSorted` builds a valid tree of
minimal height from sorted keys for the tests (bulk loading is
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

One `lowerBound` call says where the key would be in this node and which child to
follow if it is not here. The loop runs once per level: a search reads at most h nodes
and makes about log2(M) comparisons in each. `inOrder` is the recursive walk "child i,
then key i".

**Validate** (`base_validate.zig`). `check(node, lo, hi, is_root, depth)` receives the
open interval (lo, hi) that the node's keys must lie in. It checks the node's size, its
order and the interval, then that all its child slots are filled (and no others), and
only then calls itself for child i with the interval narrowed to
(keys[i-1], keys[i]); the first child keeps the node's own lo and the last child its
hi, as rule 2 says. `depth` is the level minus 1. The first leaf sets the expected
depth; every later leaf is compared with it. After the walk, the number of keys met is compared with `tree.len`,
and the number of nodes reached with the number of nodes created. It returns the first
violation as an error.

Comparing a child only with its parent would not be enough: a key must respect the
separators of all its ancestors, which is why the bounds are passed down.

**Broken trees** (`broken.zig`). Each case changes one thing in the canonical tree.
Part 4 of the output shows what `validate` says and how many of the 12 original keys
`get` still finds; a key that a corruption added is not counted. In case 2 the missing
key is 7, which was overwritten, while the 11 that replaced it is stored where no
search arrives. In case 4 it is the key that was removed. Four cases find all twelve
(an overfull node, leaves on different levels, a leaf with a child pointer, an
unreachable node): query tests alone would not notice them.

A rejected tree can still be inspected and freed: `render`, `shape` and `deinit` skip a
missing child (a test runs them on all ten trees). Only `get` is unsafe on case 7,
so part 4 does not try it there.

**Oracle test** (`tree.zig`, "seeded model test"). An oracle is a second implementation
that is too simple to be wrong. Here it is one `bool` per possible key, filled from the
shared SplitMix64 generator. The tree is built from the same keys, and `get` must agree
with the oracle for every possible key, present or absent, for several orders and seeds.

### Rust (`rust/src/`)

The files have the same names and the tests the same names, with these differences.

- **No pointers.** A node is named by its index, `NodeId(u32)`, into a typed arena
  (`arena.rs`: a `Vec<Node>` that is only pushed to). Indices are `Copy`, stay valid
  when the `Vec` grows, and need no lifetimes.
- **Order at run time.** Stable Rust cannot size an array from a const generic
  expression (`[u64; M - 1]`), so `order` is a field of the tree and a node holds three
  `Vec`s. An overfull node needs no spare slot.
- **No allocator parameter, no `deinit`, no `bump.rs`.** The tree owns its arena, which
  is the bump allocator; dropping the tree frees every node.
- **Out of memory.** Rust aborts when the global allocator fails, so the arena has a
  node budget and `alloc` returns `Err(OutOfNodes)`. Zig tests real allocation failure
  with `std.testing.checkAllAllocationFailures`.
- **Missing child.** A null pointer in Zig, a too-short `children` vector in Rust.
  `validate` names the same first error in both. Printing a broken tree can differ: a
  Zig walk follows key count + 1 children, a Rust walk the `children` vector (the root
  of case 5 prints one child in Zig and four in Rust).

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
    validate: KeysOutOfOrder; get finds 11 of the 12 original keys
 2. leaf [7] holds 11 instead: sorted, but on the wrong side of separator 10
    validate: KeyOutsideParentBounds; get finds 11 of the 12 original keys
 3. leaf [12 15 17] gets a fourth key, 18
    validate: NodeOverfull; get finds 12 of the 12 original keys
 4. leaf [7] loses its only key
    validate: NodeUnderfull; get finds 11 of the 12 original keys
 5. the root's key count is set to 0
    validate: EmptyRoot; get finds 3 of the 12 original keys
 6. leaf [12 15 17] becomes interior [15] above new leaves [12] and [17]
    validate: LeavesAtDifferentDepths; get finds 12 of the 12 original keys
 7. the root's last child pointer is erased
    validate: MissingChild; get not tried (it could follow the erased pointer)
 8. leaf [7] gets a child pointer
    validate: UnexpectedChild; get finds 12 of the 12 original keys
 9. key 5 vanishes from leaf [1 3 5], the tree still claims 12 keys
    validate: WrongKeyCount; get finds 11 of the 12 original keys
10. a sixth node is allocated but nothing points to it
    validate: NodeCountMismatch; get finds 12 of the 12 original keys

== 5. Height: how few and how many keys fit ==
sparsest tree with 3 levels at M = 4 (7 keys):
  [4]
  [2] [6]
  [1] [3] | [5] [7]
fullest tree with 2 levels at M = 4 (15 keys):
  [4 8 12]
  [1 2 3] [5 6 7] [9 10 11] [13 14 15]
keys in a tree of h levels: 2*d^(h-1) - 1 up to M^h - 1, with d = ceil(M/2)
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

`fill` is the share of key slots in use: keys divided by nodes times (M - 1), rounded
down (12 of 15 in part 1). Part 7 uses `fromSorted`, which always produces the shortest
tree; trees grown by insertion (chapter 04) land between the bounds.

## In real databases

- **A 2-3-4 tree in production code.** Milvus uses the Go library `google/btree` in two
  small in-memory places with degree 2: `btree.New(2)` in
  `milvus/internal/kv/mem/mem_kv.go:51-55` and `btree.NewG(2, ...)` in
  `milvus/internal/streamingcoord/server/broadcaster/schema.go:90`. That degree 2 means
  CLRS t = 2, our M = 4, is **unverified**: the library source is not in the checkout.
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
  (`turso/core/storage/btree.rs:3429-3430`, `:10836-10848`). Rule 4 in bytes.

## Allocator notes

**The lifetime.** A tree of this chapter is built once and never changes: no node dies
before the tree does. "Free everything at once" is all the freeing there is.

**First by hand: `BumpAllocator`** (`bump.zig`). It owns a chunk of memory and a cursor.
To allocate: round the cursor up to the alignment, return that address, advance the
cursor. A full chunk is followed by a new one from the child allocator. An object too
big for an ordinary chunk gets a chunk of its own, and the current chunk stays in use.
`free` does nothing; `deinit` gives every chunk back. It implements the four functions
of `std.mem.Allocator` (`alloc`, `resize`, `remap`, `free`), so any code that takes an
`Allocator` runs on it (a test fills an `ArrayList`).

**Used as the node pool.** `DirectNodes` (`base_pool.zig`, the pool contract that
chapters 04 and 05 fill differently) calls `gpa.create` once per node, so the allocator
handed to `leaf` and `interior` decides where nodes live:

| Allocator passed in | Where nodes live | Teardown |
|---|---|---|
| `std.testing.allocator` | one tracked allocation each | `tree.deinit(gpa)` walks the tree and destroys every node it reaches |
| `BumpAllocator` | next to each other in a chunk | `bump.deinit()`: one free per chunk, no walk |
| `std.heap.ArenaAllocator` | the same | `arena.deinit()`, or `arena.reset(.retain_capacity)` to reuse the memory |

A test runs all three and gets the same tree. Parts 1 to 3 of `zig build run` use the
bump allocator; the rest uses one arena.

**Then `std.heap.ArenaAllocator`.** The same idea from the standard library, with more
care: it takes back the most recent allocation, keeps its memory across a `reset`, and
is thread-safe when its child allocator is (comment at the top of
`lib/std/heap/ArenaAllocator.zig`). Use it; the hand-written one shows there is no magic.

**Why this fits.**

- *No walk at teardown.* Freeing node by node means visiting every node just to throw
  it away.
- *A broken or half-built tree can still be freed.* `deinit` frees only what the root
  reaches. Three of the ten broken trees keep nodes out of reach (three leaves in
  case 5, one node each in cases 7 and 10), and a build that failed half-way has no
  root at all. Node-by-node allocation leaks those; an arena frees them in one call
  (one test counts what the walk frees, `checkAllAllocationFailures` fails every
  allocation of a build in turn).
- *Neighbours in memory.* Nodes created one after the other are adjacent, with no
  header between them (a test checks the addresses; a `Node(4)` is 120 bytes on the
  64-bit target used here).

**What would go wrong with a different choice.**

- A bump allocator or arena in a tree that deletes: every merged node stays allocated
  until the tree dies. Chapter 05 uses a free list for that reason.
- A general-purpose allocator here: correct, but it tracks every node and needs the
  walk. Tests use it once, because `std.testing.allocator` reports a forgotten node.
- Forgetting the lifetime: after `bump.deinit()` every node pointer dangles. Zig does
  not check this; Rust's ownership does.

**Rust.** `Arena` is a `Vec<Node>` plus a budget; dropping it frees all nodes, though
not in one deallocation: each node owns three small `Vec`s. The Zig node is one flat
block.

## Pitfalls

- **Assuming a search ends in a leaf.** In a plain B-tree it can end in any node. Code
  that scans "all leaves" misses the keys stored in interior nodes; an in-order
  traversal must emit a key between two children.
- **Trusting lookups as a test.** Four of the ten broken trees answer every `get`
  correctly. Run `validate` after every operation in tests.
- **Reading meaning into which error `validate` returns.** A tree with two defects
  gets one name: the first violation the walk meets (a node's keys, then its child
  slots, then the subtrees from left to right). Fix what is named, then validate again.

## Exercises

1. (easy) Three trees of order 5. For each: is it a valid B-tree? If not, which of the
   six rules does it break, and in which node? Which of them would be valid at order 4?

   ```
   (a)        [20]              (c)         [10 20]
       [5 10 15]  [25 30]            [2 5]  [12 21]  [25 30]

   (b)                    [30]
             [10 20]                [40]
       [2 5] [12 15] [22 25]    [32 35] [42 45]
   ```
2. (easy) A B-tree of order M = 5 holds 100 keys. What are the smallest and the largest
   possible height? Then: how many keys does a tree of order 5 need before it can have
   5 levels?
3. (medium) Take the canonical tree and apply two corruptions at once: leaf `[7]`
   becomes `[11]`, and leaf `[12 15 17]` becomes `[12 17 15]`. Which error does
   `validate` return, and why? Then a different pair: leaf `[1 3 5]` becomes `[3 1 5]`,
   and the root's last child pointer is erased. The disordered leaf is the leftmost node
   below the root. Is it reported? Explain the answer from the code of `check`.
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
