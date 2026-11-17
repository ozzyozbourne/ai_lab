/*
 * Chapter 29 — source snippets for the code panels (inlined: no fetch under
 * file://) and the programs' expected output for the self-tests.
 * Snippets are abridged from zig/src and rust/src; line numbers match between
 * the two languages so one highlight works in both tabs.
 */
window.CHAPTER_CODE = {
  checkZone: {
    zig: [
      'pub fn checkZone(zone: Zone, op: Op, c: u64) Prune {',
      '    const inside = zone.min <= c and c <= zone.max;',
      '    const single = zone.min == c and zone.max == c; // every row equals c',
      '    return switch (op) {',
      '        .eq => if (single) .always_true else if (inside) .maybe else .always_false,',
      '        .ne => if (!inside) .always_true else if (single) .always_false else .maybe,',
      '        .ge => if (zone.min >= c) .always_true else if (zone.max >= c) .maybe else .always_false,',
      '        .gt => if (zone.min > c) .always_true else if (zone.max > c) .maybe else .always_false,',
      '        .le => if (zone.max <= c) .always_true else if (zone.min <= c) .maybe else .always_false,',
      '        .lt => if (zone.max < c) .always_true else if (zone.min < c) .maybe else .always_false,',
      '    };',
      '}',
      '// between lo and hi = andPrune(checkZone(.ge, lo), checkZone(.le, hi))'
    ].join('\n'),
    rust: [
      'pub fn check_zone(zone: Zone, op: Op, c: u64) -> Prune {',
      '    let inside = zone.min <= c && c <= zone.max;',
      '    let single = zone.min == c && zone.max == c; // every row equals c',
      '    match op { // verdict(true for all rows?, true for some row?)',
      '        Op::Eq => verdict(single, inside),',
      '        Op::Ne => verdict(!inside, !single),',
      '        Op::Ge => verdict(zone.min >= c, zone.max >= c),',
      '        Op::Gt => verdict(zone.min > c, zone.max > c),',
      '        Op::Le => verdict(zone.max <= c, zone.min <= c),',
      '        Op::Lt => verdict(zone.max < c, zone.min < c),',
      '    }',
      '}',
      '// between lo and hi = and_prune(check_zone(Ge, lo), check_zone(Le, hi))'
    ].join('\n')
  },
  search: {
    zig: [
      'pub fn search(self: *const Ivf, scratch: Allocator, query: []const i32,',
      '              nprobe: usize, out: []Hit) !SearchStats {',
      '    const order = try scratch.alloc(Hit, self.nlist);',
      '    self.rankLists(query, order); // distance to EVERY centroid, sorted',
      '    var stats: SearchStats = .{};',
      '    for (order[0..@min(nprobe, self.nlist)]) |list| {',
      '        stats.lists_probed += 1;',
      '        for (self.list_offsets[list.id]..self.list_offsets[list.id + 1]) |pos| {',
      '            const d = dist2(self.vecs[pos * self.dim ..][0..self.dim], query);',
      '            stats.vectors_scanned += 1;',
      '            stats.hits = topkOffer(out, stats.hits, .{ .dist = d, .id = self.ids[pos] });',
      '        }',
      '    }',
      '    return stats;',
      '}'
    ].join('\n'),
    rust: [
      'pub fn search(&self, scratch: &mut Vec<Hit>, query: &[i32],',
      '              nprobe: usize, out: &mut [Hit]) -> SearchStats {',
      '    self.rank_lists(query, scratch); // distance to EVERY centroid, sorted',
      '    let mut stats = SearchStats::default();',
      '    for list in &scratch[..nprobe.min(self.nlist)] {',
      '        stats.lists_probed += 1;',
      '        let c = list.id as usize;',
      '        for pos in self.list_offsets[c] as usize..self.list_offsets[c + 1] as usize {',
      '            let d = dist2(&self.vecs[pos * self.dim..(pos + 1) * self.dim], query);',
      '            stats.vectors_scanned += 1;',
      '            stats.hits = topk_offer(out, stats.hits, Hit { dist: d, id: self.ids[pos] });',
      '        }',
      '    }',
      '    stats',
      '}'
    ].join('\n')
  },
  descent: {
    c: [
      '// faiss/faiss/impl/HNSW.cpp:1775-1783 (FAISS, not this chapter\'s code)',
      '//  greedy search on upper levels',
      'storage_idx_t nearest = hnsw.entry_point;',
      'float d_nearest = qdis(nearest);',
      '',
      'for (int level = hnsw.max_level; level >= 1; level--) {',
      '    HNSWStats local_stats = greedy_update_nearest_impl<C>(',
      '            hnsw, qdis, level, nearest, d_nearest);',
      '    stats.combine(local_stats);',
      '}',
      '// then: best-first search on level 0 with max(efSearch, k) candidates'
    ].join('\n'),
    pseudo: [
      'cur = entry_point                      // one node on the top layer',
      'for layer = top .. 1:',
      '    loop:',
      '        best = the neighbour of cur on this layer closest to the query',
      '        if dist(best) >= dist(cur): break   // local minimum on this layer',
      '        cur = best',
      '    // drop: cur is also a node of the layer below',
      'layer 0: keep the ef best nodes seen (W) and a queue of nodes to expand (C)',
      '    expand the closest unexpanded node; add its neighbours to W and C',
      '    stop when the closest unexpanded node is farther than everything in W',
      'answer = closest node in W'
    ].join('\n')
  }
};
