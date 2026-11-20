# Chapter 18: solutions

Numbers marked **measured** were produced by running code against this chapter's Zig
library (a temporary test using `buildDemo`, `fetchScan`, `countOnDay` and `Cursor`, which
is not part of the repository). Everything else is reasoning from the code and is marked
as such; it was not run.

## 1. Cost of `SELECT * WHERE customer = 3`

From section 1 of the output, the index leaves are

```
(3,4,#3) (3,4,#20) | (3,9,#30) (3,28,#1) | (7,3,#12) (7,12,#5) | ...
```

The seek for (3, 0, smallest locator) is smaller than every key, so the descent ends in
the first leaf: 3 nodes. The scan returns two entries, hops to the second leaf, returns
two more, hops to the third leaf and sees (7,3,#12), which is past the range. That is 2
hops, 5 tree nodes for the index part, 4 entries.

- Clustered: 4 row fetches, each a descent of the height-3 primary tree: 12 more nodes.
- Heap: 4 row fetches, each one heap read.

Measured:

```
clustered: descents=5 tree nodes=17 index entries=4 row fetches=4 heap reads=0 -> 17 page reads
heap     : descents=1 tree nodes=5  index entries=4 row fetches=4 heap reads=4 -> 9 page reads
```

## 2. Why the unique check is a prefix probe

The key of `by_code` is (code, locator). (Reasoning, not run.)

- `get(columnKey(code, 0))` looks for the exact key (code, locator 0). A row with that
  code at any other locator is a different key, so `get` returns null and the duplicate is
  accepted. It would only catch a conflict with the row whose id (or TID) is 0.
- `get(columnKey(code, locator))` with the *new* row's locator looks for the new row's own
  entry. Before the insert it is not there, whatever other rows contain. In the heap
  layout the new locator does not even exist before the row is appended.

The question is "is there any entry whose first column is this code", and its answer is
the first key at or after (code, 0), compared on the code part only. That is `probe`:
`Cursor.seek(tree, columnRange(code))` followed by one `next`. The tests
"unique constraint and primary key reject duplicates" and the model test (which generates
duplicate codes on purpose) exercise it.

## 3. An INCLUDE column in the value slot

Not implemented in the repository and not run; the following is a design derived from the
code.

- `insert`: pass `row.amount` instead of `0` as the value of the `by_customer_day` entry.
  Nothing else in `insert` changes, and the rollback is the same `delete` of the same key.
- `delete`: unchanged. The entry is still named by (customer, day, locator); the value
  takes no part in finding it.
- `Cursor.next` returns only the key. Either give it a sibling that also returns
  `n.kind.leaf.values[self.index]`, or use the base `LeafWalker` (which returns key and
  value) with the same range check.
- `validate`: additionally check `row.amount == value`.
- An update of `amount` now has to update the index entry too. That is the price of an
  included column: one more tree to write on every change of that column.

Expected cost of `amountsOfCustomer(7)`: the same cursor walk as the covering scan of
section 4, so the same line, `descents=1 tree nodes=6 ... row fetches=0 -> 6 page reads`
in both layouts, against 21 and 11 for the fetching query of section 3. This is an
expectation from the code path, not a measurement.

Why the value and not the key: an included column is payload. In the key it would take
part in ordering and in separators for no benefit. Postgres drops INCLUDE columns from
pivot tuples for that reason (`nbtree/README:834-838`).

## 4. `updateDay`, in place and to a new slot

Not implemented in the repository and not run; descents are counted from the code paths
of `delete` and `insert`.

In place, `day` is in the key of `by_customer_day` only:

- Clustered: read the row (1 descent), remove the old index entry (1), insert the new one
  (1), overwrite the row in the primary tree (1). 4 descents. `by_code` is untouched.
- Heap: probe the primary key index (1 descent), read the heap slot (1 heap read), remove
  and insert the `by_customer_day` entry (2), overwrite the slot in place. 3 descents and
  one heap read. The primary key index and `by_code` are untouched because the TID did not
  change.

If the changed row is written to a new heap slot, its TID changes, and the TID is part of
*every* index key in the heap layout. The primary key entry (id, TID) and the `by_code`
entry (code, TID) must be replaced too, although neither id nor code changed: 2 more
removes and 2 more inserts, 7 descents in total. In the clustered layout the same update
still touches one index, because the locator is the id and the id did not change.

This is the general trade-off of the chapter seen from the write side: an address is cheap
to follow and expensive to keep correct when rows move; a key costs a descent to follow
and never needs fixing. Postgres' answer to the write-side cost is HOT (see
`postgres/src/backend/access/heap/README.HOT`), which this guide did not study.

## 5. Skip scan for `WHERE day = ?`

The loop, using only the public cursor (this is the code that was run):

```zig
fn skipScan(table: *Table, day: u16) usize {
    var count: usize = 0;
    var customer: u32 = 0;
    while (customer <= 65535) {
        // Smallest key with customer >= `customer`: tells us the next customer that exists.
        var probe = Cursor.seek(&table.by_customer_day,
            .{ .lo = row_.customerDayKey(@intCast(customer), 0, 0), .hi = std.math.maxInt(u64) },
            &table.counters);
        const first = probe.next() orelse break;
        const c = row_.keyCustomer(first);
        // The run (c, day): a normal two-column prefix scan.
        var run = Cursor.seek(&table.by_customer_day, row_.customerDaysRange(c, day, day), &table.counters);
        while (run.next()) |_| count += 1;
        customer = @as(u32, c) + 1;
    }
    return count;
}
```

Measured (identical for both layouts, since no row is fetched):

| table | method | result | descents | tree nodes | index entries |
|---|---|---|---|---|---|
| 12 rows, M = 4, day 12 | `countOnDay` | 2 | 1 | 7 | 12 |
| 12 rows, M = 4, day 12 | skip scan | 2 | 7 | 24 | 5 |
| 2000 rows, M = 16, day 180 | `countOnDay` | 2 | 1 | 186 | 2000 |
| 2000 rows, M = 16, day 180 | skip scan | 2 | 101 | 320 | 52 |

The skip scan makes two descents per distinct customer plus one to find that there are no
more (3 customers: 7; 50 customers: 101). It reads far fewer entries (52 instead of 2000)
but, on these tables, **more** tree nodes: 320 against 186. With 50 customers and only
about 185 leaves, two descents of height 3 per customer cost more nodes than walking every
leaf once.

So it wins when the number of distinct leading values is small compared with the number
of leaf pages: roughly when `2 * distinct * height` is less than the leaf count. That
condition is reasoning from the two formulas, and the table above shows two cases on the
losing side of it; a winning case was not measured. A real implementation also avoids
the first of the two descents per value when the next customer is on the same leaf
(Postgres' skip arrays, `nbtree/nbtpreprocesskeys.c:110-127`, are considerably more
refined than this loop).
