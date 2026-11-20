# Chapter 08: solutions

Every result below was produced by running this chapter's code: either it is
in `expected_output.txt`, or it came from the JavaScript port of the same
model (`viz/local.js`, which a self-test ties to that output), or from a
scratch test as stated. Where something was not run, it says so.

## 1. `(7, 20]` backward by hand

A backward scan starts at the upper bound. It is included, so the seek is
`le 20`: the last key `<= 20`.

- `#7[15]`: 20 >= 15, child 1.
- `#6[20]`: 20 equals the separator and goes right, child 1: leaf
  `#3(20 25 30)`.
- `upperBound(20)` in `(20 25 30)` is 1, so one key qualifies and the cursor
  lands on index 0: key 20.

Then `prev` repeatedly, testing the lower bound `key > 7`: 20, then leaf
`#5`: 17, 15, then leaf `#1`: 12, 10, then leaf `#4`: 7 fails the test.

Result: `20 17 15 12 10`. Run with the model: the same five keys; the link
cursor makes 6 node moves (3 for the descent, then `#5`, `#1`, `#4`), the
stack cursor 11.

## 2. Accounting for 7 and 13 node visits

The trace for `[5, 20]` forward:

```
5    #0[2]        #7.0 #2.0 -> #0[2]
6    #4[0]        #7.0 #2.1 -> #4[0]
7    #4[1]        #7.0 #2.1 -> #4[1]
10   #1[0]        #7.0 #2.2 -> #1[0]
12   #1[1]        #7.0 #2.2 -> #1[1]
15   #5[0]        #7.1 #6.0 -> #5[0]
17   #5[1]        #7.1 #6.0 -> #5[1]
20   #3[0]        #7.1 #6.1 -> #3[0]
```

Both cursors visit 3 nodes for the seek (`#7`, `#2`, `#0`). The scan then
crosses four leaf boundaries: 5|6, 7|10, 12|15, 17|20. After returning 20
both cursors step once more inside leaf `#3` (to 25, which fails the upper
bound); that step changes no node.

- Link cursor: 3 + 1 + 1 + 1 + 1 = **7**.
- Stack cursor: the path changes only in its last frame at 5|6, 7|10 and
  17|20 (up to the parent, down to the new leaf: 2 moves each). At 12|15
  the first frame changes too: up to `#2`, up to `#7`, down to `#6`, down to
  `#5`, 4 moves. 3 + 2 + 2 + 4 + 2 = **13**.

The test `the stack cursor's path is the root-to-leaf route` asserts the 4
for the 12|15 boundary.

## 3. `certainlyEmpty`

```zig
/// True only if NO u64 can be inside the range.
pub fn certainlyEmpty(lo: Bound, hi: Bound) bool {
    const max = std.math.maxInt(u64);
    const l = switch (lo) {
        .unbounded => return switch (hi) {
            .excluded => |k| k == 0, // "key < 0"
            else => false,
        },
        .included, .excluded => |k| k,
    };
    const h = switch (hi) {
        .unbounded => return lo == .excluded and l == max, // "key > max"
        .included, .excluded => |k| k,
    };
    if (l > h) return true; // inverted
    if (l == h) return lo == .excluded or hi == .excluded; // only [k, k] has a key
    // Integers only: nothing lies strictly between k and k + 1.
    return lo == .excluded and hi == .excluded and h - l == 1;
}
```

This function is not part of the chapter's sources. It was appended to a
scratch copy of `bounds.zig` together with a test that tries every pair of
bounds built from the values 0, 1, 2, 3, 4, max-3, max-2, max-1, max (361
pairs) and compares the result with "does `contains` accept any of 13 probe
keys around those values". The test passed; 180 of the 361 pairs are empty.

For byte-string keys two cases change:

- The last line is wrong. Between two different strings there is always
  another string (`"a"` < `"a\x00"` < `"b"`), so `(k, k')` with both ends
  excluded is not empty just because the keys are "adjacent".
- The checks against the ends of the key space change: the smallest string
  is the empty string, so `< ""` is empty, and there is no largest string
  unless the key length is bounded.

