# Chapter 28: solutions

## 1. `team`, `tea`, `ten`

Encoded keys: `team\x00`, `tea\x00`, `ten\x00`.

After `team` (5 bytes fit in one prefix node):

```
prefix "team\x00" -> leaf 1
```

After `tea`: the stored prefix and the new key agree on `tea`, then differ (`m` against
`\x00`). Head `tea` stays, a Node4 gets the two bytes. The old tail after `m` is `\x00`.
The new key has nothing left after its `\x00`, so its child is the leaf itself:

```
prefix "tea" -> node4 [2]
  '\x00' -> leaf 2
  'm' -> prefix "\x00" -> leaf 1
```

After `ten`: the prefix `tea` mismatches at its last byte (`a` against `n`). The head is
`te`. The old tail after `a` is empty, so no tail node is created and the existing Node4
becomes the child for `a` directly. This is the split with an empty old tail:

```
prefix "te" -> node4 [2]
  'a' -> node4 [2]
    '\x00' -> leaf 2
    'm' -> prefix "\x00" -> leaf 1
  'n' -> prefix "\x00" -> leaf 3
```

Two prefix splits, three prefix nodes, two Node4. Note that `\x00` sorts before `m`, so
`tea` comes before `team` in iteration order, as it should. You can check the drawings
by pasting the three `put` calls into a test and printing `dump`.

## 2. Elements read per layout

| Layout | Worst case for one byte | Elements |
|---|---|---|
| Node4 | scan all key bytes, then read one child | 4 + 1 |
| Node16 | scan all key bytes, then read one child | 16 + 1 |
| Node48 | one index entry, one child | 1 + 1 |
| Node256 | one child | 1 |

A Node48 with 48 sorted key bytes would need a scan of up to 48 bytes, or a binary
search with about six unpredictable branches. The 256-entry index costs 256 bytes per
node and turns the search into one array read. The positions are one byte each because
48 children need only values 0 to 47, with 48 free to mean "empty". The alternative of
256 full child references is the Node256, which is several times larger; Node48 exists
to cover the range where that would be mostly empty. The index also keeps the node
ordered without sorting anything: iterating byte values 0 to 255 visits children in key
order, while the `children` array itself stays in insertion order.

## 3. `min` and `max`

`min` follows the first child at every inner node, `max` the last. `nextChild(ref, 0)`
is "first child". For "last child" you need the mirror image, a `prevChild(ref, from)`
that returns the last child with byte less than or equal to `from`:

```zig
fn prevChild(ref: Ref, from: u8) ?ByteChild {
    switch (ref) {
        inline .n4, .n16 => |n| {
            var i: usize = n.count;
            while (i > 0) {
                i -= 1;
                if (n.keys[i] <= from) return .{ .byte = n.keys[i], .child = n.children[i] };
            }
            return null;
        },
        .n48 => |n| {
            var b: usize = from;
            while (true) : (b -= 1) {
                const slot = n.index[b];
                if (slot != Node48.empty48) return .{ .byte = @intCast(b), .child = n.children[slot] };
                if (b == 0) return null;
            }
        },
        .n256 => |n| {
            var b: usize = from;
            while (true) : (b -= 1) {
                if (n.children[b] != .none) return .{ .byte = @intCast(b), .child = n.children[b] };
                if (b == 0) return null;
            }
        },
        else => unreachable,
    }
}

/// Largest key. Appends its bytes to `key` and returns its value.
pub fn max(self: *const Art, gpa: Allocator, key: *std.ArrayList(u8)) !?u64 {
    var ref = self.root;
    while (true) {
        switch (ref) {
            .none => return null,
            .leaf => |v| return v,
            .prefix => |p| {
                try key.appendSlice(gpa, p.slice());
                ref = p.child;
            },
            .n4, .n16, .n48, .n256 => {
                const last = prevChild(ref, 255).?; // inner nodes are never empty
                try key.append(gpa, last.byte);
                ref = last.child;
            },
        }
    }
}
```

`min` is the same loop with `nextChild(ref, 0)`. Both cost one step per node on the
path, like a lookup. `prevChild` is also all a backward iterator needs: keep the same
stack, store "previous byte to try" in each frame, and count down.

## 4. Deleting from the hash index

