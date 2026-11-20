/* Chapter 20: adapter between the B-link model (model.js) and BTViz.TreeView.
 *
 * Why this file exists. TreeView draws a tree: every node below the root hangs
 * on an edge from its parent. In a B-link tree the right half of a split has,
 * for a while, NO parent entry: it is reachable only through its left sibling's
 * right link. To draw such a node on its own level, next to its sibling, it is
 * passed to TreeView as an extra child of the sibling's parent, and then
 *   1. its edge is hidden (highlight state `nolink`, see the <style> block);
 *   2. the edges of the children after it are moved back to their own gaps,
 *      because TreeView picks the gap by position in the child list.
 * Step 2 touches TreeView internals (view.edges, view.layout, view._draw). If
 * they are ever renamed the helper does nothing and the picture is merely a
 * little less exact, it does not break.
 */
(function (global) {
  'use strict';
  function nid(id) { return 'n' + id; }

  /** Model state -> {model, hidden} for TreeView. `badges` maps node id -> latch badges. */
  function toView(t, badges) {
    var hidden = {};
    function build(id, orphan) {
      var n = t.nodes[id];
      var node = {
        id: nid(id), keys: n.keys.slice(), leaf: n.level === 0, children: [],
        meta: { label: '#' + id }
      };
      if (n.right !== null) node.right = nid(n.right);
      if (n.high !== null) node.highKey = n.high;
      if (n.inc) node.meta.note = 'split incomplete';
      if (orphan) { node.meta.note = 'no downlink'; node._orphan = true; }
      if (badges[id]) node.meta.lock = badges[id];
      (n.kids || []).forEach(function (k) {
        node.children.push(build(k, false));
        if (t.nodes[k].inc) {
          var o = t.nodes[k].right;
          node.children.push(build(o, true));
          hidden[nid(id) + '>' + nid(o)] = 'nolink';
        }
      });
      return node;
    }
    var roots = [build(t.root, false)];
    // A root whose split is incomplete: its sibling stands next to it, with no parent at all.
    if (t.nodes[t.root].inc) roots.push(build(t.nodes[t.root].right, true));
    return { model: roots.length === 1 ? roots[0] : roots, hidden: hidden };
  }

  /** Move the edges that follow a downlink-less node back to their own gap. */
  function fixEdges(view, model) {
    if (!view || !view.edges || !view.layout || typeof view._draw !== 'function') return;
    var touched = false;
    (function walk(p) {
      if (Array.isArray(p)) { p.forEach(walk); return; }
      var real = 0;
      (p.children || []).forEach(function (c, pos) {
        walk(c);
        if (c._orphan) return;
        if (pos !== real) {
          var it = view.edges.get(p.id + '>' + c.id), info = view.layout.nodes.get(p.id);
          if (it && it.to && info && info.anchors) {
            it.to.sx = info.x + info.anchors[Math.min(real, info.anchors.length - 1)];
            touched = true;
          }
        }
        real++;
      });
    })(model);
    if (touched && !(view._dur > 0)) view._draw(1);
  }

  /** Draw state S with highlight `hl` (TreeView terms, see model.js). */
  function render(view, S, hl) {
    var badges = {};
    function badge(id, b) { (badges[id] = badges[id] || []).push(b); }
    if (S.writer && S.writer.held !== null) badge(S.writer.held, 'W:X');
    if (S.reader && !S.reader.done && global.BLink.blocked(S, 'R')) badge(S.reader.next, 'R:S?');
    var v = toView(S.t, badges);
    var h = { nodes: hl.nodes || {}, keys: hl.keys || {}, links: hl.links || {}, cursor: hl.cursor, edges: {} };
    var k;
    for (k in (hl.edges || {})) h.edges[k] = hl.edges[k];
    for (k in v.hidden) h.edges[k] = v.hidden[k];
    view.render(v.model, h);
    fixEdges(view, v.model);
  }

  global.Ch20 = { toView: toView, render: render };
})(window);
