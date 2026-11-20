# Solutions for chapter 26

## 1. Next handle and vacuum victim

Maps: slab 0 `[##.#####]`, slab 1 `[...#....]`, slab 2 `[########]`.

`create` takes the lowest slab with a free slot, then its lowest free slot: slab 0,
slot 2. In the leaf pool that is handle `L0.2` = `(0 << 8) | 2` = `0x00000002`.

`vacuumBegin` needs at least two slabs and at least one slab's worth of free slots.
Free slots: 1 + 7 + 0 = 8, and a slab has 8, so it proceeds. The victim is the slab
with the fewest used slots: slab 1 (one item). That item is relocated to the only free
slot outside the victim, `0.2`, and slab 1 is released. Afterwards: `[########]`,
released, `[########]`.

The condition "free slots >= slots per slab" is exactly what guarantees room: if the
victim has `u` used slots it has `S - u` free ones, so the other slabs have at least
`S - (S - u) = u` free slots.

## 2. Buddy heap by hand

1024-byte heap, 64-byte minimum block. A request is rounded up to a power of two.

```
alloc 200 -> 256   [256 used][256 free][512 free]
alloc 200 -> 256   [256 used][256 used][512 free]
alloc 60  -> 64    [256 used][256 used][64 used][64 free][128 free][256 free]
free first 200     [256 free][256 used][64 used][64 free][128 free][256 free]
```

The freed block's buddy (the second 256) is in use, so nothing merges.

A request for 500 needs a 512-byte block. Free space is 256 + 64 + 128 + 256 = 704
bytes, more than enough in total, but the largest free block is 256: the request
fails. That is external fragmentation. It would succeed only after the second 200
were freed too (the two 256 blocks merge into a 512).

You can check with the code: `zig/src/buddy.zig`, test "split on alloc, merge on
free", has the same shape.

## 3. Generation counters in 32 bits

Per slot, keep a small counter that is incremented on every `destroy`. A handle
carries the counter value it was created under; `get` compares the two and rejects a
mismatch.

Zig sketch (slab side):

```zig
pub const Slab = struct {
    free: [words]u64,
    generation: [slots_per_slab]u8, // survives destroy/create of the slot
    used: u16,
    items: [slots_per_slab]T,
};
```

and in the pool:

```zig
// create: stamp the current generation into the handle
return .{ .slot = slot, .generation = slab.generation[slot], .slab = id, .class = class };
// destroy: every outstanding handle to this slot becomes stale
slab.generation[h.slot] +%= 1;
// isLive: additionally
if (slab.generation[h.slot] != h.generation) return false;
```

To stay within 32 bits the generation must take bits from the slab id, for example
`{ slot: u8, generation: u8, slab: u15, class: u1 }`: 32,767 slabs and 256
generations. Two consequences:

- The counter wraps. After 256 frees of one slot an old handle matches again, so the
  check is probabilistic, not a proof. Wider counters make the handle 64 bits, which
  is the usual trade (`GenHandle` in `rust/src/idioms.rs` uses 32 + 32).
- The generation array must not be reset when a slab is released and its id reused,
  or the first generation of the new slab collides with handles to the old one.
  Either keep the array in the directory (outside the slab) or never reuse slab ids.

Vacuum is unaffected: `relocate` returns a new handle with the new slot's generation.

## 4. Several victims per vacuum

Select victims while the remaining slabs can still absorb their items:

```
sort slabs by used count, ascending
free_elsewhere = total free slots
victims = {}
for slab in that order:
    f = slots - slab.used
    if free_elsewhere - f >= (items in victims) + slab.used:   # still room outside
        victims += slab; free_elsewhere -= f
    else break
```

(DuckDB computes the number of excess buffers as `free segments / segments per
buffer` and takes that many of the emptiest buffers,
`duckdb/src/execution/index/fixed_size_allocator.cpp:195-258`.)

In the code, `victim: ?u32` becomes a set (a bitset over slab ids is enough), and:

- `create` must skip **every** victim, not just one, and must never need a new slab
  during the vacuum. The selection rule above guarantees the second point: the items
  of all victims fit into the free slots of the non-victims.
- `destroy` releases a victim slab as soon as it is empty, as now.
- `vacuumEnd` checks that every victim is gone.

The tree side does not change at all: `moveIfVictim` asks the pool "is this handle in
a victim?", whatever the number of victims.

## 5. How many handle updates per moved node

In this chapter's tree a node is referenced from exactly one place, its parent's
child slot (or `root`): **1** update.

(a) B+tree with doubly linked leaves: moving a leaf changes the parent's child slot,
the `next` handle of its left sibling and the `prev` handle of its right sibling:
**3** updates, in three different nodes. The two siblings are not on the path from
the root, so the walk that finds the node does not have them at hand; it must
dereference them (and on disk, read and dirty two more pages).

(b) Parent handles in every node: moving a node changes the parent's child slot and
the parent handle stored in **each of its children**: 1 + (number of children)
updates, up to 1 + M. Moving a leaf is still 1.

With both features, an interior node costs 1 + M and a leaf 3.

What this says: compaction by relocation is cheap exactly when each node has a single
incoming reference. DuckDB's ART has that property and vacuums by moving nodes. A
disk B-tree with sibling links (Postgres) or a tree with parent pointers does not, so
such engines reclaim space differently: they merge or empty whole pages and put the
page on a free list, and they move live pages only in special, expensive operations.