Why emptying the slot is wrong. Suppose `A`, `B` and `C` all hash to slot 5. Inserted in
that order they occupy slots 5, 6 and 7. Now delete `B` by marking slot 6 empty. A lookup
of `C` starts at 5, sees `A`, moves to 6, sees an empty slot and concludes that `C` is
not present. But `C` is in slot 7. A later `put(C)` would even insert a second copy at
slot 6. Lookup relies on the invariant "there is no empty slot between a key's home slot
and the key".

**Tombstones.** Give a slot three states: empty, full, deleted. `delete` marks the slot
deleted. A probe walks past deleted slots. `put` of a new key may reuse the first deleted
slot it passed, but only after the probe has reached an empty slot (otherwise it could
duplicate a key that sits further along). Tombstones count toward the load factor,
because they lengthen probe runs like live entries do; when `len + tombstones` exceeds
the limit, rebuild the table, which drops them. `validate` additionally checks that the
tombstone counter matches the number of deleted slots.

**Backward shift** keeps two states and repairs the run instead:

```zig
pub fn delete(self: *HashIndex, key: []const u8) ?u64 {
    if (self.slots.len == 0) return null;
    const mask = self.slots.len - 1;
    var hole = self.probe(keys.fnv1a(key), key).index;
    const removed = self.slots[hole];
    const owned = removed.key orelse return null; // not present
    self.gpa.free(owned);
    self.len -= 1;

    // Walk the rest of the run. An entry may move into the hole only if its
    // home slot is not cyclically inside (hole, j]: otherwise the move would
    // put it before its home slot and lookups would no longer find it.
    var j = hole;
    while (true) {
        j = (j + 1) & mask;
        const next = self.slots[j];
        if (next.key == null) break;
        const home: usize = @intCast(next.hash & mask);
        const distance_from_home = (j -% home) & mask;
        const distance_from_hole = (j -% hole) & mask;
        if (distance_from_home >= distance_from_hole) {
            self.slots[hole] = next;
            hole = j;
        }
    }
    self.slots[hole] = .{};
    return removed.value;
}
```

The existing `validate` already checks the invariant that matters: every entry is found
at the slot where `probe` ends. A model test with `delete` weight above zero against the
oracle exercises it.

Backward shift keeps lookups fast and needs no rebuild, but moves entries on delete.
Tombstones make delete a single write but degrade lookups until the next rebuild.

## 5. Deleting from the ART

Outline (DuckDB: `art_operator.hpp:257-327`, `base_node.cpp:78-102`, `node48.cpp:38-56`,
`node256.cpp:14-31`):

1. Descend as in `lookup`, remembering the path. If the key is absent, stop.
2. Remove the leaf's byte from its parent inner node (`removeChild`). In Node4 and Node16
   shift the tail of `keys` and `children` left. In Node48 set `index[byte]` to empty; the
   child slot becomes a hole, so `addChild` can no longer assume that slot `count` is
   free and must look for an empty slot. In Node256 clear the slot.
3. Shrink if the count has fallen far enough: Node256 to Node48 at 36 or fewer children,
   Node48 to Node16 below 12, Node16 to Node4 below 4. Shrinking is `grow` in reverse:
   allocate the smaller node, copy, free the larger one, hand the new reference to the
   parent.
4. A Node4 left with one child no longer branches. Replace it with a prefix that holds
   its one remaining byte, then merge adjacent prefix nodes: (prefix above) + byte +
   (prefix below) are concatenated into as few 7-byte prefix nodes as possible.
5. A leaf that hangs below a prefix chain: free the whole chain when the leaf goes.
6. Update `validate`: the minimum counts become Node4 at least 2, Node16 at least 4,
   Node48 at least 12, Node256 at least 37, and Node48 may have holes (`index` maps onto
   distinct occupied slots, not onto `0..count`).

Failure atomicity is harder than for insert, because shrinking and prefix merging
allocate during a delete. The simple rule: if the smaller node cannot be allocated,
leave the larger one in place. An oversized node is still correct.

Why the thresholds are below the capacities. With "shrink as soon as it fits" a node
holding 16 children would grow to Node48 on the next insert, shrink to Node16 on the next
delete, grow again on the next insert, and so on. Every one of those operations
allocates, copies and frees a node. With the lower thresholds a Node48 shrinks only when
it has fewer than 12 children; the resulting Node16 then takes six more inserts before
it has to grow again. The gap between "grow at" and "shrink at" is hysteresis: it bounds
how often an alternating workload can make a node change layout. A B-tree has the same
idea in its "merge at less than half, split at full" rule, and real engines widen the gap
further (chapter 15: Postgres never merges non-empty pages at all).
