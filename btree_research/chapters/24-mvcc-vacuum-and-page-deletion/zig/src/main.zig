const std = @import("std");
const lib = @import("ch24_mvcc_vacuum_and_page_deletion");
pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const w = &file_writer.interface;
    var db: lib.Db = .init(4);
    defer db.deinit(init.gpa);
    for ([_]u64{ 10, 20, 30, 40, 50, 60, 70, 80, 90 }) |k| _ = try db.put(init.gpa, k, k);
    const s = try db.store.openSnapshot();
    _ = try db.put(init.gpa, 20, 21);
    _ = db.delete(40);
    _ = db.delete(50);
    try lib.dump.dump(&db, w);
    try db.validate();
    _ = try db.get(s, 20);
    db.store.closeSnapshot(s);
    const r = db.vacuum(.{});
    try w.print("{any}\n", .{r});
    try lib.dump.dump(&db, w);
    try db.validate();
    try w.flush();
}
