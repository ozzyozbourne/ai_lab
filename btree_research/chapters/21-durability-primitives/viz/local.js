/*
 * Chapter 21 local view: "pending writes | durable disk", one row per page,
 * eight cells per row (one per 512-byte sector). The shared toolkit has no
 * component for a two-sided disk picture, so this small helper builds one
 * from toolkit pieces (BTViz.el, .bt-mem-slot cells, .bt-chip badges and the
 * semantic state classes s-dirty / s-inserted / s-pointer / s-found / s-deleted).
 *
 *   var view = new Ch21DiskView(target, { labels: {0: 'slot', 1: 'home'} });
 *   view.render(state, hl)
 *     state  Ch21.snapshot(disk)
 *     hl     { read: {side: 'pending' | 'durable', page: n},   outline the row that answered a read
 *              touched: {pageNo: true},                        durable rows changed by this step
 *              note: 'html' }                                  status line under the picture
 */
(function (root) {
  'use strict';
  var el = BTViz.el;

  var css = [
    '.c21-disk { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; }',
    '@media (max-width: 720px) { .c21-disk { grid-template-columns: minmax(0, 1fr); } }',
    '.c21-col { border: 1px solid var(--bt-border); border-radius: var(--bt-radius); padding: 8px 10px 10px; min-width: 0; min-height: 132px; }',
    '.c21-col h3 { margin: 0 0 2px; font-size: .86rem; font-weight: 650; }',
    '.c21-col p { margin: 0 0 8px; font-size: .76rem; color: var(--bt-muted); }',
    '.c21-row { display: flex; flex-wrap: wrap; align-items: center; gap: 4px 8px; padding: 4px; border-radius: 6px; }',
    '.c21-row + .c21-row { margin-top: 2px; }',
    '.c21-row.is-read { box-shadow: inset 0 0 0 2px var(--bt-accent); background: var(--bt-accent-bg); }',
    '.c21-row.is-touched { background: var(--bt-surface-2, var(--bt-key-bg)); }',
    '.c21-label { flex: 0 0 5.6em; font: .76rem var(--bt-mono); color: var(--bt-text); line-height: 1.25; }',
    '.c21-label small { display: block; color: var(--bt-muted); font-size: .7rem; }',
    '.c21-cells { display: grid; grid-template-columns: repeat(8, 24px); gap: 2px; }',
    '.c21-cells .bt-mem-slot { height: 26px; font-size: .74rem; }',
    '.c21-empty { font-size: .8rem; color: var(--bt-muted); padding: 6px 4px; }',
    '.c21-status { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; margin-top: 10px; font-size: .8rem; color: var(--bt-muted); }'
  ].join('\n');
  var styled = false;
  function ensureStyle() {
    if (styled) return;
    styled = true;
    document.head.appendChild(el('style', { text: css }));
  }

  function newestLetter(map) {
    var best = '';
    for (var i = 0; i < map.length; i++) if (map[i] >= 'A' && map[i] <= 'Z' && map[i] > best) best = map[i];
    return best;
  }

  function Ch21DiskView(target, opts) {
    ensureStyle();
    this.opts = opts || {};
    this.pending = el('div');
    this.durable = el('div');
    this.status = el('div.c21-status', { 'aria-live': 'off' });
    var host = typeof target === 'string' ? document.querySelector(target) : target;
    host.appendChild(el('div.c21-disk',
      el('section.c21-col', { 'aria-label': 'Pending writes' },
        el('h3', 'Pending writes (OS cache)'), el('p', 'Visible to reads. A crash may drop, keep or tear each one.'), this.pending),
      el('section.c21-col', { 'aria-label': 'Durable pages' },
        el('h3', 'Durable (on disk)'), el('p', 'What is left after a power cut.'), this.durable)));
    host.appendChild(this.status);
  }

  Ch21DiskView.prototype.label = function (pageNo, prefix) {
    var role = (this.opts.labels || {})[pageNo];
    return el('span.c21-label', (prefix || '') + 'page ' + pageNo, role ? el('small', role) : null);
  };

  Ch21DiskView.prototype.render = function (state, hl) {
    hl = hl || {};
    var self = this;
    this.pending.textContent = '';
    this.durable.textContent = '';

    if (!state.pending.length) this.pending.appendChild(el('div.c21-empty', 'No pending writes.'));
    // The newest pending write per page is the one a read returns.
    var newest = {};
    state.pending.forEach(function (w, i) { newest[w.page] = i; });
    state.pending.forEach(function (w, i) {
      var cells = el('div.c21-cells', { role: 'img', 'aria-label': 'pending write to page ' + w.page + ': sectors ' + w.map });
      w.map.split('').forEach(function (ch) { cells.appendChild(el('div.bt-mem-slot.s-dirty', ch)); });
      var isRead = hl.read && hl.read.side === 'pending' && hl.read.page === w.page && newest[w.page] === i;
      self.pending.appendChild(el('div', { class: 'c21-row' + (isRead ? ' is-read' : '') },
        self.label(w.page, 'write ' + (i + 1) + ' → '), cells, el('span.bt-chip.s-dirty', 'not synced')));
    });

    if (!state.durable.length) this.durable.appendChild(el('div.c21-empty', 'The disk is empty (size 0).'));
    state.durable.forEach(function (p) {
      var cells = el('div.c21-cells', { role: 'img', 'aria-label': 'durable page ' + p.page + ': sectors ' + p.map + ', checksum ' + p.check });
      var top = p.check === 'corrupt' ? newestLetter(p.map) : '';
      p.map.split('').forEach(function (ch, s) {
        var cls = ch === '.' ? 'bt-mem-slot is-free s-free' : 'bt-mem-slot ' + (top && ch === top ? 's-inserted' : 's-pointer');
        cells.appendChild(el('div', { class: cls, title: 'sector ' + s + (ch === '.' ? ': zeroes' : ': version ' + ch) }, ch === '.' ? '' : ch));
      });
      var chip = p.check === 'ok' ? el('span.bt-chip.s-found', '✓ checksum ok')
        : p.check === 'blank' ? el('span.bt-chip.s-free', 'blank')
        : el('span.bt-chip.s-deleted', { title: 'stored ' + p.stored + ', computed ' + p.computed }, '✗ corrupt');
      var isRead = hl.read && hl.read.side === 'durable' && hl.read.page === p.page;
      var touched = hl.touched && hl.touched[p.page];
      self.durable.appendChild(el('div', { class: 'c21-row' + (isRead ? ' is-read' : '') + (touched ? ' is-touched' : '') },
        self.label(p.page), cells, chip));
    });

    this.status.textContent = '';
    this.status.appendChild(el('span.bt-chip', 'writes ' + state.stats.writes));
    this.status.appendChild(el('span.bt-chip', 'syncs ' + state.stats.syncs));
    this.status.appendChild(el('span.bt-chip', 'crashes ' + state.stats.crashes));
    if (state.off) this.status.appendChild(el('span.bt-chip.s-deleted', 'power is off'));
    if (hl.note) this.status.appendChild(el('span', { html: hl.note }));
    return this;
  };

  root.Ch21DiskView = Ch21DiskView;
})(window);
