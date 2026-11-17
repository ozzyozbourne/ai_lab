//! Checksummed pages: how a reader tells a good page from a damaged one.
//!
//! Layout of a 4096-byte page:
//!
//!     0 ......................... 4091 | 4092 .. 4095
//!     payload (payload_size bytes)     | CRC-32, little-endian
//!
//! The CRC covers the page number (8 bytes, little-endian) followed by the
//! payload. Mixing in the page number means a perfectly good page that lands
//! at the wrong address (a misdirected write) or is read from the wrong
//! address also fails verification.
//!
//!     seal(&page, page_no)     compute and store the checksum; call it last,
//!                              right before writePage
//!     verify(&page, page_no)   .ok, .blank (all zeroes: never written) or
//!                              .corrupt
//!     readChecked(storage, page_no, &out)   readPage + verify; a page past
//!                              the end of the store counts as blank
//!
//! What a checksum does NOT do: it cannot repair anything, and it cannot tell
//! a stale-but-intact page (a lost write) from the current one. Detection
//! only; repair needs a second copy (doublewrite.zig here, the log in ch. 22).
const std = @import("std");
const crc = @import("crc32.zig");
const storage_mod = @import("storage.zig");
const Storage = storage_mod.Storage;
const Page = storage_mod.Page;
const page_size = storage_mod.page_size;

pub const checksum_size = 4;
/// Bytes of a page that the layers above may use.
pub const payload_size = page_size - checksum_size; // 4092

pub const Check = enum { ok, blank, corrupt };

/// CRC-32 over (page_no as 8 little-endian bytes) ++ payload.
pub fn checksum(page: *const Page, page_no: u64) u32 {
    var no: [8]u8 = undefined;
    std.mem.writeInt(u64, &no, page_no, .little);
    return crc.crc32Update(crc.crc32(&no), page[0..payload_size]);
}

/// The checksum stored in the page's last four bytes.
pub fn storedChecksum(page: *const Page) u32 {
    return std.mem.readInt(u32, page[payload_size..][0..checksum_size], .little);
}

/// Stamp the page for address `page_no`. Any later change to the payload
/// requires sealing again.
pub fn seal(page: *Page, page_no: u64) void {
    std.mem.writeInt(u32, page[payload_size..][0..checksum_size], checksum(page, page_no), .little);
}

pub fn verify(page: *const Page, page_no: u64) Check {
    if (storedChecksum(page) == checksum(page, page_no)) return .ok;
    // A page of zeroes was never written (a hole, or space past the end). It
    // is not damage, but it is not data either: the caller decides.
    if (std.mem.allEqual(u8, page, 0)) return .blank;
    return .corrupt;
}

/// Read a page and classify it. A page at or past `storage.size()` is
/// returned as zeroes and `.blank`, which is what recovery code wants.
pub fn readChecked(storage: Storage, page_no: u64, out: *Page) Storage.Error!Check {
    if (page_no >= storage.size()) {
        @memset(out, 0);
        return .blank;
    }
    try storage.readPage(page_no, out);
    return verify(out, page_no);
}

// ---------------------------------------------------------------------------
const testing = std.testing;

test "seal then verify" {
    var page: Page = @splat(0);
    try testing.expectEqual(Check.blank, verify(&page, 5));
    @memcpy(page[0..5], "hello");
    try testing.expectEqual(Check.corrupt, verify(&page, 5)); // not sealed yet
    seal(&page, 5);
    try testing.expectEqual(Check.ok, verify(&page, 5));
    try testing.expectEqual(storedChecksum(&page), checksum(&page, 5));
}

test "the page number is part of the checksum" {
    var page: Page = @splat(0);
    @memcpy(page[0..5], "hello");
    seal(&page, 5);
    try testing.expectEqual(Check.corrupt, verify(&page, 6)); // right bytes, wrong place
}

test "an all-zero payload sealed for a page is ok, not blank" {
    // The CRC of a zero payload is not zero, so a deliberately written empty
    // page is distinguishable from a hole.
    var page: Page = @splat(0);
    seal(&page, 0);
    try testing.expect(storedChecksum(&page) != 0);
    try testing.expectEqual(Check.ok, verify(&page, 0));
}

test "every single-bit flip is detected" {
    var page: Page = undefined;
    for (&page, 0..) |*b, i| b.* = @truncate(i *% 31);
    seal(&page, 9);
    // CRC-32 detects all single-bit errors; try one bit in every byte.
    for (0..page_size) |i| {
        page[i] ^= @as(u8, 1) << @intCast(i % 8);
        try testing.expectEqual(Check.corrupt, verify(&page, 9));
        page[i] ^= @as(u8, 1) << @intCast(i % 8);
    }
    try testing.expectEqual(Check.ok, verify(&page, 9));
}

test "every torn mix of two sealed versions is detected" {
    const sector_size = storage_mod.sector_size;
    var old: Page = @splat('A');
    var new: Page = @splat('B');
    seal(&old, 3);
    seal(&new, 3);
    var mask: u16 = 1;
    while (mask < 255) : (mask += 1) { // all 254 proper sector subsets
        var torn = old;
        for (0..storage_mod.sectors_per_page) |s| {
            if (mask & (@as(u16, 1) << @intCast(s)) != 0) {
                @memcpy(torn[s * sector_size ..][0..sector_size], new[s * sector_size ..][0..sector_size]);
            }
        }
        try testing.expectEqual(Check.corrupt, verify(&torn, 3));
    }
}
