# Chapter 19: Latching and lock coupling

## What you will learn

- The difference between a **latch** and a **lock**, and which one a B-tree
  node needs.
- A ladder of three ways to share one tree between threads: one mutex, one
  reader-writer lock, and one latch per node with **latch coupling**
  (also called lock coupling or crabbing), and the **convoy** it can cause.
- The **safe node** rule that tells a writer which latches it may release.
- Why latch order matters, and why this design cannot deadlock.
- How to test concurrent code deterministically: freeze one operation at a
  chosen point, run another, and look at what happened.
- What optimistic descent with version counters changes (prose and
  visualization only).

Prerequisites: chapter 07 (the B+tree this chapter starts from) and chapter 06
(oracle tests). Chapter 20 builds the B-link tree, which is what PostgreSQL
actually uses, on the ideas of this chapter.

## The idea in plain words

Everything up to here assumed that one thread uses the tree at a time. Two
threads break that in a simple way. A split moves half of a leaf's keys into a
new leaf and then tells the parent. A reader that looks at the leaf between
those two moments, or that read the parent just before, can miss a key that is
in the tree. Nothing has to crash: the reader just gets a wrong answer.

### Latches and locks

Two different things are called "lock" in database writing. This chapter uses
the textbook names (the distinction is from the database literature, for
example Graefe's survey of B-tree locking; it is not taken from one code base).

| | Latch | Lock |
|---|---|---|
| Protects | an in-memory structure (a node, a page) | a logical thing (a row, a key range) |
| Held for | one step of one operation | until the transaction ends |
| Deadlock | avoided by always acquiring in a fixed order | detected or timed out by a lock manager |
| Belongs to | a thread | a transaction |

This chapter is only about latches. A latch says "nobody changes these bytes
while I look at them". It says nothing about transactions. The Zig type is
`std.Io.RwLock` and the Rust type is `std::sync::RwLock`; in this chapter they
are used as latches.

A reader-writer latch has two modes. **Shared** (S): any number of holders,
all of which only read. **Exclusive** (X): one holder, who may write.

### The ladder

**Rung 1: one mutex for the whole tree.** Every `get` and `put` takes it. No
two operations ever overlap, so the single-threaded tree code stays correct
as it is. One thread works at a time, even if all of them only read.

**Rung 2: one reader-writer lock for the whole tree.** `get` takes it shared,
`put` exclusive. Readers no longer wait for each other. One writer still stops
everybody, although it changes one leaf out of thousands.

**Rung 3: one latch per node.** An operation latches only the nodes it is
working on. The question becomes: in which order, and when may a latch be
released? The answer is latch coupling:

> To move from a node to its child: latch the child first, then release the
> parent.

For a moment the thread holds both, like a crab that puts one claw down before
it lifts the other. That moment closes the gap described above. While the
parent is latched nobody can split the child, because the split would have to
write the parent. So when the reader arrives at the child, the child still
covers the key range the parent promised.

A reader holds shared latches and never more than two. A writer holds exclusive
latches, and it has a harder problem: a split at the bottom may travel up.
Releasing every parent would let another thread change a node that the split
is about to write. Keeping every latch from the root down would be the global
lock again. The **safe node rule** decides:

> A node is safe for an insert if it has room for one more key. When the
> writer latches a safe child, it releases all the latches above it.

A safe child absorbs whatever comes up from below without splitting, so
nothing above it can change. A full child may split, so its parent stays
latched. When the writer reaches the leaf it holds exactly the nodes that will
change, and no others.

**Latch order.** Every thread takes latches top-down along one path and never
waits for a latch above or beside one it holds. A deadlock needs a cycle of
threads each waiting for the next; with one global order there is no cycle.
That is the whole deadlock argument, and it is why this chapter's leaves are
chained in one direction only (see Pitfalls).

**The root** has no parent whose latch could protect the step "read the root
id, then latch that node". The code latches the node and then reads the root id
again. If it changed, the thread lets go and starts over.

**Waiting while holding.** Coupling means that a thread waits for the child's
latch with the parent's latch still in its hand. A reader that waits for a
child of the root keeps its shared latch on the root, and every writer starts
with an exclusive latch on the root. So every writer waits, also those bound
for a part of the tree nobody is working on. Threads queue behind a thread
that is itself only waiting: a **convoy**. It is not a deadlock (the queue
drains when the first thread finishes), but one slow operation can close the
whole tree for a while.

### One rung further: optimistic descent (not implemented here)

Even a shared latch is a write to shared memory: the latch counts its holders.
Every reader of the tree writes to the root's latch, and the cache line that
holds it bounces between cores. Optimistic schemes (textbook; none of the six
code bases in this guide uses one) give every node a version counter that a
writer bumps when it releases the node. A reader takes no latch. It notes a
node's version, reads, and checks that the version is unchanged before it
trusts what it read; if not, it starts again. Writers can descend the same way
and latch only the leaf, falling back to latch coupling when the leaf is full.
The visualization has this as a fourth protocol. The cost is that readers can
be forced to retry, and that a node must never be freed while a reader might
still look at it.

## A worked example by hand

The canonical keys with M = 4 give this tree (`#n` is a node handle):

```
                     #7[15]
        #2[6 10]                  #6[20]
#0(1 3 5)  #4(6 7)  #1(10 12)     #5(15 17)  #3(20 25 30)
```

**`get 12` with latch coupling.** S on #7. S on #2, then release #7. S on #1,
then release #2. Read the leaf. Release #1.

**`put 11`.** X on #7. X on #2: it has 2 of 3 keys, so it is safe; release #7.
X on #1: 2 of 3 keys, safe; release #2. The writer holds only #1 and inserts.

**`put 26`.** X on #7. X on #6: 1 key, safe; release #7. X on #3: 3 keys, full,
so #6 stays latched. The writer holds #6 and #3. The leaf splits into
#3(20 25) and a new #8(26 30); separator 26 goes into #6, which had room.
Meanwhile a second thread's `get 12` or `put 11` runs freely through #7 and
#2, and a `get 17` gets through #7 and then waits at #6.

With four threads the same `put 26` produces a convoy: section 7 of the
output.

**Without coupling.** Suppose `get 30` released #6 *before* it latched #3. It
has read "30 is under #3" and holds nothing. Now `put 26` runs from start to
end and moves 30 into the new leaf #8. The reader latches #3, searches
(20 25) and answers "not found" for a key that never left the tree. With
coupling the reader still holds #6, which the split needs: one of the two
waits. (Solution 3 ran this; the visualization's sandbox has it as the
protocol "no coupling (broken)".)

**`put 2` after `put 8` and `put 9`** (which fill #2 to `[6 8 10]`). X on #7.
X on #2: full, keep #7. X on #0: full, keep both. The writer holds #7, #2 and
#0: the whole path. Until it finishes, the tree is as closed as under a global
lock. This is the weakness of the pessimistic rule: it must assume the worst
before it has seen the leaf.

The program checks all of these (section 3 of its output, below).

## Code walk-through

Both versions have the same files. `base_node` and `base_search` are copied
from chapter 07 and trimmed.

| File | Contents |
|---|---|
| `table` | the preallocated node table: every node with its latch |
| `tree` | the `Tree`, the three protocols, the test hook |
| `plain` | `get` and `put` with no latch protocol (used under a global lock) |
| `coupled` | `get` and `put` with latch coupling and the safe node rule |
| `insert` | leaf insert and splits, shared by `plain` and `coupled` |
| `validate`, `dump` | invariants and text rendering, for a quiescent tree |
| `probe` | freeze one operation, run others behind it |
| `stress` | bounded multi-threaded workload and its check |

Run with `zig build test --summary all`, `zig build run`, `cargo test`,
`cargo run`.

### The node table

Chapter 07 kept nodes in a growable array with a free list. Both parts are
unsafe with several threads. A growing array moves while another thread reads
a node. A freed slot can be reused while a slow thread still holds its handle.
So the table has a **fixed capacity**, is allocated once, and **never frees a
node** (there is no delete in this chapter). Handles are still `u32` indices.

A new node is taken by bumping one atomic counter. `reserve(n)` hands out `n`
slots or none. An insert asks for every node its splits will need *before* it
changes anything, so `OutOfNodes` leaves the tree untouched. The number is
known exactly: it is the run of full nodes at the bottom of the path, plus one
if that run reaches the root.

### Zig

`tree.zig` holds the protocol switch. The two global protocols are a lock
around the plain algorithm:

```zig
pub fn getHooked(self: *Tree, io: Io, key: u64, hook: ?*const Hook) ?u64 {
    if (self.protocol == .latch_coupling) return coupled.get(self, io, key, hook);
    self.lockGlobal(io, .shared, hook);
    defer self.unlockGlobal(io, .shared);
    emit(hook, .at_leaf, .nil);
    return plain.get(self, key);
}
```

In Zig 0.17.1 `std.Thread` only spawns and joins. Mutexes and reader-writer
locks live in `std.Io` and every blocking call takes an `io`, which is why
`io` is a parameter of `get` and `put`.

`coupled.zig` is the chapter. The reader:

```zig
.internal => |*in| {
    const child = in.children[search.childIndex(n.keySlice(), key)];
    latch(tree, io, child, .shared, hook); // claw down on the child ...
    unlatch(tree, io, id, .shared); //        ... then lift it off the parent
    id = child;
},
```

The writer keeps its exclusive latches in a small array `held`, top-down:

```zig
latch(tree, io, child, .exclusive, hook);
if (tree.table.node(child).len < tree.maxKeys()) {      // safe node rule
    for (held[0..n]) |ancestor| unlatch(tree, io, ancestor, .exclusive);
    n = 0;
    top_is_root = false;
}
held[n] = child;
n += 1;
```

After the descent `held[0..n]` is passed to `insert.insertAtLeaf`, the same
function `plain.put` calls with the whole path. `latchRoot` reads the atomic
root id, latches that node and reads the id again.

### Rust

The table is `Box<[RwLock<Node>]>`: the node lives *inside* its latch. That
changes two things, and leaves one as it was.

- A latch is released by dropping its guard. Coupling is an assignment:
  `node = child_guard;` drops the parent's guard after the child's exists. The
  writer's `held` is a `Vec` of `(NodeId, RwLockWriteGuard)`; `held.clear()`
  releases the ancestors top-down.
- There is no way to reach a node without a guard, so `plain.rs` takes each
  node's latch as it goes although the global lock already keeps everybody
  out. The latches never wait there; they only satisfy the type system. Zig's
  `plain.zig` takes none.
- Releasing in the wrong *order*, or too early, is still possible: the
  compiler does not know about coupling.

Threads are `std::thread::scope`, which lets the workers borrow the tree and
joins them before the scope ends.

### The test hook

`getHooked` / `putHooked` (Rust: `get_hooked` / `put_hooked`) take an optional
callback that the operation calls on its own thread at five points:
`root_loaded`, `latched`, `at_leaf`, `root_built` (a new root is filled in but
not yet published) and `blocked` (a try-lock failed; about to wait). A test
blocks inside the callback, which freezes the operation with all its latches.
`probe.probe(tree, A, pause, B)` does this with two threads: it freezes A,
starts B, and waits until B either finishes or reports `blocked`. No sleep is
involved. If B has to wait, it waits for something the frozen A holds, so it
cannot finish early and the answer is final. `probe.convoy` starts several
operations behind the frozen one, one after the other.

The same hook on a single thread shows *which* latches an operation holds: the
callback tries to latch every node and notes the ones that fail.

### Tests

1. Single-threaded: every protocol against the oracle; the three protocols
   produce byte-identical trees; every table size from 1 to 7 nodes, checking
   that a failing `put` changes nothing and leaves no latch held. The oracle
   run stops with a message if an operation ever has to wait: on one thread
   only a leaked latch can cause that.
2. Hook on one thread: a `get` holds at most two latches; the safe node rule
   keeps exactly the nodes listed in the worked example.
3. Hook with two or more threads: the table of section 3 below; operations
   frozen in mid-descent; two convoys. For the root: a reader and a writer
   that latched a replaced root; a thread already waiting for the old root's
   latch; a new root that is complete before it is published; and the latch
   order, a restart that holds nothing when it asks for the new root.
4. `reserve` has its own seam, a callback between "read the counter" and
   "claim the slots". The test's callback takes a slot there, as another
   thread could: the race is replayed on one thread.
5. Stress: 4 threads, seeded, with disjoint and with overlapping key sets, a
   hot spot of 24 keys, and a table that runs out. It is bounded by an
   operation count, not by a clock. Afterwards `validate()` runs and the leaf
   chain is compared with an oracle.

A stress test proves little by passing. As a check, 28 bugs were put into a
scratch copy, one at a time, and the test binary was run ten times per bug in
each language. (Five cannot be written in safe Rust. One, releasing latches
bottom-up instead of top-down, changes nothing a test could see.)

Every other bug fails a deterministic test in every run. Three examples: the
parent released before the child is latched, the root id checked before the
latch is taken instead of after, a new root published half filled. The
stress tests alone noticed these in roughly one run in three, three runs in
four, and never (approximate rates, from about 20 runs per bug and
language). A bug that would end in a hang is reported by a hook that sees
the stuck thread. A deterministic test exists only for an interleaving
somebody thought of.

### Output

Both programs print exactly this (`expected_output.txt`). Sections 3, 4, 6
and 7 use threads. Section 6 prints only values that do not depend on the
interleaving.

```
== 1. One tree, three protocols: canonical keys, order M = 4 ==
global mutex:
  height 3, 12 keys, 8 nodes
  level 0: #7[15]
  level 1: #2[6 10] #6[20]
  leaves : #0(1 3 5) -> #4(6 7) -> #1(10 12) -> #5(15 17) -> #3(20 25 30)
global rwlock: same tree: yes
latch coupling: same tree: yes

== 2. Model run: 20000 single-threaded operations (put, get) against the oracle ==
global mutex   keys=500 height=6 nodes=323 leaf splits=212 internal splits=105 mismatches=0
global rwlock  keys=500 height=6 nodes=323 leaf splits=212 internal splits=105 mismatches=0
latch coupling keys=500 height=6 nodes=323 leaf splits=212 internal splits=105 mismatches=0

== 3. A is frozen at the end of its descent, holding its locks. Does B finish? (canonical tree) ==
A = get 12 (latch coupling holds: #1 shared)
  B                      global mutex    global rwlock   latch coupling
  get 25 (other leaf)    waits           finishes        finishes
  get 10 (same leaf)     waits           finishes        finishes
  put 16 (other leaf)    waits           waits           finishes
  put 11 (same leaf)     waits           waits           waits at #1
A = put 11 (latch coupling holds: #1 exclusive; leaf #1 has room)
  B                      global mutex    global rwlock   latch coupling
  get 25 (other leaf)    waits           waits           finishes
  get 12 (same leaf)     waits           waits           waits at #1
  put 16 (other leaf)    waits           waits           finishes
A = put 26 (latch coupling holds: #6, #3 exclusive; leaf #3 is full, its parent #6 has room)
  B                      global mutex    global rwlock   latch coupling
  get 12 (under #2)      waits           waits           finishes
  put 11 (under #2)      waits           waits           finishes
  get 17 (under #6)      waits           waits           waits at #6
after put 8, put 9: A = put 2 (latch coupling holds: #7, #2, #0 exclusive; leaf #0 and its parent #2 are full)
  B                      global mutex    global rwlock   latch coupling
  get 25 (under #6)      waits           waits           waits at #7

== 4. Latch coupling: the root is replaced under a reader ==
before: height 1, 3 keys, 1 nodes
  leaves : #0(5 10 20)
reader of 20 has read root = #0 and holds no latch yet; now put 6 splits the root
after:  height 2, 4 keys, 3 nodes
  level 0: #2[10]
  leaves : #0(5 6) -> #1(10 20)
reader latched #0, saw root = #2, restarted 1 time(s): get 20 = 2000

== 5. A node table of 7: put 15 needs 3 new nodes (leaf, internal, root) ==
global mutex   put 15: OutOfNodes; nodes used 5 -> 5 of 7; tree unchanged: yes; locks still held: none
global rwlock  put 15: OutOfNodes; nodes used 5 -> 5 of 7; tree unchanged: yes; locks still held: none
latch coupling put 15: OutOfNodes; nodes used 5 -> 5 of 7; tree unchanged: yes; locks still held: none

== 6. Stress: 4 threads x 5000 operations, then validate and compare with the oracle ==
disjoint keys    global mutex   keys=2972 expected=2972 first-time puts=2972 lost=0 failed=0 mismatches=0 valid=yes
disjoint keys    global rwlock  keys=2972 expected=2972 first-time puts=2972 lost=0 failed=0 mismatches=0 valid=yes
disjoint keys    latch coupling keys=2972 expected=2972 first-time puts=2972 lost=0 failed=0 mismatches=0 valid=yes
overlapping keys global mutex   keys=2983 expected=2983 first-time puts=2983 lost=0 failed=0 mismatches=0 valid=yes
overlapping keys global rwlock  keys=2983 expected=2983 first-time puts=2983 lost=0 failed=0 mismatches=0 valid=yes
overlapping keys latch coupling keys=2983 expected=2983 first-time puts=2983 lost=0 failed=0 mismatches=0 valid=yes

== 7. Latch coupling, four threads: A = put 26 is frozen as in section 3; then B, C, D start, one after the other ==
  B = get 17 (under #6)  waits at #6
  C = get 12 (under #2)  finishes
  D = put 11 (under #2)  waits at #7
D needs nothing that A holds. It waits for the shared latch B keeps on the root #7 while B itself waits at #6.
after A is released: get 26 = 2600, get 11 = 1100, valid=yes, latches still held: none
```

Section 3 is the chapter in one table. Read it by columns: each rung of the
ladder turns some "waits" into "finishes". Read the last row: when the full
nodes reach up to the root's child, latch coupling waits at the root like the
global locks.

In section 6, "first-time puts" counts the `put` calls that returned "no
previous value". It equals the number of distinct keys exactly when no
insert was lost and none happened twice.

No timings are printed; which protocol is faster was not measured.

## In real databases

Latch coupling as implemented here is **textbook material**. None of the six
code bases this guide studies descends a tree this way.

- **DuckDB** takes one mutex for the whole index, also for read-only scans.
  `IndexLock` is a scoped `lock_guard<mutex>`
  (`duckdb/src/include/duckdb/execution/index/index_lock.hpp:17-22`), and the
  ART's scans take it (`duckdb/src/execution/index/art/art.cpp:886`, `:915`,
  `:936`). That is rung 1.
- **Milvus** wraps its in-memory `google/btree` in one `sync.RWMutex`
  (`milvus/internal/kv/mem/mem_kv.go:39-42`); readers call `RLock` (`:96`),
  writers `Lock` (`:157`). That is rung 2.
- **Turso** allows one writer at a time for the whole database. A write
  transaction must win the WAL write lock or gets `Busy`
  (`turso/core/storage/wal.rs:3571-3590`). Its B-tree pages carry flags and
  pin counts but no per-page reader-writer latch (research notes,
  `research/turso.md` section 12).
- **PostgreSQL** does have a latch per page (a buffer content lock, shared or
  exclusive), but it does **not** couple them on the way down. `_bt_search`
  releases the parent and only then locks the child:
  `/* drop the read lock on the page, then acquire one on its child */`
  (`postgres/src/backend/access/nbtree/nbtsearch.c:184-185`, through
  `_bt_relandgetbuf`, `nbtpage.c:988`). Its README says a scan holds nothing
  "between levels" (`postgres/src/backend/access/nbtree/README:428-431`). The
  gap this chapter closes with coupling, PostgreSQL closes differently: every
  page has a right link and a high key, and a reader that lands on a page
  that was split under it moves right (Lehman and Yao; chapter 20). The
  README does keep "conservatively coupling parent and child locks when
  ascending the tree" for a split's insert into the parent (`README:153-156`).
  So in PostgreSQL coupling exists on the way *up*, not on the way down.

Rungs 1 and 2 are not beginner mistakes. DuckDB and Milvus ship them, because
their index workloads do not need more.

## Allocator notes

- **The node table is one allocation**, made in `Tree.init` from the allocator
  the caller passes, and freed in `deinit`. Operations never allocate a node,
  and in Zig they allocate nothing at all (the path is a fixed array on the
  stack). This is a correctness property here, not a tuning choice: a table
  that grows would move nodes under other threads, and a general-purpose
  `free` would let a slot be reused under a thread that still holds its
  handle.
- **`std.heap.smp_allocator`** backs the tables in `main`. It is a global,
  thread-safe allocator made for multi-threaded programs, and needs no
  `deinit`.
- **A thread-safe arena** holds the stress workers' logs. In Zig 0.17.1
  `std.heap.ArenaAllocator` is thread-safe when its child allocator is
  (`lib/std/heap/ArenaAllocator.zig`, top comment). Four workers grow their
  key lists from one arena at the same time, and one `arena.deinit()` after the
  check frees everything.
- **Tests use `std.testing.allocator`**, also under the stress arena, so a
  leak fails the test. `Tree.init` is tested with a failing allocator.
- **Rust**: the table is a `Box<[RwLock<Node>]>` built once; its length is
  the node budget. Instead of an arena each worker owns its `Vec` and hands
  it back through `join`. Unlike Zig, every `put` makes one small heap
  allocation, the `Vec` of its guards.

## Pitfalls

- **Releasing the parent first.** `unlatch(parent); latch(child);` looks
  equivalent and passes most tests. It reopens exactly the gap coupling
  exists to close.
- **Reading the root id once.** The root pointer is not protected by any
  node's latch. Latch, then look again.
- **Waiting while holding.** See the convoy above. Chapter 20's B-link tree
  holds one latch at a time on the way down.
- **Publishing a node before it is finished.** A new node needs no latch
  while nobody can reach it. The store that makes it reachable (the parent's
  child pointer, or the root id) must come last.
- **Reusing nodes.** The second look at the root is only safe because a
  handle always names the same node. A delete that frees nodes needs a rule
  for when no thread can still hold the handle (chapter 24).
- **Sideways links.** A doubly linked leaf chain makes a leaf split write the
  *right neighbour's* back pointer: a latch beside the ones held, so a second
  latch order and a possible deadlock against a scan walking the other way.
  This chapter keeps only `next` and offers no concurrent range scan.
- **Upgrading a latch.** Two readers that both try to turn their shared latch
  into an exclusive one wait for each other forever. The writer here takes
  exclusive latches from the root down instead.
- **`validate()` and `dump()` are quiescent-only.** They are for after the
  threads have been joined.
- **A leaked latch is a hang, not a failure.** The next operation that needs
  the node waits forever. Run concurrent tests under a timeout
  (`timeout 120 zig build test`).

## Exercises

1. (easy) In the canonical tree, which latches does `put 4` hold when it
   reaches its leaf? And `put 18`? Check with the visualization.
2. (easy) `put 12` overwrites an existing key and cannot split anything. In
   the canonical tree it holds only leaf #1. Find an overwrite that keeps a
   parent latched, and explain why the rule cannot do better.
3. (medium) Change the reader to release the parent before it latches the
   child. Describe an interleaving with one reader and one writer in which the
   reader returns "not found" for a key that is in the tree the whole time.
   Which tests fail?
4. (medium) Writers latch the root exclusively on every `put`, although most
   puts change only a leaf. Describe a `put` that descends with *shared*
   latches and takes an exclusive latch only on the leaf. What must it do when
   the leaf is full?
5. (hard) Add a `prev` link to the leaves. Which latch does a leaf split now
   need that it does not hold? Give two operations that can deadlock, and one
   latch order that prevents it.

Solutions are in [solutions.md](solutions.md).

## Links

- Previous: [chapter 18, indexes in a database](../18-indexes-in-a-database/README.md)
- Next: [chapter 20, B-link trees](../20-blink-trees/README.md)
- Visualization: [viz/index.html](viz/index.html) (two threads, you choose who
  steps next, under four protocols and a broken fifth; one experiment with
  four threads shows the convoy)
