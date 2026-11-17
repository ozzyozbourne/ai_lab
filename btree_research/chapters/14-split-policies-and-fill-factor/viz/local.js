/*
 * Chapter 14: two small chapter-local views that the shared toolkit does not have.
 *   C14.CellStrip  one page drawn to scale: cells as boxes whose width is their byte
 *                  size, free space hatched, numbered gaps underneath
 *   C14.PageRow    a level of pages as small vertical gauges (height = fill)
 * Both are dumb views in the toolkit's style: call render(state) from a Stepper.
 * Colours come only from the toolkit's tokens (viz.css); the CSS is in index.html.
 */
(function (root) {
  'use strict';
  var el = BTViz.el;

  /**
   * new C14.CellStrip(target).render({
   *   title,                       text above the strip
   *   items: [{key, tid, size, state?}],   state: 'inserted' | 'split' | …
   *   capacity,                    bytes; the strip is scaled to max(capacity, sum of sizes)
   *   gaps: {s: state} | null      numbered markers under the gap before index s
   * })
   */
  function CellStrip(target) {
    this.root = el('div.c14-strip');
    (typeof target === 'string' ? document.querySelector(target) : target).appendChild(this.root);
  }
  CellStrip.prototype.render = function (st) {
    var rootEl = this.root, total = 0, i;
    rootEl.textContent = '';
    for (i = 0; i < st.items.length; i++) total += st.items[i].size;
    var scale = Math.max(total, st.capacity);
    if (st.title) rootEl.appendChild(el('div.c14-strip-title', { html: st.title }));
    var cells = el('div.c14-cells', { role: 'img', 'aria-label': (st.ariaLabel || 'Page') + ': ' + st.items.length + ' cells, ' + total + ' of ' + st.capacity + ' bytes' });
    var prevKey = null, alt = false;
    st.items.forEach(function (c) {
      if (prevKey !== null && c.key !== prevKey) alt = !alt;   // shade runs of equal keys alike
      prevKey = c.key;
      var share = c.size / scale;
      var box = el('div', { class: 'c14-cell' + (alt ? ' is-alt' : '') + (c.state ? ' s-' + c.state : ''), style: { flex: c.size + ' 0 0' }, title: '(' + c.key + ',' + c.tid + ') ' + c.size + ' bytes' });
      if (share >= 0.075) {
        box.appendChild(el('b', String(c.key)));
        box.appendChild(el('span.c14-tid', '#' + c.tid));
        box.appendChild(el('span.c14-size', c.size + 'B'));
      }
      cells.appendChild(box);
    });
    if (total < st.capacity) cells.appendChild(el('div.c14-free', { style: { flex: (st.capacity - total) + ' 0 0' }, title: (st.capacity - total) + ' bytes free' },
      (st.capacity - total) / scale >= 0.2 ? el('span', (st.capacity - total) + 'B free') : null));
    rootEl.appendChild(cells);
    if (total > st.capacity) {
      // The imaginary page is longer than a real one: mark where a real page ends.
      cells.appendChild(el('div.c14-cap', { style: { left: (st.capacity / scale * 100) + '%' } }));
      rootEl.appendChild(el('div.c14-cap-label', { style: { width: (st.capacity / scale * 100) + '%' } }, 'a real page ends at ' + st.capacity + 'B ⤴'));
    }
    if (st.gaps) {
      var row = el('div.c14-gaps'), left = 0;
      for (i = 1; i < st.items.length; i++) {
        left += st.items[i - 1].size;
        var state = st.gaps[i];
        row.appendChild(el('span', { class: 'c14-gap' + (state ? ' s-' + state : '') + (state === 'free' ? ' is-illegal' : ''), style: { left: (left / scale * 100) + '%' } }, String(i)));
      }
      rootEl.appendChild(row);
    }
    return this;
  };

  /**
   * new C14.PageRow(target).render({ used: [bytes per page in key order], capacity, marks: {index: 'split'} })
   * Pages under a quarter full are drawn in the 'merge' (underfull) colour.
   */
  function PageRow(target) {
    this.root = el('div.c14-pages');
    (typeof target === 'string' ? document.querySelector(target) : target).appendChild(this.root);
  }
  PageRow.prototype.render = function (st) {
    var rootEl = this.root, marks = st.marks || {};
    rootEl.textContent = '';
    rootEl.classList.toggle('is-dense', st.used.length > 80);
    rootEl.setAttribute('role', 'img');
    rootEl.setAttribute('aria-label', st.used.length + ' pages');
    st.used.forEach(function (used, i) {
      var pct = Math.round(used * 100 / st.capacity);
      var cls = 'c14-pg' + (marks[i] ? ' s-' + marks[i] : pct < 25 ? ' s-merge' : ' s-active');
      rootEl.appendChild(el('span', { class: cls, title: 'page ' + (i + 1) + ' of ' + st.used.length + ': ' + used + ' bytes, ' + pct + '%' },
        el('i', { style: { height: Math.max(4, pct) + '%' } })));
    });
    return this;
  };

  root.C14 = { CellStrip: CellStrip, PageRow: PageRow };
})(window);
