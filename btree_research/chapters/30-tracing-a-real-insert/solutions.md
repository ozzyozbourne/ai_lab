# Chapter 30: solutions

Outcomes marked "run" were produced by making the change in `zig/src/resumable.zig` and
running `zig build test`; the file was restored afterwards. Everything else is a design
sketch and says so.

## 1. Append to the path before asking for the page

The changed arm:

```zig
.descend => {
    try self.path.append(self.arena.allocator(), .{ .id = self.cur, .index = 0 });
    if (self.need(self.cur)) |id| return .{ .io = id };   // may return here ...
    ...                                                    // ... and then runs the append again
    self.path.items[self.path.items.len - 1].index = index;
```

Run: 9 of the 66 tests fail. The most direct report comes from "an operation re-entered
before its page arrived makes no progress and changes nothing":

```
Field path_len incorrect. expected 2, found 3
```

Each extra call added the same page to the path once more. The path then contains the
page twice, the first copy with the placeholder index 0. The inserts themselves do not
corrupt the file silently: when a split later walks back up, `insertSeparator` checks
that the child at the remembered index is the page that split, finds that it is not, and
returns `error.Corrupt`. By then the leaf has been split, so the handle is poisoned (the
byte-identity test reports `expected .done, found .failed`). The lesson of the exercise
is the order of the two failures: the re-entry test points at the line that is wrong,
the workload test only says that something is.

This is the first row of Turso's table of re-entrancy bugs
(`turso/docs/agent-guides/async-io-model.md:166`): "`vec.push(x); return_if_io!(...)`:
Vec grows on each re-entry".

## 2. Pop the path before asking for the parent

```zig
.insert_separator => {
    const parent = self.path.pop().?;
    if (self.need(parent.id)) |id| return .{ .io = id };
```

Run: the first time this state yields, the entry is gone. On re-entry `pop()` returns
null for a two-level tree (the path held one entry), and the Debug build panics with
`attempt to use null value`; every test that splits a leaf with a small pool aborts. In a
deeper tree `pop()` would return the grandparent instead, and the separator would be
offered to the wrong page; the check in `insertSeparator` would report `error.Corrupt`.
That second case was not run.

The correct arm reads the top with `getLast()`, may yield, and pops only after
`insertSeparator` has returned.

## 3. Share in-flight reads (sketch, not run)

Give `SimDisk` a map from page id to the list of operations waiting for it. `submit`
appends to the list and creates a request only if the page had none. `completeOne`
reads the page once and returns all waiters; the scheduler must then step **each** of
them before it completes another read, or a small pool could evict the page before the
second waiter ran. In Part 3 of the demo the three lookups all ask for page 1 first, so
the expected change is one "disk: page 1" line that wakes #0, #1 and #2, and two fewer
completions. The expected output would change, so the test that compares it must be
updated with the new text.

Turso does the same thing in the pager (`pending_reads`, `turso/core/storage/pager.rs:1627`).

## 4. Yield on page allocation too (sketch, not run)

`splitLeaf` does three things: copy the page and compute the two halves, allocate the
right page, write both halves. The allocation is in the middle, so the step must be cut
in two:

```
split_leaf_prepare   needs the leaf; computes the halves into the arena;
                     asks for a new page                      -> may yield (write)
split_leaf_apply     needs the leaf AND the new page pinned;
                     writes both halves                       -> no yield inside
```

The same for `pushRootDown` and `splitInterior`. The hardest rule is R3, "no pin across
a yield". Between `prepare` and `apply` the leaf is unpinned, so `apply` must not trust
the halves it computed if anything could have changed the leaf meanwhile. With a single
writer nothing can, but the page can be evicted, so `apply` must ask for it again (R1),
and the halves must live in the arena because they are computed in one call and used
in another. This is the shape of Turso's `balance_non_root`: `NonRootDoBalancing`
computes, `NonRootDoBalancingAllocate { i, context }` allocates one page per entry
with its progress in the state, and `NonRootDoBalancingFinish { context }` writes
(`turso/core/storage/btree.rs:296-324`).

## 5. Readers during an insert, without a WAL (sketch, not run)

What goes wrong is shown by the test "a reader let in while a split is half done misses
a key": after `split_leaf` the right half is reachable only through the left leaf's
link, and a lookup that lands on the left leaf stops there.

The B-link answer (chapter 20):

- every page stores a high key, an upper bound for the keys it may hold, and a right
  link (the leaves of this tree already have the link; interior pages need one too);
- `split_leaf` and `split_interior` set the left page's high key to the separator and
  link the new page in, in the same step that moves the keys;
- a lookup that arrives on a page and finds its key at or above the high key follows
  the right link and checks again. It must do this on every level, including the leaf.

The check goes into `GetOp.step` right after the page is pinned and before the binary
search. The scheduler may then admit lookups while an insert waits.

`pushRootDown` needs no extra rule. A lookup that waits holds only a page id and reads
the page's kind again every time it is stepped. If the root's content moved down
meanwhile, the lookup finds an interior root with no key and one child, follows it, and
arrives at the old content. The remaining condition is the one in the list above: each
split must set the high key and the right link in the same step that moves the keys,
for `split_interior` as well as for `split_leaf`.
