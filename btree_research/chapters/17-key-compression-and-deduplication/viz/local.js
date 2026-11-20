/* Chapter 17 local views (the shared toolkit has no view for byte-sized pages
 * with string keys and posting lists, and TreeView nodes get far too wide for
 * them). Both views are "dumb": call render(model, highlight) from onStep.
 * They use only the toolkit's colour tokens and state classes (s-…).
 */
(function () {
  'use strict';
  var el = BTViz.el, M = Ch17Model;

  function cls(base, state) { return base + (state ? ' s-' + state : ''); }

  /* ---- TreeCards: one card per page, one row per tree level ------------ */

  function TreeCards(mount) {
    this.root = el('div.c17-tree', { role: 'img', 'aria-label': 'The tree, one card per page, root at the top' });
    mount.appendChild(this.root);
  }

  // state: {root, pageSize, pages: [{id, leaf, low, high, right, cells, seps, children, used}]}
  // highlight: {pages: {id: state}, cells: {'id:i': state}, seps: {'id:i': state},
  //             links: {'id:i': state}, fences: {'id:low' | 'id:high': state}}
  TreeCards.prototype.render = function (state, hl) {
    hl = hl || {};
    var H = { pages: hl.pages || {}, cells: hl.cells || {}, seps: hl.seps || {}, links: hl.links || {}, fences: hl.fences || {} };
    var levels = [], frontier = [state.root];
    while (frontier.length) {
      levels.push(frontier);
      var next = [];
      frontier.forEach(function (id) { next = next.concat(state.pages[id].children); });
      frontier = next;
    }
    var rootEl = this.root;
    rootEl.textContent = '';
    levels.forEach(function (ids, depth) {
      var row = el('div.c17-level');
      ids.forEach(function (id) { row.appendChild(card(state.pages[id], state.pageSize, H)); });
      rootEl.appendChild(el('div.c17-level-label', depth === levels.length - 1 ? 'leaves' : depth === 0 ? 'root' : 'internal'));
      rootEl.appendChild(row);
    });
  };

  function card(p, pageSize, H) {
    var over = p.used > pageSize;
    var pct = Math.min(100, Math.round(p.used * 100 / pageSize));
    var body = el('div.c17-body');
    if (p.leaf) {
      if (!p.cells.length) body.appendChild(el('span.c17-empty', 'empty'));
      p.cells.forEach(function (c, i) {
        var chip = el('span', { class: cls('bt-chip c17-cell' + (c.tids.length > 1 ? ' c17-posting' : ''), H.cells[p.id + ':' + i]) },
          el('span.c17-key', M.keyText(c.key)), el('span.c17-tids', M.tidsText(c.tids)));
        if (c.tids.length > 1) chip.title = 'posting list: one key, ' + c.tids.length + ' TIDs';
        body.appendChild(chip);
      });
    } else {
      p.children.forEach(function (child, i) {
        body.appendChild(el('span', { class: cls('bt-chip c17-link', H.links[p.id + ':' + i] || 'pointer') }, '→ page ' + child));
        if (i < p.seps.length) body.appendChild(el('span', { class: cls('bt-chip c17-sep', H.seps[p.id + ':' + i]) }, M.sepText(p.seps[i], '')));
      });
    }
    return el('div', { class: cls('c17-page' + (over ? ' is-over' : ''), H.pages[p.id]), 'data-page': p.id },
      el('div.c17-head',
        el('b', 'page ' + p.id), el('span.c17-kind', p.leaf ? 'leaf' : 'internal'),
        el('span.c17-used', p.used + ' / ' + pageSize + ' B' + (over ? ' — too big' : ''))),
      el('div.c17-meter', { 'aria-hidden': 'true' }, el('span', { style: { width: pct + '%' } })),
      el('div.c17-fences',
        el('span', { class: cls('c17-fence', H.fences[p.id + ':low']) }, 'low ' + M.sepText(p.low, '−∞')),
        el('span.c17-rule', '< tuples ≤'),
        el('span', { class: cls('c17-fence', H.fences[p.id + ':high']) }, 'high ' + M.sepText(p.high, '+∞'))),
      body,
      p.leaf && p.right !== null ? el('div.c17-right', 'next leaf → page ' + p.right) : null);
  }

  /* ---- SepView: two keys compared byte by byte -------------------------- */

  // A space in a byte box would look like an empty box: draw it as an open box.
  function byteText(ch) { return ch === ' ' ? '\u2423' : ch; }

  function SepView(mount) {
    this.root = el('div.c17-bytes', { role: 'img', 'aria-label': 'Byte-by-byte comparison of the two keys around the cut' });
    mount.appendChild(this.root);
  }

  // model: {left: {key, tid}, right: {key, tid}, upto, decisive, sep}
  //   upto     = number of byte positions examined so far
  //   decisive = index of the byte that ends the comparison, or null
  //   sep      = null while comparing, then {key, tid}
  SepView.prototype.render = function (m) {
    var n = Math.max(m.left.key.length, m.right.key.length);
    function row(label, t, isRight) {
      var cells = [el('span.c17-rowlabel', label)];
      for (var i = 0; i < n; i++) {
        var ch = t.key[i], state = '';
        if (ch === undefined) { cells.push(el('span.c17-byte.is-none', '·')); continue; }
        if (i < m.upto) state = (m.decisive !== null && i === m.decisive) ? 'compare' : 'found';
        else if (m.sep) state = isRight && m.sep.tid === null ? 'deleted' : 'dim';
        cells.push(el('span', { class: cls('c17-byte' + (state === 'deleted' ? ' is-cut' : ''), state) }, byteText(ch)));
      }
      var tidState = m.sep ? (m.sep.tid !== null && !isRight ? 'inserted' : (isRight && m.sep.tid === null ? 'deleted' : 'dim')) : '';
      cells.push(el('span', { class: cls('c17-byte c17-tid' + (tidState === 'deleted' ? ' is-cut' : ''), tidState) }, '@' + t.tid));
      return el('div.c17-row', cells);
    }
    var sepRow = [el('span.c17-rowlabel', 'separator')];
    if (m.sep) {
      m.sep.key.split('').forEach(function (ch) { sepRow.push(el('span.c17-byte.s-inserted', byteText(ch))); });
      for (var i = m.sep.key.length; i < n; i++) sepRow.push(el('span.c17-byte.is-none', '·'));
      sepRow.push(el('span', { class: 'c17-byte c17-tid ' + (m.sep.tid !== null ? 's-inserted' : 'is-none') }, m.sep.tid !== null ? '@' + m.sep.tid : '−∞'));
    } else {
      sepRow.push(el('span.c17-pending', '…'));
    }
    this.root.textContent = '';
    this.root.append(row('last on left', m.left, false), row('first on right', m.right, true), el('div.c17-row.c17-seprow', sepRow));
  };

  window.Ch17View = { TreeCards: TreeCards, SepView: SepView };
})();
