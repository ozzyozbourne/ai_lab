/* Chapter 13 — chapter-local view helpers (the toolkit has no "file as a row of
 * pages with links between them" component).
 *
 *   Ch13View.FileStrip   one card per page of the file, with arrows for the two
 *                        kinds of page-to-page links this chapter adds:
 *                        overflow chains and the free list
 *   Ch13View.treeModel   a model state -> BTViz.TreeView model + highlight
 *   Ch13View.mapSlots    a model state -> BTViz.MemoryMap slots
 *
 * Classic script: defines window.Ch13View. Colours come from the toolkit's
 * tokens through the s-… state classes; nothing is hard-coded.
 */
(function () {
  'use strict';
  var el = BTViz.el;
  var SVG = 'http://www.w3.org/2000/svg';

  /* role -> toolkit state (colour) and the word printed on the page */
  var ROLE = {
    meta:     { state: '',        word: 'metapage' },
    interior: { state: '',        word: 'interior' },
    leaf:     { state: '',        word: 'leaf' },
    overflow: { state: 'split',   word: 'overflow' },
    trunk:    { state: 'compare', word: 'trunk' },
    free:     { state: 'free',    word: 'free' }
  };
  var BADGE = { inserted: 'written', deleted: 'freed', active: 'read', split: 'split' };

  function cellLabel(c) {
    var n = Ch13.overflowPages(c.total);
    return c.key + (n ? ' +' + n + 'p' : '');
  }
  function leafUsed(p) {
    var used = 0;
    p.cells.forEach(function (c) { used += Ch13.cellCost(c.total); });
    return used;
  }

  /* ---- FileStrip ---------------------------------------------------------- */

  function FileStrip(target, opts) {
    this.opts = opts || {};
    this.strip = el('div.ch13-strip');
    this.svg = document.createElementNS(SVG, 'svg');
    this.svg.setAttribute('class', 'ch13-arrows');
    this.svg.setAttribute('aria-hidden', 'true');
    this.root = el('div.ch13-file', { role: 'img', 'aria-label': this.opts.ariaLabel || 'The pages of the file' }, this.strip);
    this.root.appendChild(this.svg);
    (typeof target === 'string' ? document.querySelector(target) : target).appendChild(this.root);
    this.links = [];
    var self = this;
    window.addEventListener('resize', function () { self.drawArrows(); });
  }

  function line(text, cls) { return el('div.ch13-line' + (cls ? '.' + cls : ''), text); }

  FileStrip.prototype.render = function (state, highlight) {
    var hot = (highlight && highlight.pages) || {}, self = this, links = [];
    this.strip.textContent = '';
    state.pages.forEach(function (p, id) {
      var role = ROLE[p.role], hl = hot[id];
      var card = el('div', { class: 'ch13-page' + (role.state ? ' s-' + role.state : '') + (p.role === 'free' ? ' is-hatch' : '') + (hl ? ' is-hot hot-' + hl : ''), dataset: { page: id } },
        el('div.ch13-page-id', 'page ' + id), el('div.ch13-page-role', role.word));
      var body = el('div.ch13-page-body');
      if (p.role === 'meta') {
        body.append(line('root → 1'), line('free list → ' + (state.freeHead === null ? '–' : state.freeHead)), line(state.freeCount + ' free'));
        if (state.freeHead !== null) links.push({ from: id, to: state.freeHead, kind: 'free' });
      } else if (p.role === 'interior') {
        var parts = [];
        p.children.forEach(function (c, i) { parts.push('(' + c + ')'); if (i < p.keys.length) parts.push(p.keys[i]); });
        body.append(line(parts.join(' ')));
      } else if (p.role === 'leaf') {
        body.append(line(p.cells.length ? p.cells.map(cellLabel).join(', ') : '(no cells)'));
        body.append(line('next → ' + (p.next === null ? '–' : p.next), 'is-muted'));
        var used = leafUsed(p);
        body.append(el('div.ch13-meter', { title: used + ' of ' + Ch13.CAPACITY + ' bytes in use' }, el('span', { style: { width: Math.round(100 * used / Ch13.CAPACITY) + '%' } })));
        p.cells.forEach(function (c) { if (c.first !== null) links.push({ from: id, to: c.first, kind: 'chain' }); });
      } else if (p.role === 'overflow') {
        body.append(line('value of ' + p.owner), line('part ' + p.part + ' of ' + p.of), line(p.bytes + ' B', 'is-muted'));
        body.append(el('div.ch13-meter', { title: p.bytes + ' of ' + Ch13.OVERFLOW_PAYLOAD + ' payload bytes' }, el('span', { style: { width: Math.round(100 * p.bytes / Ch13.OVERFLOW_PAYLOAD) + '%' } })));
        if (p.next !== null) links.push({ from: id, to: p.next, kind: 'chain' });
      } else if (p.role === 'trunk') {
        body.append(line(p.ids.length ? 'lists ' + p.ids.join(', ') : 'lists nothing'), line('next trunk → ' + (p.next === null ? '–' : p.next), 'is-muted'));
        p.ids.forEach(function (f) { links.push({ from: id, to: f, kind: 'free' }); });
        if (p.next !== null) links.push({ from: id, to: p.next, kind: 'free' });
      } else {
        body.append(line('reusable'), line(p.was ? 'old bytes: ' + p.was : 'old bytes', 'is-muted'));
      }
      card.appendChild(body);
      if (hl && BADGE[hl]) card.appendChild(el('div.ch13-badge', BADGE[hl]));
      self.strip.appendChild(card);
    });
    this.links = links;
    this.drawArrows();
    return this;
  };

  /* Arrows are drawn after layout, from the cards' real positions, so they are
   * right whether the cards sit in one row or wrap into several. */
  FileStrip.prototype.drawArrows = function () {
    var svg = this.svg, root = this.root, strip = this.strip;
    while (svg.firstChild) svg.removeChild(svg.firstChild);
    var w = root.clientWidth, h = root.clientHeight;
    if (!w || !h) return;
    svg.setAttribute('viewBox', '0 0 ' + w + ' ' + h);
    svg.setAttribute('width', w); svg.setAttribute('height', h);
    var defs = document.createElementNS(SVG, 'defs');
    ['chain', 'free'].forEach(function (kind) {
      var m = document.createElementNS(SVG, 'marker');
      m.setAttribute('id', 'ch13-head-' + kind + '-' + (root.dataset.uid || (root.dataset.uid = String(Math.random()).slice(2, 8))));
      m.setAttribute('viewBox', '0 0 8 8'); m.setAttribute('refX', '7'); m.setAttribute('refY', '4');
      m.setAttribute('markerWidth', '7'); m.setAttribute('markerHeight', '7'); m.setAttribute('orient', 'auto');
      var tip = document.createElementNS(SVG, 'path');
      tip.setAttribute('d', 'M0,0 L8,4 L0,8 z'); tip.setAttribute('class', 'ch13-head is-' + kind);
      m.appendChild(tip); defs.appendChild(m);
    });
    svg.appendChild(defs);
    var base = root.getBoundingClientRect();
    function box(id) {
      var c = strip.querySelector('[data-page="' + id + '"]');
      if (!c) return null;
      var r = c.getBoundingClientRect();
      return { x: r.left - base.left, y: r.top - base.top, w: r.width, h: r.height };
    }
    this.links.forEach(function (l, n) {
      var a = box(l.from), b = box(l.to);
      if (!a || !b) return;
      var shift = l.kind === 'chain' ? 9 : 24;            // the two kinds leave and arrive at different x
      var x1 = a.x + a.w / 2 + shift, x2 = b.x + b.w / 2 - shift, d;
      var lane = 8 + 6 * (n % 6);                          // staggers lines that share a gap between rows
      if (Math.abs(a.y - b.y) < 8) {
        // Same row: an arc under the cards, deeper for longer hops.
        var y = a.y + a.h, depth = 12 + 7 * Math.min(4, Math.abs(l.to - l.from));
        d = 'M' + x1 + ',' + y + ' C' + x1 + ',' + (y + depth) + ' ' + x2 + ',' + (y + depth) + ' ' + x2 + ',' + (y + 2);
      } else {
        // Different rows (a narrow screen wraps the cards): straight segments
        // that stay in the gaps between rows, and in the left margin when a
        // row lies in between, so that no line runs across a card.
        var down = b.y > a.y;
        var y1 = down ? a.y + a.h : a.y, y2 = down ? b.y - 2 : b.y + b.h + 2;
        var g1 = down ? y1 + lane : y1 - lane, g2 = down ? y2 - (50 - lane) + 6 : y2 + (50 - lane) - 6;
        var adjacent = Math.abs(y2 - y1) < 70;
        d = adjacent
          ? 'M' + x1 + ',' + y1 + ' L' + x1 + ',' + g1 + ' L' + x2 + ',' + g1 + ' L' + x2 + ',' + y2
          : 'M' + x1 + ',' + y1 + ' L' + x1 + ',' + g1 + ' L' + (4 + (n % 3) * 3) + ',' + g1 + ' L' + (4 + (n % 3) * 3) + ',' + g2 + ' L' + x2 + ',' + g2 + ' L' + x2 + ',' + y2;
      }
      var path = document.createElementNS(SVG, 'path');
      path.setAttribute('d', d);
      path.setAttribute('class', 'ch13-arrow is-' + l.kind);
      path.setAttribute('marker-end', 'url(#ch13-head-' + l.kind + '-' + root.dataset.uid + ')');
      svg.appendChild(path);
    });
  };

  /* ---- adapters for the toolkit's views ------------------------------------ */

  /** {model, highlight} for BTViz.TreeView: the tree pages only, one node per page. */
  function treeModel(state, highlight) {
    var hot = (highlight && highlight.pages) || {}, hl = { nodes: {}, keys: {} };
    function node(id) {
      var p = state.pages[id], n;
      if (p.role === 'leaf') {
        n = { id: 'p' + id, leaf: true, keys: p.cells.map(cellLabel), meta: { label: 'page ' + id, note: leafUsed(p) + ' / ' + Ch13.CAPACITY + ' B' } };
        if (p.next !== null) n.next = 'p' + p.next;
      } else {
        // An interior page with one child and no key exists for a moment before the root collapses.
        n = { id: 'p' + id, leaf: false, keys: p.keys.length ? p.keys.slice() : ['no key'], children: p.children.map(node), meta: { label: 'page ' + id } };
      }
      if (hot[id]) hl.nodes['p' + id] = hot[id];
      return n;
    }
    var model = node(state.root);
    var c = highlight && highlight.cell;
    if (c) {
      var page = state.pages[c.page];
      if (page && page.role === 'leaf') page.cells.forEach(function (cell) { if (cell.key === c.key) hl.keys['p' + c.page + ':' + cellLabel(cell)] = c.state; });
    }
    return { model: model, highlight: hl };
  }

  /** Slots for BTViz.MemoryMap: one per page, coloured by role, labelled with the page id. */
  function mapSlots(state) {
    return state.pages.map(function (p, id) {
      var what = p.role === 'overflow' ? 'overflow page ' + p.part + ' of ' + p.of + ' of key ' + p.owner
        : p.role === 'trunk' ? 'free-list trunk listing ' + (p.ids.length ? p.ids.join(', ') : 'nothing')
        : p.role === 'leaf' ? 'leaf with ' + p.cells.length + ' cells'
        : p.role === 'interior' ? 'interior page (the root)'
        : p.role === 'meta' ? 'metapage' : 'free page';
      // 'node' is not a state class, so tree pages get the resting look.
      return { state: p.role === 'free' ? 'free' : (ROLE[p.role].state || 'node'), label: id, title: 'page ' + id + ': ' + what };
    });
  }

  /** One line of text for the free list: head → trunk 2 [3 6] → … */
  function freeListText(state) {
    if (state.freeHead === null) return 'free list: empty';
    var parts = [];
    for (var t = state.freeHead; t !== null; t = state.pages[t].next) parts.push('trunk ' + t + ' [' + state.pages[t].ids.join(' ') + ']');
    return 'free list (' + state.freeCount + ' pages): ' + parts.join(' → ');
  }

  window.Ch13View = { FileStrip: FileStrip, treeModel: treeModel, mapSlots: mapSlots, freeListText: freeListText, cellLabel: cellLabel };
})();
