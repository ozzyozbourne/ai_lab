/*
 * Chapter 21: text inlined for the visualization (no fetch under file://).
 *   CHAPTER_CODE.durability  condensed from zig/src and rust/src; the two
 *                            tabs have the same line numbers on purpose
 *   CH21_EXPECTED_OUTPUT     ../expected_output.txt, verbatim
 */
window.CHAPTER_CODE = {
  durability: {
    zig: `
// sim_disk.zig (condensed)
pub fn writePage(self: *SimDisk, page_no: u64, page: *const Page) !void {
    const copy = try self.arena.allocator().create(Page);
    copy.* = page.*;
    self.pending.appendAssumeCapacity(.{ .page_no = page_no, .data = copy });
}   // durable image untouched: the write is only pending

pub fn sync(self: *SimDisk) !void {
    for (self.pending.items) |w| self.apply(w, 0xFF); // all 8 sectors
    self.forgetPending();
}

pub fn crash(self: *SimDisk, mode: CrashMode) CrashReport {
    for (self.pending.items) |w| switch (self.fate(mode)) {
        .drop => {}, // never left the cache
        .keep => self.apply(w, 0xFF), // the OS had flushed it
        .tear => self.apply(w, self.randomMask()), // 1..254: some sectors
    };
    self.forgetPending();
}

// page.zig
pub fn verify(page: *const Page, page_no: u64) Check {
    if (storedChecksum(page) == checksum(page, page_no)) return .ok;
    return if (allZero(page)) .blank else .corrupt;
}

// doublewrite.zig
pub fn update(self: DoubleWrite, i: u64, page: *Page) !void {
    seal(page, self.slotPage(i));
    try self.storage.writePage(self.slotPage(i), page);
    try self.storage.sync(); // the second copy is durable first
    seal(page, self.homePage(i));
    try self.storage.writePage(self.homePage(i), page);
    try self.storage.sync();
}

// recover(), for each logical page i:
if (slot_check == .ok) {
    seal(slot, self.homePage(i));
    try self.storage.writePage(self.homePage(i), slot); // home := slot
} else {
    // slot torn or blank: home was never touched, keep it
}
try self.storage.sync();
`,
    rust: `
// sim_disk.rs (condensed)
fn write_page(&mut self, page_no: u64, page: &Page) -> Result<(), StorageError> {
    self.pending_bytes.extend_from_slice(page); // bump Vec<u8>
    self.pending_pages.push(page_no);
    Ok(())
}   // durable image untouched: the write is only pending

fn sync(&mut self) -> Result<(), StorageError> {
    for i in 0..self.pending_pages.len() { self.apply(i, 0xFF); } // all 8 sectors
    self.forget_pending();
}

pub fn crash(&mut self, mode: CrashMode) -> CrashReport {
    for i in 0..self.pending_pages.len() { match self.fate(mode) {
        CrashMode::Drop => {} // never left the cache
        CrashMode::Keep => self.apply(i, 0xFF), // the OS had flushed it
        CrashMode::Tear => self.apply(i, self.random_mask()), // 1..254: some sectors
    }}
    self.forget_pending();
}

// page.rs
pub fn verify(page: &Page, page_no: u64) -> Check {
    if stored_checksum(page) == checksum(page, page_no) { return Check::Ok; }
    if all_zero(page) { Check::Blank } else { Check::Corrupt }
}

// doublewrite.rs
pub fn update(&mut self, i: u64, page: &mut Page) -> Result<(), StorageError> {
    page::seal(page, self.slot_page(i));
    self.storage.write_page(self.slot_page(i), page)?;
    self.storage.sync()?; // the second copy is durable first
    page::seal(page, self.home_page(i));
    self.storage.write_page(self.home_page(i), page)?;
    self.storage.sync()
}

// recover(), for each logical page i:
if slot_check == Check::Ok {
    page::seal(slot, home_no);
    self.storage.write_page(home_no, slot)?; // home := slot
} else {
    // slot torn or blank: home was never touched, keep it
}
self.storage.sync()?;
`
  }
};

window.CH21_EXPECTED_OUTPUT = `Chapter 21: durability primitives
page = 4096 bytes = 8 sectors of 512; one letter per sector; SimDisk seed 2121

== 1. A write is not durable until sync ==
write page 0 = A: pending=1 durable_pages=0
read  page 0 -> AAAAAAAA ok
crash(drop): dropped=1 kept=0 torn=0
read  page 0 -> out of bounds (size=0)
write page 0 = A, sync: pending=0 durable_pages=1
crash(drop): dropped=0 kept=0 torn=0
read  page 0 -> AAAAAAAA ok

== 2. A torn write, caught by the checksum ==
write page 0 = B: pending=1 durable_pages=1
read  page 0 -> BBBBBBBB ok
crash(tear): dropped=0 kept=0 torn=1
read  page 0 -> ABBAAABB corrupt
checksum: stored=a6ca308e computed=11258b39

== 3. The checksum binds a page to its address ==
page sealed for address 0: checksum=70fea20f
verified at address 0: ok
verified at address 1: corrupt (expected checksum 8eec239b)

== 4. Double write: a second copy makes repair possible ==
layout: slot = page 0, home = page 1
update to A: writes=2 syncs=2
update to B, power off after 2 writes: PowerLoss
crash(tear): dropped=0 kept=0 torn=1
read  page 0 -> BBBBBBBB ok
read  page 1 -> ABBAAABB corrupt
recover: intact=0 rolled_forward=0 restored=1 blank=0
read  page 1 -> BBBBBBBB ok

== 5. Crash at every write: 4 crash modes x 100 seeds per line ==
in-place update (1 write, 1 sync):
  power off after 0 writes: old=400 new=0 corrupt=0
  power off after 1 writes: old=125 new=133 corrupt=142
double write (2 writes, 2 syncs), after recover:
  power off after 0 writes: old=400 new=0 corrupt=0
  power off after 1 writes: old=267 new=133 corrupt=0
  power off after 2 writes: old=0 new=400 corrupt=0
`;
