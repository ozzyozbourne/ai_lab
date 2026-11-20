/* Chapter 18 — code panel snippets (inlined: no fetch under file://).
 * Excerpts of zig/src/table.zig and rust/src/table.rs. */
window.CHAPTER_CODE = {
  fetch: {
    zig: [
      "/// From a locator found in an index entry to the row.",
      "fn fetch(self: *Table, locator: Locator) ?Row {",
      "    self.counters.row_fetches += 1;",
      "    switch (self.layout) {",
      "        // The locator is a KEY of another tree: search that tree.",
      "        .clustered => {",
      "            chargeDescent(&self.counters, &self.primary);",
      "            const value = self.primary.get(locator) orelse return null;",
      "            return row_.unpackRow(locator, value);",
      "        },",
      "        // The locator is an ADDRESS: go there.",
      "        .heap => {",
      "            self.counters.heap_reads += 1;",
      "            return self.heap.fetch(locator);",
      "        },",
      "    }",
      "}"
    ].join('\n'),
    rust: [
      "/// From a locator found in an index entry to the row.",
      "fn fetch(&self, locator: Locator) -> Option<Row> {",
      "    count(&self.counters, |c| c.row_fetches += 1);",
      "    match self.layout {",
      "        // The locator is a KEY of another tree: search that tree.",
      "        Layout::Clustered => {",
      "            charge_descent(&self.counters, &self.primary);",
      "            let value = self.primary.get(u64::from(locator))?;",
      "            Some(row::unpack_row(locator, value))",
      "        }",
      "        // The locator is an ADDRESS: go there.",
      "        Layout::Heap => {",
      "            count(&self.counters, |c| c.heap_reads += 1);",
      "            self.heap.fetch(locator)",
      "        }",
      "    }",
      "}"
    ].join('\n')
  },
  scan: {
    zig: [
      "/// SELECT * ... : one descent of the index, one row fetch PER ENTRY.",
      "pub fn fetchScan(self: *Table, arena: Allocator, range: KeyRange) ![]Row {",
      "    var out: std.ArrayList(Row) = .empty;",
      "    var cursor = Cursor.seek(&self.by_customer_day, range, &self.counters);",
      "    while (cursor.next()) |key| try out.append(arena, self.fetch(row_.keyLocator(key)).?);",
      "    return out.items;",
      "}",
      "",
      "/// SELECT customer, day ... : the key holds every requested column.",
      "pub fn indexOnlyScan(self: *Table, arena: Allocator, range: KeyRange) ![]u64 {",
      "    var out: std.ArrayList(u64) = .empty;",
      "    var cursor = Cursor.seek(&self.by_customer_day, range, &self.counters);",
      "    while (cursor.next()) |key| try out.append(arena, key);",
      "    return out.items;",
      "}"
    ].join('\n'),
    rust: [
      "/// SELECT * ... : one descent of the index, one row fetch PER ENTRY.",
      "pub fn fetch_scan(&self, out: &mut Vec<Row>, range: KeyRange) {",
      "    out.clear();",
      "    for key in Cursor::seek(&self.by_customer_day, range, &self.counters) {",
      "        let row = self.fetch(row::key_locator(key));",
      "        out.push(row.expect(\"index entry without a row\"));",
      "    }",
      "}",
      "",
      "/// SELECT customer, day ... : the key holds every requested column.",
      "pub fn index_only_scan(&self, out: &mut Vec<u64>, range: KeyRange) {",
      "    out.clear();",
      "    out.extend(Cursor::seek(&self.by_customer_day, range, &self.counters));",
      "}"
    ].join('\n')
  }
};
