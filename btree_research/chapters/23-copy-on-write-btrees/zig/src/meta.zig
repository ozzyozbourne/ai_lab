//! The metapage: the ONE place that is overwritten, and how that stays safe.
//!
//! Every other page is written once into a free slot and never changed while
//! a committed root can reach it. But "which root is current" has to live at
//! a fixed address, or nobody could find it after a restart. So the metapage
//! has TWO slots and commits alternate between them:
//!
//!     commit of txn 7 writes slot 1   (7 % 2), slot 0 still holds txn 6
//!     commit of txn 8 writes slot 0   (8 % 2), slot 1 still holds txn 7
//!
//! A commit therefore never overwrites the slot of the newest committed
//! transaction. If the write is torn (chapter 21), the checksum of the half
//! written slot fails and the reader falls back to the other slot: the
//! previous commit, complete and untouched.
//!
//! Slot layout, 32 bytes, little-endian:
//!
//!     0   u64  txn_id      id of the transaction that wrote this slot
//!     8   u32  root        page id of the root, 0xFFFFFFFF = empty tree
//!     12  u32  height      levels (0 = empty, 1 = the root is a leaf)
//!     16  u64  count       number of entries
//!     24  u32  page_count  size of the page store in pages at this commit
//!     28  u32  checksum    CRC-32 of bytes 0..28
const std = @import("std");
const crc32 = @import("crc32.zig").crc32;
const PageId = @import("base_node.zig").PageId;

pub const slot_size = 32;
pub const Slots = [2][slot_size]u8;

pub const Meta = struct {
    txn_id: u64,
    root: PageId,
    height: u32,
    count: u64,
    page_count: u32,

    pub fn encode(self: Meta) [slot_size]u8 {
        var b: [slot_size]u8 = undefined;
        std.mem.writeInt(u64, b[0..8], self.txn_id, .little);
        std.mem.writeInt(u32, b[8..12], @backingInt(self.root), .little);
        std.mem.writeInt(u32, b[12..16], self.height, .little);
        std.mem.writeInt(u64, b[16..24], self.count, .little);
        std.mem.writeInt(u32, b[24..28], self.page_count, .little);
        std.mem.writeInt(u32, b[28..32], crc32(b[0..28]), .little);
        return b;
    }

    /// null if the checksum does not match: a slot that was never written
    /// (all zeroes: the CRC of 28 zero bytes is not 0) or a torn write.
    pub fn decode(b: *const [slot_size]u8) ?Meta {
        if (std.mem.readInt(u32, b[28..32], .little) != crc32(b[0..28])) return null;
        return .{
            .txn_id = std.mem.readInt(u64, b[0..8], .little),
            .root = @fromBackingInt(std.mem.readInt(u32, b[8..12], .little)),
            .height = std.mem.readInt(u32, b[12..16], .little),
            .count = std.mem.readInt(u64, b[16..24], .little),
            .page_count = std.mem.readInt(u32, b[24..28], .little),
        };
    }

    /// The rule a reader (or a restart) uses: of the slots whose checksum is
    /// valid, the one with the higher transaction id. null = no valid slot.
    pub fn pick(slots: *const Slots) ?Meta {
        const a = decode(&slots[0]);
        const b = decode(&slots[1]);
        if (a == null) return b;
        if (b == null) return a;
        return if (a.?.txn_id > b.?.txn_id) a else b;
    }

    pub fn checksum(b: *const [slot_size]u8) u32 {
        return std.mem.readInt(u32, b[28..32], .little);
    }
};

test "encode and decode round-trip, a flipped bit is detected" {
    const m: Meta = .{ .txn_id = 7, .root = .fromIndex(3), .height = 2, .count = 9, .page_count = 12 };
    var b = m.encode();
    try std.testing.expectEqual(m, Meta.decode(&b).?);
    b[9] ^= 0x10;
    try std.testing.expectEqual(null, Meta.decode(&b));
}

test "pick takes the valid slot with the higher transaction id" {
    const old: Meta = .{ .txn_id = 6, .root = .fromIndex(1), .height = 1, .count = 2, .page_count = 4 };
    const new: Meta = .{ .txn_id = 7, .root = .fromIndex(2), .height = 1, .count = 3, .page_count = 4 };
    var slots: Slots = @splat(@splat(0));
    try std.testing.expectEqual(null, Meta.pick(&slots)); // never written
    slots[0] = old.encode();
    try std.testing.expectEqual(old, Meta.pick(&slots).?); // one valid slot
    slots[1] = new.encode();
    try std.testing.expectEqual(new, Meta.pick(&slots).?); // higher id wins
    slots[1][0] ^= 0xFF; // torn write of the newest commit
    try std.testing.expectEqual(old, Meta.pick(&slots).?); // fall back
}
