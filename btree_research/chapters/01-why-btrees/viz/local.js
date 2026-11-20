/*
 * Chapter 01: two small chapter-local views that the shared toolkit does not have.
 *   C1.PageStrip  a sorted array drawn as a row of fixed-size pages (the toolkit's
 *                 ArrayView is one unbroken row and cannot show page boundaries)
 *   C1.BstView    a binary search tree drawn compactly, one column per key, in a box
 *                 that follows the search path in both directions (the toolkit's
 *                 TreeView can draw binary trees too; see the note at BstView)
 * Both are dumb views in the toolkit's style: call render(state) from a Stepper.
 * Colours come only from the toolkit's tokens (viz.css); the CSS is in index.html.
 * Requires viz.js (BTViz.el) and model.js (the C1 namespace).
 */
(function (root) {
  'use strict';
  var el = BTViz.el, C1 = root.C1;

  /**
   * new C1.PageStrip(target, {ariaLabel}).render({
   *   keys: [k | null, …],       null draws an empty slot
   *   perPage: n,
   *   cells: {index: state},     'compare' | 'found' | 'inserted' | 'dirty' | 'deleted' | 'dim'
   *   pages: {pageIndex: state}, 'active' (read in this step) | 'pointer' (read earlier) | 'dirty'
   *   range: [lo, hi)            cells outside are dimmed (optional)
   * })
   */
  function PageStrip(target, opts) {
    this.opts = opts || {};
    this.root = el('div.c1-strip', { role: 'img', 'aria-label': this.opts.ariaLabel || 'Sorted array on pages' });
    (typeof target === 'string' ? document.querySelector(target) : target).appendChild(this.root);
  }
  PageStrip.prototype.render = function (st) {
    var host = this.root, cells = st.cells || {}, pages = st.pages || {}, range = st.range;
    host.textContent = '';
    var count = Math.ceil(st.keys.length / st.perPage);
    for (var p = 0; p < count; p++) {
      var box = el('div', { class: 'c1-page' + (pages[p] ? ' s-' + pages[p] : '') }, el('div.c1-page-label', 'page ' + p));
      var row = el('div.c1-cells');
      for (var i = p * st.perPage; i < (p + 1) * st.perPage; i++) {
        var key = i < st.keys.length ? st.keys[i] : undefined;
        var state = cells[i] || (range && key !== undefined && key !== null && (i < range[0] || i >= range[1]) ? 'dim' : '');
        var empty = key === undefined || key === null;
        row.appendChild(el('span', { class: 'c1-cell' + (empty ? ' is-empty' : '') + (state ? ' s-' + state : '') }, empty ? '' : String(key)));
      }
      box.appendChild(row);
      host.appendChild(box);
    }
    return this;
  };

  /**
   * new C1.BstView(target, {ariaLabel, maxHeight}).render(rootNode, {nodes: {id: state}, edges: {childId: state}, focus: id})
   * rootNode: {id, key, left, right}. x = in-order rank, y = depth, so a left child is
   * always drawn to the left of its parent and a right child to the right.
   * The box scrolls inside itself: it follows `focus`, and without a focus it shows the root.
   *
   * Why not BTViz.TreeView with `binary: true`? Measured on this chapter's trees it is no
   * narrower (998 px against 1056 for the 40 default keys, 1324 against 1056 for the
   * ascending chain), it is taller per level, and it only scrolls sideways to a highlighted
   * node, while the 40-level chain also has to be followed downwards.
   */
  function BstView(target, opts) {
    this.opts = opts || {};
    this.svg = el('svg', { class: 'c1-bst-svg', role: 'img', 'aria-label': this.opts.ariaLabel || 'Binary search tree' });
    this.root = el('div.c1-bst', { tabindex: 0 }, this.svg);
    if (this.opts.maxHeight) this.root.style.maxHeight = this.opts.maxHeight + 'px';
    (typeof target === 'string' ? document.querySelector(target) : target).appendChild(this.root);
  }
  var NODE_H = 22, PITCH_Y = 30, PAD = 8, PITCH_X_MIN = 23, PITCH_X_MAX = 26;
  BstView.prototype.render = function (rootNode, hl) {
    hl = hl || {};
    var nodes = hl.nodes || {}, edges = hl.edges || {}, svg = this.svg, placed = [], rank = 0, maxDepth = 0, box = this.root;
    // In-order walk without recursion (a degenerate tree is as deep as it is large).
    var stack = [], cur = rootNode, depthOf = new Map();
    if (rootNode) depthOf.set(rootNode, 0);
    while (cur || stack.length) {
      while (cur) { stack.push(cur); if (cur.left) depthOf.set(cur.left, depthOf.get(cur) + 1); cur = cur.left; }
      cur = stack.pop();
      var d = depthOf.get(cur);
      placed.push({ node: cur, rank: rank, y: PAD + d * PITCH_Y });
      if (d > maxDepth) maxDepth = d;
      rank++;
      if (cur.right) depthOf.set(cur.right, d + 1);
      cur = cur.right;
    }
    // One column per key. The columns shrink a little (a three-digit key still fits) when that
    // lets the whole tree fit the box, so that a wide screen needs no sideways scrolling.
    var PITCH_X = Math.max(PITCH_X_MIN, Math.min(PITCH_X_MAX, Math.floor((box.clientWidth - 2 * PAD) / Math.max(1, rank))));
    var NODE_W = PITCH_X - 1;
    var pos = new Map();
    placed.forEach(function (p) { p.x = PAD + p.rank * PITCH_X; pos.set(p.node, p); });
    var W = PAD * 2 + Math.max(1, rank) * PITCH_X - (PITCH_X - NODE_W), H = PAD * 2 + maxDepth * PITCH_Y + NODE_H;
    svg.textContent = '';
    svg.setAttribute('viewBox', '0 0 ' + W + ' ' + H);
    svg.setAttribute('width', W);
    svg.setAttribute('height', H);
    var gE = el('g'), gN = el('g');
    svg.appendChild(gE); svg.appendChild(gN);
    placed.forEach(function (p) {
      [p.node.left, p.node.right].forEach(function (child) {
        if (!child) return;
        var c = pos.get(child);
        gE.appendChild(el('line', {
          class: 'c1-bedge' + (edges[child.id] ? ' s-' + edges[child.id] : ''),
          x1: p.x + NODE_W / 2, y1: p.y + NODE_H, x2: c.x + NODE_W / 2, y2: c.y
        }));
      });
      var g = el('g', { class: 'c1-bnode' + (nodes[p.node.id] ? ' s-' + nodes[p.node.id] : ''), transform: 'translate(' + p.x + ',' + p.y + ')' },
        el('rect', { width: NODE_W, height: NODE_H, rx: 6 }),
        el('text', { x: NODE_W / 2, y: NODE_H / 2 + 4.5, 'text-anchor': 'middle' }, String(p.node.key)));
      gN.appendChild(g);
    });
    // Keep the focused node visible by scrolling the view's own box (never the page).
    var f = hl.focus && placed.filter(function (p) { return p.node.id === hl.focus; })[0];
    if (f) {
      if (f.x < box.scrollLeft + 8 || f.x + NODE_W > box.scrollLeft + box.clientWidth - 8) box.scrollLeft = Math.max(0, f.x - box.clientWidth / 2);
      if (f.y < box.scrollTop + 8 || f.y + NODE_H > box.scrollTop + box.clientHeight - 8) box.scrollTop = Math.max(0, f.y - box.clientHeight / 2);
    } else {
      // Nothing is being searched: show the top of the tree with the root in the middle (on a
      // narrow screen the root of a 40-key tree is far to the right of the left edge).
      var top = rootNode && pos.get(rootNode);
      box.scrollLeft = top ? Math.max(0, top.x + NODE_W / 2 - box.clientWidth / 2) : 0;
      box.scrollTop = 0;
    }
    return this;
  };

  C1.PageStrip = PageStrip;
  C1.BstView = BstView;
})(window);
