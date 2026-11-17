/* Snippets for the code panel (inlined: no fetch under file://). */
window.CHAPTER_CODE = {
  separator: {
    zig: [
      'pub fn separator(truncate: bool, last_left: LeafCell, first_right: LeafCell) Sep {',
      '    if (truncate) {',
      '        const n = commonPrefixLen(last_left.key, first_right.key);',
      '        if (n < first_right.key.len) return .{ .key = first_right.key[0 .. n + 1], .tid = null };',
      '    }',
      '    // Equal keys (or truncation off): the last-left tuple, in full.',
      '    return .{ .key = last_left.key, .tid = last_left.tids[last_left.tids.len - 1] };',
      '}'
    ].join('\n'),
    rust: [
      'pub fn separator<\'a>(truncate: bool, last_left: &\'a LeafCell, first_right: &\'a LeafCell)',
      '    -> (&\'a [u8], Option<Tid>) {',
      '    if truncate {',
      '        let n = common_prefix_len(&last_left.key, &first_right.key);',
      '        if n < first_right.key.len() {',
      '            return (&first_right.key[..=n], None);',
      '        }',
      '    }',
      '    // Equal keys (or truncation off): the last-left tuple, in full.',
      '    (&last_left.key, last_left.tids.last().copied())',
      '}'
    ].join('\n')
  },
  compare: {
    zig: [
      'pub fn compareTuple(a_key: []const u8, a_tid: ?Tid, b_key: []const u8, b_tid: ?Tid) Order {',
      '    const by_key = std.mem.order(u8, a_key, b_key); // a prefix sorts first',
      '    if (by_key != .eq) return by_key;',
      '    const a = a_tid orelse return if (b_tid == null) .eq else .lt; // null = minus infinity',
      '    const b = b_tid orelse return .gt;',
      '    return std.math.order(a, b);',
      '}',
      '',
      '// Child to follow: the number of separators strictly below the tuple.',
      'pub fn childIndex(page: *const Page, key: []const u8, tid: Tid) usize {',
      '    var lo: usize = 0;',
      '    var hi: usize = page.seps.items.len;',
      '    while (lo < hi) {',
      '        const mid = lo + (hi - lo) / 2;',
      '        const s = page.seps.items[mid];',
      '        if (compareTuple(s.key, s.tid, key, tid) == .lt) lo = mid + 1 else hi = mid;',
      '    }',
      '    return lo;',
      '}'
    ].join('\n'),
    rust: [
      'pub fn compare_tuple(a_key: &[u8], a_tid: Option<Tid>, b_key: &[u8], b_tid: Option<Tid>) -> Ordering {',
      '    // Slices: a prefix sorts first. Options: None < Some(_), i.e. minus infinity.',
      '    a_key.cmp(b_key).then(a_tid.cmp(&b_tid))',
      '}',
      '',
      '// Child to follow: the number of separators strictly below the tuple.',
      'pub fn child_index(page: &Page, key: &[u8], tid: Tid) -> usize {',
      '    page.seps.partition_point(|s| {',
      '        compare_tuple(&s.key, s.tid, key, Some(tid)) == Ordering::Less',
      '    })',
      '}'
    ].join('\n')
  }
};
