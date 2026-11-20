# Chapter 20: B-link trees

## What you will learn

- The two fields Lehman and Yao added to every B-tree node, the **high key**
  and the **right link**, and the single comparison ("move right") that lets a
  search survive a split it did not see.
- Why a search then needs only **one latch at a time**, with no lock coupling.
- How a split becomes **two separate atomic steps**, and why the state between
  them is a legal state of the tree.
- The **incomplete-split flag**: what it promises, who clears it, and why the
  next writer finishes the job before doing its own.
- How to test all of this deterministically, without threads and without
  sleeps, and what a bounded stress test adds on top.

Prerequisites: chapter 07 (B+tree, separators, handles) and chapter 19
(latches, latch coupling and why coupling is expensive). The code here is the
B+tree of chapter 07 with delete removed and concurrency added.

## The idea in plain words

Chapter 19 made a tree safe for several threads by *coupling* latches: hold the
parent while you latch the child. It works, and it makes the root a bottleneck,
because every operation holds a latch near the top for a moment.

Why was coupling needed at all? Because of this race. A reader looks at an
internal node and learns "key 30 is in leaf 3". It lets go of the internal
node. Before it reaches leaf 3, a writer splits leaf 3 and moves 30 into a new
leaf. The reader arrives at leaf 3, does not find 30, and reports "not found"
for a key that is in the tree. Coupling prevents the race by never letting go.

Lehman and Yao's answer is to let the race happen and make it harmless. Every
node, leaf or internal, gets two extra fields:

- a **high key**: an upper bound on the keys the node may hold;
- a **right link**: the handle of the next node on the same level.

and splits obey one rule:

> A split moves the upper half of a node into a **new node to its right**. The
> old node keeps its handle and its lower half. Nothing ever moves left.

Now the reader can repair its own stale knowledge. Whenever it arrives at a
node, it first compares its key with the node's high key. If the key is not
below the high key, the keys it wants were moved away by a split, and they can
only have moved right: follow the right link and look again. This is called
**moving right**. A node may have split several times, so the reader repeats
it until the key fits.

The comparison is made on every level, with two different jobs. On the leaf
level it is what makes the answer correct. On the internal levels it keeps
the path short: a search that ignored the high key of an internal node would
go down into a leaf too far to the left and still arrive, along the right
links of the leaf level.

With that, a reader never needs two latches. It latches a node, reads it,
decides where to go, releases the latch, and only then latches the next node.

### A split in two steps

A split has to change two nodes on the child level and one on the parent
level. With lock coupling a writer cannot let go of the parent until it knows
that the child will not split. The B-link structure allows the split to be cut
in two:

1. **Step 1**, under the latch of the full node only: create the right
   sibling, move the upper half into it, give it the old high key and the old
   right link, then set the old node's high key to the separator and its right
   link to the new node.
2. **Step 2**, under the latches of that node and of its parent: insert the
   **downlink** (the separator plus the handle of the new node) into the
   parent.

After step 1 the tree is already correct. The parent still sends keys of the
upper half to the old node, and the old node's high key sends them on. Step 2
only shortens the path.

The writer does **not** release the split node between the two steps. It
keeps that latch until the downlink is in the parent, so other threads
normally never look at the node in between: they wait for it. What the cut
buys is this: nothing above the node is latched during the descent and during
step 1, and if the writer stops after step 1, it leaves a legal tree.

What if step 2 never happens, because the writer crashed or ran out of space?
Searches still work. But a node without a downlink must not be split again,
because step 2 of that later split could not find where to put its downlink.
So step 1 also sets a flag on the left node, **INCOMPLETE_SPLIT**, and step 2
clears it. Any writer that meets the flag finishes the split first.

### This chapter's conventions

The high key here is **exclusive**: a node holds keys strictly below its high
key, and a search moves right when `key >= high_key`. That follows chapter 07,
where a separator is a copy of the first key of the right node. Postgres uses
an inclusive bound (see "In real databases"). The rightmost node of a level
has no high key (plus infinity) and no right link.

## A worked example by hand

