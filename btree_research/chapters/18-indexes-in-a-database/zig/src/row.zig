//! The one table of this chapter and the keys of its indexes.
//!
//!     CREATE TABLE orders (
//!         id       INTEGER PRIMARY KEY,   -- u32
//!         customer INTEGER,               -- u16
//!         day      INTEGER,               -- u16
//!         amount   INTEGER,               -- u16
//!         code     INTEGER UNIQUE         -- u16
//!     );
//!     CREATE INDEX by_customer_day ON orders (customer, day);
//!
//! The B+tree copied from chapter 07 maps one u64 to one u64. That is enough
//! for a whole table engine if every key is a COMPOSITE packed into 64 bits:
//!
//!     by_customer_day key:  customer:16 | day:16 | locator:32
//!     by_code key:          0:16        | code:16 | locator:32
//!     heap primary key:     id:32                 | locator:32
//!
//! Putting the first column in the most significant bits makes the integer
//! order equal to the column-by-column (lexicographic) order, which is all a
//! composite index is. Chapter 11 does the same for byte strings.
//!
//! The LOCATOR is whatever leads from an index entry back to its row. It is
//! the last part of every index key for two reasons: it makes entries with
//! equal columns distinct (chapter 07's tie-breaker), and it is the payload
//! the scan wants. What the locator IS depends on the layout (see table.zig):
//! the row id in a clustered table, the TID in a heap table.
const std = @import("std");

pub const Row = struct {
    id: u32,
    customer: u16,
    day: u16,
    amount: u16,
    code: u16,
};

/// Row id (clustered layout) or TID (heap layout).
pub const Locator = u32;

/// A clustered table stores the row IN the primary tree: key = id, value =
/// every other column. Four u16 columns happen to fill the u64 value slot; a
/// real engine stores a variable-length record there (chapter 11).
pub fn packRow(row: Row) u64 {
    return @as(u64, row.customer) << 48 | @as(u64, row.day) << 32 |
        @as(u64, row.amount) << 16 | row.code;
}

pub fn unpackRow(id: u32, value: u64) Row {
    return .{
        .id = id,
        .customer = @truncate(value >> 48),
        .day = @truncate(value >> 32),
        .amount = @truncate(value >> 16),
        .code = @truncate(value),
    };
}

/// Key of `by_customer_day`.
pub fn customerDayKey(customer: u16, day: u16, locator: Locator) u64 {
    return @as(u64, customer) << 48 | @as(u64, day) << 32 | locator;
}

/// Key of a one-column index (`by_code`, and the heap layout's primary key).
pub fn columnKey(value: u32, locator: Locator) u64 {
    return @as(u64, value) << 32 | locator;
}

pub fn keyCustomer(key: u64) u16 {
    return @truncate(key >> 48);
}

pub fn keyDay(key: u64) u16 {
    return @truncate(key >> 32);
}

/// The column of a one-column index key.
pub fn keyColumn(key: u64) u32 {
    return @truncate(key >> 32);
}

pub fn keyLocator(key: u64) Locator {
    return @truncate(key);
}

/// A closed key interval [lo, hi]. Closed, not half-open, so that the range
/// of the largest prefix (customer 65535) needs no key beyond the u64 range.
pub const KeyRange = struct {
    lo: u64,
    hi: u64,

    pub const all: KeyRange = .{ .lo = 0, .hi = std.math.maxInt(u64) };
};

const any_locator: u64 = std.math.maxInt(u32);

/// A prefix scan is a range scan: fix the leading column(s) and let every
/// later column, the locator included, run from its minimum to its maximum.
/// WHERE customer = c
pub fn customerRange(customer: u16) KeyRange {
    return customerDaysRange(customer, 0, std.math.maxInt(u16));
}

/// WHERE customer = c AND day BETWEEN day_lo AND day_hi
/// Equality on the first column, a range on the second: still ONE contiguous
/// run of the index. (A range on the first column and equality on the second
/// would not be.)
pub fn customerDaysRange(customer: u16, day_lo: u16, day_hi: u16) KeyRange {
    return .{
        .lo = customerDayKey(customer, day_lo, 0),
        .hi = customerDayKey(customer, day_hi, any_locator),
    };
}

/// WHERE column = v on a one-column index: every locator under that value.
pub fn columnRange(value: u32) KeyRange {
    return .{ .lo = columnKey(value, 0), .hi = columnKey(value, any_locator) };
}

test "packed order equals column-by-column order" {
    // (customer, day, locator) triples in ascending lexicographic order.
    const triples = [_][3]u32{
        .{ 0, 0, 0 },  .{ 0, 0, 1 },     .{ 0, 1, 0 },                   .{ 0, 65535, 9 },
        .{ 1, 0, 0 },  .{ 7, 12, 5 },    .{ 7, 12, 10 },                 .{ 7, 13, 0 },
        .{ 8, 0, 99 }, .{ 65535, 0, 0 }, .{ 65535, 65535, 0xFFFF_FFFF },
    };
    var previous: ?u64 = null;
    for (triples) |t| {
        const key = customerDayKey(@intCast(t[0]), @intCast(t[1]), t[2]);
        if (previous) |p| try std.testing.expect(p < key);
        previous = key;
        try std.testing.expectEqual(t[0], keyCustomer(key));
        try std.testing.expectEqual(t[1], keyDay(key));
        try std.testing.expectEqual(t[2], keyLocator(key));
    }
}

test "a prefix range contains exactly the keys with that prefix" {
    const r = customerRange(7);
    try std.testing.expect(customerDayKey(6, 65535, 0xFFFF_FFFF) < r.lo);
    try std.testing.expect(customerDayKey(7, 0, 0) == r.lo);
    try std.testing.expect(customerDayKey(7, 65535, 0xFFFF_FFFF) == r.hi);
    try std.testing.expect(customerDayKey(8, 0, 0) > r.hi);
    // The largest prefix does not overflow.
    try std.testing.expectEqual(std.math.maxInt(u64), customerRange(65535).hi);

    const d = customerDaysRange(7, 10, 20);
    try std.testing.expect(customerDayKey(7, 9, 0xFFFF_FFFF) < d.lo);
    try std.testing.expect(customerDayKey(7, 21, 0) > d.hi);
    try std.testing.expect(d.lo <= customerDayKey(7, 20, 123) and customerDayKey(7, 20, 123) <= d.hi);
}

test "a row survives packing" {
    const row: Row = .{ .id = 17, .customer = 9, .day = 15, .amount = 510, .code = 170 };
    try std.testing.expectEqual(row, unpackRow(17, packRow(row)));
    const max: Row = .{ .id = 0xFFFF_FFFF, .customer = 65535, .day = 65535, .amount = 65535, .code = 65535 };
    try std.testing.expectEqual(max, unpackRow(max.id, packRow(max)));
}
