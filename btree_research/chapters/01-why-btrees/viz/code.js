/* Chapter 01 code-panel snippets (abridged from zig/src and rust/src; no fetch under file://). */
window.CHAPTER_CODE = {
  put: {
    zig: `
pub fn put(self: *SortedArrayMap, allocator: Allocator, key: u64, value: u64) !?u64 {
    const i = self.lowerBound(key, null);
    if (i < self.len and self.entries[i].key == key) {
        const old = self.entries[i].value;
        self.entries[i].value = value;
        return old;
    }
    if (self.len == self.entries.len) try self.grow(allocator);

    // Everything in [i, len) moves one slot to the right.
    const tail = self.len - i;
    @memmove(self.entries[i + 1 .. self.len + 1], self.entries[i..self.len]);
    self.entries[i] = .{ .key = key, .value = value };
    self.len += 1;
    self.moves += tail;
    return null;
}`,
    rust: `
pub fn put(&mut self, key: u64, value: u64) -> Result<Option<u64>, OutOfSpace> {
    let i = self.lower_bound(key, None);
    if let Some(entry) = self.entries.get_mut(i)
        && entry.key == key
    {
        return Ok(Some(std::mem::replace(&mut entry.value, value)));
    }
    if self.limit == Some(self.entries.len()) {
        return Err(OutOfSpace);
    }

    // Everything in [i, len) moves one slot to the right:
    // Vec::insert does the shift.
    let tail = self.entries.len() - i;
    self.entries.insert(i, Entry { key, value });
    self.moves += tail as u64;
    Ok(None)
}`
  },
  minHeight: {
    zig: `
/// Fewest levels that can hold n keys when every node is full:
/// the smallest h with m^h - 1 >= n.
pub fn minHeight(n: u64, m: u64) u32 {
    var h: u32 = 0;
    var capacity_plus_one: u128 = 1; // m^h
    while (capacity_plus_one - 1 < n) {
        capacity_plus_one *= m;
        h += 1;
    }
    return h;
}`,
    rust: `
/// Fewest levels that can hold n keys when every node is full:
/// the smallest h with m^h - 1 >= n.
pub fn min_height(n: u64, m: u64) -> u32 {
    let mut h = 0;
    let mut capacity_plus_one: u128 = 1; // m^h
    while capacity_plus_one - 1 < u128::from(n) {
        capacity_plus_one *= u128::from(m);
        h += 1;
    }
    h
}`
  }
};