The canonical keys 10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15 with M = 4 give
the tree of chapter 07, now with high keys (`<k`) and right links (`->`):

```
level 2: #7[15]
level 1: #2[6 10]<15 -> #6[20]
level 0: #0(1 3 5)<6 -> #4(6 7)<10 -> #1(10 12)<15 -> #5(15 17)<20 -> #3(20 25 30)
```

Insert 26. It belongs in leaf #3, which is full.

**Step 1**, under the latch of #3. New node #8 takes the upper half (26, 30). #8 inherits #3's old
high key (none) and old right link (none). #3 gets high key 26, right link to
#8, and the flag:

```
level 1: #2[6 10]<15 -> #6[20]
level 0: ... -> #5(15 17)<20 -> #3(20 25)<26 {incomplete} -> #8(26 30) {no downlink}
```

Suppose the writer stopped here and let go of #3 (a crash, an error, or the
test hook). Search for 30 now. Root #7: 30 >= 15, go to #6. #6: 30 >= 20, go
to #3. In #3: 30 >= high key 26, so follow the right link to #8. Found, after
one extra hop. A search that ignores the high key stops in #3 and misses 30.

**Step 2**, by the same writer if it did not stop, otherwise by the next
writer that comes to #3. Still holding #3, latch #6, insert (26, #8) after the
entry for #3, clear the flag, release both:

```
level 1: #2[6 10]<15 -> #6[20 26]
level 0: ... -> #5(15 17)<20 -> #3(20 25)<26 -> #8(26 30)
```

Now consider a reader that read #6 *before* the split and was told "#3". If
the writer did not stop, the reader waits for the latch on #3 and gets it
after step 2. The parent has changed but the reader does not know. It lands on
#3, sees 30 >= 26, and moves right. This is the normal case in a running
system: the reader's information was stale, not the tree.

## Code walk-through

Both languages have the same files. `base_*` files are copied from chapter 07
and trimmed.

| File | Content |
|------|---------|
| `base_handle`, `base_node`, `base_search` | `NodeId`, keys and children of one node, `lowerBound` / `childIndex` |
| `blink` | `BLinkTree`: the node table, `Page` (node + level + high key + right link + flag), latch helpers |
| `search` | `Descent`: one node per `step`; `lookup` with or without right links |
| `insert` | `put`, `putFrom` (test hook), `moveRight`, `halfSplit` (step 1), `insertParent` (step 2), `finishSplit` |
| `validate`, `dump` | invariants as code; text rendering |
| `stress` | bounded multi-threaded workload |
| `tests` | deterministic tests first, then the model test and the stress tests |

### Zig

**The node table** (`blink.zig`). `init` allocates `capacity` slots once. A
slot is a `std.Io.RwLock` and a `Page`. Allocating a node is a compare-and-swap
on a counter; nodes are never freed and the table never moves, so a `*Page`
stays valid while other threads allocate. `root` is an atomic `u32` that
readers load without a lock. A small mutex, `meta`, guards root changes and
`level_head`, the leftmost node of every level. Because the left half of a
split keeps its handle, the leftmost node of a level never changes once the
level exists.

In Zig 0.17.1 locks live in `std.Io` and every blocking call takes `io`, so
`get`, `lookup` and `put` take an `io` argument (`std.testing.io` in tests,
`init.io` in `main`).

**Search** (`search.zig`). `Descent.step` visits exactly one node:

```zig
const page = tree.lockShared(io, id);
defer tree.unlockShared(io, id);
if (self.mode == .follow_right_links and page.isBeyond(self.key)) {
    self.next = page.right;                 // move right
    return .{ .moved_right = ... };
}
// otherwise: pick a child (internal) or search the keys (leaf)
```

`get` is a loop over `step`. Writing the descent as a state machine has a
purpose: between two steps the reader holds no latch, and a test can run a
whole insert in that gap.

**Insert** (`insert.zig`). `put` descends like a reader, remembering the node
it came through on each level (a hint for finding parents, like Postgres'
stack). Leaves are latched exclusively. `moveRight` is the writer's version of
move right: if it sees the flag it calls `finishSplit` before going on.

