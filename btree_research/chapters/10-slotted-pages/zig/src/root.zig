//! Library root of chapter 10 (`@import("ch10_slotted_pages")` from main.zig).
const std = @import("std");

pub const slotted_page = @import("slotted_page.zig");
pub const demo = @import("demo.zig");
pub const workload = @import("workload.zig");
pub const ops = @import("ops.zig");

pub const SlottedPage = slotted_page.SlottedPage;

test {
    // A test block only runs if its file is referenced from here.
    _ = slotted_page;
    _ = demo;
    _ = workload;
    _ = ops;
    _ = @import("model_test.zig");
}
