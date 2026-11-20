# Chapter 19: solutions

Notation as in the chapter: `#n` handle, `[..]` internal node, `(..)` leaf,
S shared latch, X exclusive latch. The canonical tree:

```
                     #7[15]
        #2[6 10]                  #6[20]
#0(1 3 5)  #4(6 7)  #1(10 12)     #5(15 17)  #3(20 25 30)
```

Where an answer says "ran", the experiment was run against the chapter's Zig
code with the `LatchSpy` helper of `tests.zig` or with `probe.Actor`, in a
scratch copy. Where it says "expected", it was reasoned and not run.

## 1. Latches held by `put 4` and `put 18`

`put 4`: X on #7. X on #2, which holds 2 of 3 keys and is safe, so #7 is
released. X on #0, which holds 3 of 3 keys and is full, so #2 is kept. At the
leaf the writer holds **#2 and #0**. The leaf splits into #0(1 3) and a new
#8(4 5); separator 4 goes into #2, which becomes `[4 6 10]`.

`put 18`: X on #7. X on #6 (1 key, safe), release #7. X on #5 (2 keys, safe),
release #6. At the leaf the writer holds **#5** only.

Ran: the spy reported `{0, 2}` for `put 4` and `{5}` for `put 18`, and the
tree after `put 4` was

```
level 0: #7[15]
level 1: #2[4 6 10] #6[20]
leaves : #0(1 3) -> #8(4 5) -> #4(6 7) -> #1(10 12) -> #5(15 17) -> #3(20 25 30)
```

## 2. An overwrite that keeps a parent latched

`put 25` (or `put 20`, `put 30`, and likewise `put 1`, `put 3`, `put 5`). The
key is in leaf #3, which is full. When the writer latches #3 it sees a full
node and keeps #6, although the overwrite will not split anything.

Ran: `put 25` on the canonical tree holds `{3, 6}` at the leaf. `put 12` holds
`{1}`. The chapter's test `the safe-node rule decides which latches a put
keeps` checks the same for `put 3` (`{0, 2}`).

Why the rule cannot do better: it decides whether to release the parent at the
moment the child is latched, from the child's key count alone. To know that
the key already exists the writer has to search the leaf, and by then it
either still holds the parent (nothing gained) or has released it (and cannot
get it back without breaking the top-down latch order). A writer could search
the full leaf first and then release the parent early when it finds the key;
that shortens the time the parent is held, but the parent was still latched
on the way down.

## 3. Releasing the parent before latching the child

The change, in `coupled.get`:

```zig
unlatch(tree, io, id, .shared);
latch(tree, io, child, .shared, hook);
```

An interleaving on the canonical tree, reader `get 30`, writer `put 26`:

1. Reader: S on #7, moves to #6, reads "key 30 goes to child #3", releases #6.
   It now holds **nothing** and remembers the handle #3.
2. Writer: `put 26` runs from start to end. Leaf #3 is full; it splits into
   #3(20 25) and the new #8(26 30); separator 26 goes into #6.
3. Reader: S on #3, searches (20 25), answers "30 is not there".

Key 30 was in the tree the whole time. It moved to #8 while the reader stood
between two nodes.

Ran, with one extra hook call added in the gap so that the reader could be
frozen there: the reader's `get 30` returned null, a `get 30` right afterwards
returned 3000, and the tree was

```
level 1: #2[6 10] #6[20 26]
leaves : ... -> #5(15 17) -> #3(20 25) -> #8(26 30)
```

Which tests fail (ran three times with only the two swapped lines):

- `latch coupling: a get holds at most two latches, and only the leaf at the
  end` failed in all three runs (it sees one latch where it expects two).
- `stress: 4 threads, disjoint and overlapping keys, every protocol` failed in
  one run of three, and the demo-output test in one run of three. The window
  is a few instructions wide, so a stress test hits it only sometimes.

With coupling the same interleaving cannot happen: the reader still holds S on
#6 when it asks for #3, and the writer needs X on #6 to finish its split. One
of them waits. (The writer does not need #6 for long, but it needs it before
it changes #3.) The chapter's probe `A = put 26, B = get 17` shows the
symmetric case: the reader waits at #6.

Chapter 20 shows the other fix. PostgreSQL does release the parent first, as
this broken version does, and repairs the result: the reader compares its key
with the leaf's high key and moves right to #8.

## 4. Shared latches on the way down

Sketch (expected; not implemented in the chapter, not measured):

```
put(key, value):
    descend like get: S latches, coupled, down to the PARENT of the leaf
    latch the leaf X while holding the parent S, then release the parent
    if the key is in the leaf, or the leaf has room:
        insert / overwrite; release the leaf; done
    else:                               # the leaf must split
        release the leaf
        run the pessimistic put of this chapter from the root
```

The descent needs coupling for the same reason the reader does. Taking X on
the leaf while holding S on the parent is not an upgrade (the leaf was not
latched before), so it cannot create the upgrade deadlock.

When the leaf is full the writer must not try to "go back up" for the parent:
it holds a latch below and would wait for one above, which is the reverse of
the latch order. It lets go of everything and starts again with exclusive
latches. Between the two descents the tree may have changed (someone else may
have split that leaf, or filled another); the second descent is a complete
pessimistic `put` and does not rely on anything the first one saw.

What this is expected to buy: writers stop excluding each other and the
readers at the root and the upper levels, at the price of a second descent
for the inserts that split. In the chapter's example, `put 11` would take S
instead of X on #7 and #2 on its way down. How much that helps depends on the
workload and was not measured here. The optimistic protocol in the visualization goes one step further and
takes no latch at all on the way down.

## 5. A `prev` link

With `prev`, a split of leaf L into L and a new R' must set
`old_next.prev = R'`. `old_next` is L's right neighbour: a node the writer
does **not** hold. It is not on the writer's path, so the top-down rule says
nothing about it.

The writer therefore has to latch `old_next` exclusively while holding L: a
left-to-right step on the leaf level.

A deadlock (expected; not run, because the chapter has neither `prev` nor a
scan):

- Writer W holds X on leaf L, is splitting it, and waits for X on L's right
  neighbour N.
- A backward scan B holds S on N, has finished with it, and waits for S on L
  (it follows `N.prev`, and it couples like every reader: latch the next node
  before releasing this one).

W waits for B and B waits for W. Neither can release.

One order that prevents it: **on one level, latches are only ever acquired
left to right**; combined with top-down between levels this is again a single
global order. Then W's step from L to N is allowed, and B's step from N to L
is not. A backward scan must release N first, then latch L, and then check
that it arrived where it meant to (`L.next == N`): L may have split in the
gap, in which case the scan moves right from L until it finds the node whose
`next` is N.

That is what PostgreSQL does. Its split locks the former right sibling while
holding the page being split, and its README notes this is safe because no
writer of that sibling can want a write lock on the page being split; a
backward scan, after following the left link, moves right until it finds the
page whose right link matches the page it came from
(`postgres/src/backend/access/nbtree/README:76-85`).