If the leaf is full, `put` allocates the new node *before* changing anything,
so a full table leaves the tree untouched and `put` returns
`error.OutOfNodes`. Then `halfSplit` does step 1 and `insertParent` does
step 2, with the leaf latched throughout. `insertParent`

1. takes the downlink from the left node itself: `(left.high_key, left.right)`;
2. if the left node is the root, builds a new root under the `meta` mutex;
3. otherwise finds the parent by searching for the child's **handle**, starting
   at the remembered node and moving right. A writer that came down while the
   left node was still the root remembers no parent and starts at
   `level_head[level + 1]`, the leftmost node of the parent level;
4. finishes a pending split of that parent first, if it is flagged;
5. inserts the downlink and clears the flag while holding both latches;
6. if the parent overflowed, runs the same two steps one level up.

If a node is needed for the parent and the table is full, `insertParent` gives
up and leaves the flag set. The `put` still succeeded: the key is in the tree.
From then on every writer whose path leads through the flagged node must
finish that split first and fails with `OutOfNodes`, even if its own work
needs no node (an overwrite, or an insert into a leaf with room). If the
flagged node is the root, that is every `put`. Nodes are never freed here, so
these puts fail for good. Searches are not affected.

**The test hooks.** `setAbandonSplits(true)` makes every split stop after
step 1. This is how tests and the demo reach the half-finished state without
threads. The second hook makes a writer's knowledge stale:
`putFrom(start, key, value, pause)` is `put` that begins its descent at
`start` (a former root) and calls `pause.at_leaf` once it has latched its
leaf. The callback runs other puts, as other threads would in that gap, so
the parents the paused writer remembers can split, be left half split or get
a new root above them before it climbs back up. A second callback,
`pause.root_built`, runs when a root split has filled its new root and has not
yet stored the root pointer.

### Rust

The structure is the same; three things differ in kind.

- **The latch owns the data.** The table is `Box<[RwLock<Page>]>`. A `Page`
  can only be reached through a guard, so "latch before access" is checked by
  the compiler. Zig keeps the latch beside the page and relies on discipline:
  `validate` and `dump` read pages without latching (documented as
  single-threaded only), and `allocPage` initialises a new page without its
  latch because no other thread knows the handle yet. Safe Rust cannot express
  that argument, so `alloc_page` takes the uncontended latch (for a new root
  while holding `meta`, which is otherwise the last lock taken).
- **Releasing is `drop`.** `insert_parent` takes the left node's write guard
  *by value*. Every `return` releases it. The Zig function has an explicit
  `unlockExclusive` on each of its exits; forgetting one would be a deadlock
  that only a test finds.
- **`&self` everywhere.** `put` takes `&self`: shared access to the tree, with
  exclusivity inside the latches. Counters and the root are atomics, and the
  fields guarded by `meta` live inside a `Mutex<Meta>`.

The pause callbacks are function pointers plus a context pointer in Zig and
`&mut dyn FnMut` closures in Rust. Threads are `std::thread::scope` in Rust
(the closure may borrow the tree) and `std.Thread.spawn` / `join` in Zig.

### Testing

The tests are ordered from deterministic to concurrent.

- **Paused split.** With the hook on, `put 26` leaves the state of the worked
  example. `validate` passes, every key is found, and the lookups of 26 and 30
  each report one move right.
- **Move-right disabled.** `lookup(key, .ignore_right_links)` in the same state
  misses exactly 30 and 26.
- **Finishing.** A `put` elsewhere in the tree leaves the flag alone. A `put`
  that is routed to the flagged node inserts the downlink first.
- **Stale downlink.** A `Descent` is stepped twice, a complete split happens,
  and the next step reports `moved_right`. After every reader step the test
  takes every latch exclusively to prove the reader holds none.
- **Root and internal levels.** A root split paused after step 1 has height 1
  and two nodes; ascending inserts with the hook always on leave internal
  nodes half split.
