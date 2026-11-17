# 15. Redistribution and merge policies: solutions

The numbers quoted below come from applying the described change to the chapter's
programs and running them.

## 1. Balance by hand

Flattened: `40 40 30 30 30 20 50`, 240 bytes, capacity 100.

```
before     40 40 =80 | 30 30 30 20 =110 | 50 =50
pack left  40 40 =80 | 30 30 30 =90 | 20 50 =70
even out   (nothing moves)
```

Pack left: `40 40` is 80 and a `30` would make 110, so the first page closes. `30 30 30`
is 90 and the `20` would make 110, so the second closes. `20 50` is the rest.

Even out, last boundary: moving a `30` right gives 60 | 100; the right page would be the
bigger one, stop. First boundary: moving a `40` gives 40 | 130, stop.

Three pages in, three out. One cell changed page: the `20` moved from the middle page to
the right page, onto a page that already existed. The second divider in the parent
changes (it is now the key of the last `30`); the first divider stays.

## 2. A different stop rule

```zig
const before = if (left_used > right_used) left_used - right_used else right_used - left_used;
const l = left_used - c;
const r = right_used + c;
const after = if (l > r) l - r else r - l;
if (right_used != 0 and after >= before) break;
```

The original rule never lets the right page become bigger than the left; the new rule
allows an overshoot when it brings the pages closer. They differ for `30 30 30 | 25 25`
(90 | 50): the original stops (moving a `30` would give 60 | 80), the new rule moves it,
because a difference of 20 is better than 40.

Yes, results change. In section 1 of the output the first case ends as `90 | 60 | 70`
instead of `90 | 85 | 45`. The scenario dumps change, so the dump-comparing tests and
the expected-output test fail until updated; the model tests still pass, because any
cut that respects the capacity is a valid tree. In section 3, plain split under
ascending keys drops from 52.5% to 50.9% (the old rule's bias to the left happens to
help an append workload), and balance 3 under random inserts rises from 86.6% to 88.0%.

The lesson: the stop rule is a tuning choice. The invariants do not depend on it.

## 3. Pack left only

With `even_out = false`, three siblings and no fast path, ascending inserts give 596
pages at 98.2% fill, the same as the fast path. Packing left keeps every page but the
last full, and the leftover cell starts the next page, which is what an append wants.
It is still worse than the fast path: 595 balances and 1190 page writes instead of none,
because each overflow flattens and rewrites pages to arrive at the same picture.

Under random inserts it is a disaster. With plain splits (one sibling) the tree has
3909 pages at 14.9% fill instead of 855 at 68.5%: every overflow leaves one full page
and one page holding a single cell, and the full page overflows again at the next
insert that lands on it. With three siblings it is 1005 pages at 58.2%, with 10,986
balances and over 200,000 cells moved onto existing pages (27,876 page writes instead
of 11,594).

So "leave the left page full" is right only when you know the next inserts go to the
right. The fast path tests exactly that (last cell of the right-most leaf); pack-left
alone applies it everywhere. For index pages it can also leave the last sibling with no
cell at all, which is not a legal page (exercise 5).

## 4. Never free the right-most page

In `delete`, replace the fallback with

```zig
if (is_empty and ci + 1 < self.childCount()) self.removeEmpty(ci);
```

and in `validate` allow an empty page when it is the last child:

```zig
if (used == 0 and self.cfg.merge != .never and ci + 1 < self.childCount()) return error.Invalid;
```

(The balancing policies can also leave the right-most page empty if their rebalance
fails, so the relaxed check applies to all of them.)

None of the three workloads changes, not by a single page. Random deletes almost never
empty the last page; the queue is drained from the left; the churn never empties
anything. The restriction only costs something when the *largest* keys are deleted, and
then it costs exactly one page per level. That is why Postgres can afford it: it buys a
simpler traversal (there is always a right-most page to stop at) for one page.

## 5. Index-style leaves

Changes to the model:

- When flattening, insert the parent's divider cell between sibling `i` and sibling
  `i+1`. The array now holds every cell of the siblings *and* their dividers, in key
  order.
- A boundary is no longer "between cell `e-1` and cell `e`". The cell at each boundary
  is taken out of the leaf level and becomes the new divider in the parent. With `k`
  output pages, `k-1` cells of the array end up in the parent.

`packLeft` must therefore skip one cell at every boundary: when cell `i` does not fit
on the current page, cell `i` becomes the divider and the next page starts at `i+1`.
The sizes of the pages change accordingly; Turso's loop adds and subtracts the divider
cell's size when it moves a boundary (`turso/core/storage/btree.rs:4224-4240`). The
parent's free space also changes by the difference between old and new divider sizes,
so the parent can overflow even when the number of pages stays the same.

Why even-out is "not optional" here: suppose pack-left fills the first pages and the
last remaining cell is the one that does not fit. That cell becomes the divider, and
the page after it gets nothing. An empty non-root page is not allowed in this format.
Even-out pulls cells to the right until the last page is no longer the smaller one,
which in particular makes it non-empty. In the table-leaf model of this chapter the
problem cannot arise, because no cell is consumed at a boundary: if a cell does not
fit, it is itself the first cell of the next page.