The scan does not need this function for correctness: section 2 of the
output shows the empty and inverted ranges returning nothing without it. It
only saves the descent.

## 4. Re-seek counts, and a scan that never ends

A cursor re-seeks at its next step whenever the tree changed since its last
step. In the demo each delete happens right after an entry is returned, so
there is one re-seek per delete: the even keys are 6, 10, 12, 20, 30, hence
5.

Run with the model (`viz/local.js`, both designs give the same counts):

| The scan deletes | Keys returned | Re-seeks | Keys left |
|---|---|---|---|
| every even key | 12 | 5 | 1 3 5 7 15 17 25 |
| every odd key | 12 | 7 | 6 10 12 20 30 |
| every key | 12 | 12 | none |
| nothing | 12 | 0 | all 12 |

Deleting every key gives 12 re-seeks, not 11: the delete of 30 is followed
by one more `next`, which re-seeks and finds nothing. The Zig and Rust test
`delete while scanning: every entry is returned once` covers the "every key"
row for the returned keys and the empty tree.

Inserting `key + 1` after every returned key: the scan does not terminate.
The run was cut off after 40 steps, and the keys returned up to there were
1, 2, 3, ..., 40. Each `put` either creates the entry that the following
`next` returns or, when `key + 1` is already in the tree, overwrites it. The
second case happens 11 times in these 40 steps (for 3, 5, 6, 7, 10, 12, 15,
17, 20, 25 and 30): an overwrite does not change the tree version, so the
`next` after it is an ordinary step. The other 28 of the 39 `next` calls are
re-seeks for "first key > the one just returned" (both designs; from 31 on
every step is one). A side effect: the scan replaces the values of those 11
existing entries with whatever it writes. The guarantee of
the chapter holds for every single step and still the scan is infinite,
because it keeps creating entries ahead of itself. The usual cures are to
collect the keys first and modify afterwards (`collect`), or to scan a
snapshot (chapters 23 and 24). Neither is implemented in this chapter.

## 5. Page-at-a-time instead of re-seeking

Not implemented and not measured; this is a design discussion checked
against the chapter's own output where it makes a concrete claim.

The design: on arriving in a leaf, copy the entries that are inside the
bounds into a buffer in the cursor, and remember the leaf's `next` handle
(or `prev`) as it is at that moment. Return entries from the buffer; when it
is empty, go to the remembered leaf.

What such a scan would see, compared with the re-seeking cursor:

- An insert into the *current* leaf, ahead of the cursor: missed, because
  the buffer was filled earlier. The re-seeking cursor returns it.
- A delete in the current leaf, ahead of the cursor: still returned from the
  buffer although it is gone. The re-seeking cursor skips it.
- Inserts and deletes in leaves not yet visited: seen correctly, as long as
  the leaf structure stays intact (next point).

So the guarantee becomes "consistent per leaf as of the moment the leaf was
read", which is weaker than this chapter's and is acceptable in Postgres
because row visibility is decided elsewhere (chapter 24).

What breaks the idea in this chapter's tree:

1. **Entries move across leaf boundaries in both directions.** Deletes
   rebalance by borrowing from a sibling and by merging. Section 6 of the
   output shows it: before the deletes the leaves are `#5(15 17) <->
   #3(20 25 30)`, after them `#5(20) <-> #3(25 30)`. Key 20 moved left, from
   `#3` into `#5`. A forward scan that had buffered `#5` as `(15 17)` and
   then continues with `#3` would never return 20, although 20 was in the
   tree the whole time. Postgres's scheme depends on items never moving
   across existing page boundaries except to the right by a split (quoted in
   the README), and its pages are not merged this way.
2. **Handles are recycled immediately.** A merge frees a leaf, and the next
   split reuses that handle for an unrelated leaf (the test `handles are
   reused` shows the reuse). A remembered `next` handle can therefore name a
   leaf somewhere else in the key order. Postgres delays recycling a deleted
   page until no scan can still hold a link to it (chapter 24).

With both properties in place (no borrowing or merging across boundaries,
delayed reuse of freed nodes) the design works and avoids the descent of a
re-seek; without them, saving the key is the simple correct choice.