- **Stale writers** (`putFrom`). Three hand-written cases: the remembered
  parent split, it was left half split with a new root above it, and the
  writer started at an old root. A seeded run pauses 3000 writers while other
  puts run with the abandon hook on a coin.
- **Root publication.** The `root_built` callback records what it sees: the
  root pointer is still the old root, and the new root is complete.
- **Internal levels.** A reader sent to #6 finds it split and moves right on
  level 1; a writer started at the old root #2 makes two hops there.
- **Full table.** For every table size from 1 to 40, inserts run until
  `OutOfNodes`; the failed key is absent, `validate` passes, and at least one
  size ends with a legal incomplete split. With six nodes a leaf stays
  flagged and the puts routed to it fail, overwrites included; with two nodes
  it is the root and every put fails. Every get still works.
- **Model test.** Seeded puts and gets against the oracle of `common/`, with a
  seeded coin switching the hook.
- **Stress.** Four threads; after every put a thread reads back that key, one
  of its earlier keys and a preloaded key. Then `validate` and a comparison
  with the oracle. No timing is asserted and nothing printed depends on the
  interleaving.

### Output

Both programs print exactly [expected_output.txt](expected_output.txt), and a
test in each language checks it. Sections 1 to 6, with the second half of
section 5 left out:

```
== 1. Build: canonical keys, order M = 4; every node has a high key and a right link ==
height 3, 12 keys, 8 nodes
  level 2: #7[15]
  level 1: #2[6 10]<15 -> #6[20]
  level 0: #0(1 3 5)<6 -> #4(6 7)<10 -> #1(10 12)<15 -> #5(15 17)<20 -> #3(20 25 30)
legend: #n node, [..] separators, (..) leaf keys, <k high key (keys in the node are below k), -> right link

== 2. Step 1 of a split, and nothing else ==
put 26 into the full leaf #3(20 25 30); the writer stops between the two steps
height 3, 13 keys, 9 nodes
  level 2: #7[15]
  level 1: #2[6 10]<15 -> #6[20]
  level 0: #0(1 3 5)<6 -> #4(6 7)<10 -> #1(10 12)<15 -> #5(15 17)<20 -> #3(20 25)<26 {incomplete} -> #8(26 30) {no downlink}
incomplete splits: 1; validate: ok

== 3. Searching in that state ==
get 25 = 2500 (visited 3 nodes, moved right 0)
get 26 = 2600 (visited 4 nodes, moved right 1)
get 30 = 3000 (visited 4 nodes, moved right 1)
without right links: get 25 = 2500
without right links: get 26 = null  <- MISSED
without right links: get 30 = null  <- MISSED
keys found: 13 of 13 with right links, 11 of 13 without

== 4. The next writer finishes the split ==
put 27: lands on #3, sees the flag, inserts the downlink to #8 first, then does its own work
height 3, 14 keys, 9 nodes
  level 2: #7[15]
  level 1: #2[6 10]<15 -> #6[20 26]
  level 0: #0(1 3 5)<6 -> #4(6 7)<10 -> #1(10 12)<15 -> #5(15 17)<20 -> #3(20 25)<26 -> #8(26 27 30)
splits finished by a later writer: 1; incomplete splits: 0
keys found: 14 of 14 with right links, 14 of 14 without

== 5. A reader overtaken by a complete split (stale downlink) ==
with right links: get 30
  reader: visits #7[15], follows the downlink to #6
  reader: visits #6[20 26], follows the downlink to #8
  writer: put 28 splits that leaf, both steps (half splits +1, incomplete 0)
  reader: visits #8(26 27), 30 >= high key 28, follows the right link to #9
  reader: visits #9(28 30), finds 30 = 3000
  ...

== 6. A root split is the same two steps ==
put 4, stopped after step 1: the root has a right sibling and there is no new root yet
height 1, 4 keys, 2 nodes
  level 0: #0(1 2)<3 {incomplete} -> #1(3 4) {no downlink}
get 4 = 400 (moved right 1)
put 5 finishes it: step 2 of a root split builds the new root
height 2, 5 keys, 3 nodes
  level 1: #2[3]
  level 0: #0(1 2)<3 -> #1(3 4 5)
```

The rest of section 5 is the same race without right links: the reader misses
a key. Section 7 prints one line of counters per order for a seeded model run
of 20000 operations (the search without right links is wrong 103, 49 and 6
times for M = 3, 4, 16), and section 8 one line per stress run.

## In real databases

Of the codebases studied in this guide, Postgres is the one with a B-link
tree. Everything below was read in the Postgres source
(`postgres/src/backend/access/nbtree/`, shortened to `nbtree/`).

- **The two fields.** The README describes the right link and the high key
  and how a search uses them (`nbtree/README:17-29`). Postgres also keeps a
  left link for backward scans (`nbtree/README:70-86`); this chapter has none.
- **Inclusive high key.** In Postgres the high key is "greater than or equal
  to any other key that appears on the page" (`postgres/src/include/access/nbtree.h:349-366`),
  and a search moves right when its key is strictly greater
  (`nbtree/nbtsearch.c:309-313`). This chapter's bound is exclusive.
- **Readers do latch.** Lehman and Yao's readers take no locks, but assume
  private copies of pages. Postgres shares buffers, so it read-locks one page
  at a time (`nbtree/README:63-68`), as this chapter does.
- **No coupling on the way down.** `_bt_search` drops the lock on the parent
  and then locks the child (`nbtree/nbtsearch.c:184-185`). It write-locks the
  child when the parent is on level 1 (`nbtree/nbtsearch.c:176-182`) and
  trades a read lock for a write lock when the root is a leaf
  (`nbtree/nbtsearch.c:190-199`). `put` copies all three.
- **Step 1.** `_bt_split` (`nbtree/nbtinsert.c:1486-2109`) sets
  `BTP_INCOMPLETE_SPLIT` on the left page (`:1580`) and links the pages
  (`:1760`, `:1770`). The left half keeps the original block:
  "the left page never move during a split" (`:1952-1959`). The new page is
  acquired late so that a failure before it leaves no trace (`:1527-1532`).
- **Step 2.** `_bt_insert_parent` (`nbtree/nbtinsert.c:2127-2254`) forms the
  downlink from the left page's high key (`:2206-2212`), re-finds the parent
  with `_bt_getstackbuf`, which matches on the child's block number and moves
  right (`:2348-2453`), and inserts next to the left child's entry
  (`:2246-2249`). Lehman and Yao match on the separator key and must hold
  three locks at that point (`nbtree/README:139-156`). The flag is cleared in
  the same critical section (`:1316-1328`).
- **Locks across the two steps.** As in this chapter, the left page stays
  write-locked from the split until its downlink is in the parent
  (`nbtree/nbtinsert.c:1236-1252`, `:2114-2120`, `nbtree/README:666-672`).
  Child before parent is a safe order: locking the next page before releasing
  the current one "is safe when moving right or up, but not when moving left
  or down" (`nbtree/README:106-110`). Unlike this chapter, Postgres also keeps
  the new right page locked until it has locked the parent (`:2225-2238`).
  Here nothing latches the new node across the steps: the only pointer to it
  is in the latched left node.
- **Incomplete splits.** A crash or an error between the two actions leaves a
  page without a downlink; searches still work (`nbtree/README:642-650`).
  Missing downlinks are created by later insertions, not by searches, to keep
  reads read-only (`nbtree/README:652-655`). The places that finish a split
  are `_bt_moveright` when called for an update (`nbtree/nbtsearch.c:285-307`),
  `_bt_finish_split` (`nbtree/nbtinsert.c:2269-2315`) and `_bt_getstackbuf`
  (`:2368-2372`).
- **Root split.** Lehman and Yao do not describe it; Postgres splits the root
  like any page and then builds a new root (`nbtree/README:112-123`,
  `_bt_newlevel`, `nbtree/nbtinsert.c:2489-2655`).

Left out here: each step is one WAL record, which is where "atomic" comes
from on disk (chapter 22); page deletion (chapter 24); and the lock coupling
of an inserter that steps right on the leaf level, needed for unique checks
(`nbtree/nbtinsert.c:1026-1031`).

## Allocator notes

**Zig.** The tree makes one allocation: `gpa.alloc(Slot, capacity)` in `init`,
freed in `deinit`. The allocator is passed to both and stored nowhere.

- *Why preallocate.* Chapter 07's arena is a growable list. Growing moves
  every node, and here another thread may be reading one at that moment. A
  fixed table never moves. Its capacity is the tree's size limit, and
  `error.OutOfNodes` replaces `error.OutOfMemory` as the failure `put` can
  report.
- *Why never free.* There is no delete, so no node becomes garbage. In a
  B-link tree freeing would also be unsafe by itself: a reader may be holding
  the handle of a node with no latch on it. Chapter 24 deals with that.
- *What is tested.* `std.testing.allocator` fails the test if the table leaks.
  `checkAllAllocationFailures` runs `init`, some puts and `deinit` under every
  possible allocation failure. A `FailingAllocator` that allows one allocation
  proves that `put` never allocates.

The stress test gives **each worker thread its own `ArenaAllocator`** for its
key log and its list of missed reads. The arena is created before the thread
starts, used only by that thread, and freed by the main thread after the join
and after the logs were merged into the oracle. One arena per thread means the
hot loop of one thread never touches allocator state that another thread is
using, and a thread's memory goes away in one call. A shared arena would
compile and would add contention plus a rule about who may reset it.

**Rust.** The table is `Box<[RwLock<Page>]>`: a boxed slice has no `push`, so
"never grows" is visible in the type. The capacity plays the role of chapter
07's node budget and `Err(OutOfNodes)` mirrors Zig's error. Each scoped thread
owns two `Vec`s and returns them through `join`; dropping them is the arena.

## Pitfalls

- **Checking the high key after searching the node.** The high key decides
  whether this node is the right one at all. Compare first.
- **Thinking the high key is the largest key.** It is a bound. Here no key in
  the node equals it; in Postgres one may.
- **Treating an upgrade as atomic.** There is no upgrade from shared to
  exclusive, only release and re-acquire. Anything may have changed in
  between; re-check the flag and the high key.
- **Clearing the flag and inserting the downlink at different moments.** They
  must change together. Exercise 3 shows what `validate` says otherwise.
- **Walking past a flagged node as a writer.** The node to its right has no
  downlink. If it splits, step 2 cannot find a parent entry. Exercise 4.
- **Trusting the stack.** The remembered node is a hint: search from it and
  move right. (Lehman and Yao search for the separator key, which is also
  correct in this tree; Postgres and this chapter search for the child's
  handle, `nbtree/README:139-156`.)
- **Moving keys left, or reusing a node's handle for other keys.** Every
  argument in this chapter rests on "keys only move right into a new node".
- **Validating from the root only.** A node without a downlink is invisible
  from above. Walk each level as a list.
- **Tests that sleep.** A paused split, a one-node-at-a-time reader and a
  writer paused on its leaf reach the same states every time.

## Exercises

1. *(easy)* In the state of section 2, which keys does a search without right
   links miss, and why does it still find 25? Check with the program.
2. *(easy)* Change `isBeyond` to Postgres' comparison, `key > high_key`,
   without changing anything else. Predict which tests fail before you run
   them. What else would have to change to make the inclusive bound correct?
3. *(medium)* In `insertParent`, clear the flag *before* the parent's node is
   allocated. Which test fails, and which invariant does `validate` name?
4. *(medium)* Make `moveRight` ignore the flag. What is the first thing that
   goes wrong, and where?
5. *(harder)* Write `scan(lo, hi)` that returns all keys in `[lo, hi)` in
   order, holding one shared latch at a time, and stays correct when a leaf
   splits just before the scan reaches it. Which two values must be read under
   the same latch as the keys?

Solutions: [solutions.md](solutions.md).

## Links

- Previous: [chapter 19, latching and lock coupling](../19-latching-and-lock-coupling/README.md)
- Next: [chapter 21, durability primitives](../21-durability-primitives/README.md)
- Visualization: [viz/index.html](viz/index.html)
