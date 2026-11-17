/* Chapter 29, page 2: IVF probing. Model: model.js (mirrors ivf.zig / ivf.rs). */
(function () {
  'use strict';
  var el = BTViz.el, C = window.Ch29;

  BTViz.page({
    title: 'IVF probing', chapter: 29,
    prev: { href: 'index.html', title: 'Zone-map pruning' },
    next: { href: 'hnsw.html', title: 'Greedy graph descent' }
  });
  C.subnav('#subnav', 'ivf.html');

  var S = C.ivfScenario(), IX = S.index, K = C.IVF.k;
  // Draw only the part of the 0..999 square that holds data (plus a margin).
  var BOX = [Infinity, Infinity, -Infinity, -Infinity];
  S.points.forEach(function (pt) {
    BOX[0] = Math.min(BOX[0], pt[0]); BOX[1] = Math.min(BOX[1], pt[1]); BOX[2] = Math.max(BOX[2], pt[0]); BOX[3] = Math.max(BOX[3], pt[1]);
  });
  BOX = [Math.max(0, BOX[0] - 45), Math.max(0, BOX[1] - 45), Math.min(999, BOX[2] + 45), Math.min(999, BOX[3] + 45)];
  var A0 = { id: 'a0', x: BOX[0], y: BOX[1] }, A1 = { id: 'a1', x: BOX[2], y: BOX[3] };
  var anchors = [A0, A1].map(function (a) { return { id: a.id, x: a.x, y: a.y, r: 0.5, state: 'dim', label: null }; });

  function cells(cents, states) {
    return cents.map(function (c, i) { return { points: C.voronoiCell(cents, i, BOX), state: states ? states[i] : null }; });
  }
  function centroidNodes(cents, states) {
    return cents.map(function (c, i) { return { id: 'c' + i, x: c[0], y: c[1], shape: 'diamond', r: 6, label: String(i), state: states ? states[i] : null }; });
  }
  function small(view) { return view.root.clientWidth < 520; }
  function fitHeight(gv) { gv.opts.height = Math.round(Math.min(560, Math.max(300, gv.root.clientWidth * 0.95))); }

  /* =============================================================== probe */
  var fig = BTViz.figure('#fig-probe', {
    title: 'Search with nprobe lists', side: true,
    legend: [
      { token: 'node-active', label: 'query (cross), probed list' },
      { token: 'key-compare', label: 'vectors being scanned' },
      { token: 'key-found', label: 'true neighbour, found' },
      { token: 'key-deleted', label: 'true neighbour, missed' },
      { token: 'key-inserted', label: 'returned, but not a true neighbour' }
    ]
  });
  var probeSel = el('select.bt-select#nprobe', { 'aria-label': 'nprobe' });
  for (var p = 1; p <= IX.nlist; p++) probeSel.appendChild(el('option', { value: p }, 'nprobe = ' + p));
  var querySel = el('select.bt-select#query', { 'aria-label': 'Scenario query' });
  S.queries.forEach(function (q, i) { querySel.appendChild(el('option', { value: i, selected: i === 12 }, 'query ' + i + ' (' + q[0] + ', ' + q[1] + ')' + (i === 12 ? ' — first miss' : ''))); });
  querySel.appendChild(el('option', { value: 'custom' }, 'custom (click the plane)'));
  var randBtn = el('button.bt-btn#random', { type: 'button' }, 'Random query');
  fig.toolbar.append(probeSel, querySel, randBtn);

  var gv = new BTViz.GraphView(fig.stage, { height: 440, r: 3.2, ariaLabel: 'Points, cells and the query' });
  var ranking = el('div');
  fig.side.appendChild(el('div.bt-panel', el('div.bt-panel-title', 'Centroid ranking for this query'), el('div.bt-panel-body', ranking)));
  var code = BTViz.codePanel(fig.side, 'search', { title: 'Ivf.search' });

  var query = S.queries[12].slice(), rng = BTViz.rng(29), search, truth;
  var stepper = new BTViz.Stepper({
    mount: fig.controls, caption: fig.caption, root: fig.root, interval: 1400,
    onStep: function (step) { drawProbe(step.state); code.highlight(step.lines || []); }
  });

  function drawProbe(st) {
    // st: {ranked: bool, probed: n lists scanned, scanning: list id or -1, final: bool}
    var listState = {}, i;
    for (i = 0; i < st.probed; i++) listState[search.order[i].id] = 'active';
    if (st.scanning >= 0) listState[st.scanning] = 'compare';
    var top = st.probed ? search.probes[st.probed - 1].top : [];
    var inTop = {}, inTruth = {};
    top.forEach(function (h) { inTop[h.id] = true; });
    truth.forEach(function (h) { inTruth[h.id] = true; });
    var nodes = S.points.map(function (pt, id) {
      var l = IX.assign[id], state = null;
      if (st.final) state = inTruth[id] ? (inTop[id] ? 'found' : 'deleted') : inTop[id] ? 'inserted' : (listState[l] ? null : 'dim');
      else if (l === st.scanning) state = 'compare';
      else if (inTop[id]) state = 'inserted';
      else if (st.ranked && !listState[l]) state = 'dim';
      return { id: 'p' + id, x: pt[0], y: pt[1], state: state, label: null, r: state && state !== 'dim' && state !== 'compare' ? (small(gv) ? 3.4 : 4.6) : (small(gv) ? 2 : 3.2) };
    });
    var cs = {};
    for (i = 0; i < IX.nlist; i++) cs[i] = listState[i] || null;
    fitHeight(gv);
    gv.render({
      regions: cells(IX.centroids, cs),
      nodes: anchors.concat(nodes, centroidNodes(IX.centroids, cs), [{ id: 'q', x: query[0], y: query[1], shape: 'cross', r: 7, label: 'q', state: 'active' }])
    });
    var tb = el('tbody');
    search.order.forEach(function (o, rank) {
      var state = !st.ranked ? null : o.id === st.scanning ? 'compare' : rank < st.probed ? 'active' : null;
      tb.appendChild(el('tr', { class: state ? 's-' + state : null }, el('td.num', st.ranked ? String(rank + 1) : '·'), el('td', 'list ' + o.id),
        el('td.num', st.ranked ? String(o.dist) : '·'), el('td.num', String(IX.lists[o.id].length))));
    });
    ranking.textContent = '';
    ranking.appendChild(el('div.bt-table-wrap', el('table.bt-table', el('thead', el('tr', el('th.num', 'rank'), el('th', 'list'), el('th.num', 'dist²'), el('th.num', 'vectors'))), tb)));
  }

  function rebuild(play) {
    var nprobe = +probeSel.value;
    search = C.ivfSearch(IX, query, nprobe, K);
    truth = C.flatSearch(S.points, query, K);
    var steps = [], qt = '(' + query[0] + ', ' + query[1] + ')', scanned = 0;
    steps.push({
      caption: '<b>Query ' + qt + '</b>, k = ' + K + ', nprobe = ' + nprobe + '. The index holds ' + S.points.length + ' vectors in ' + IX.nlist +
        ' lists. A B-tree would now binary-search its root. This root has no order to search.',
      state: { ranked: false, probed: 0, scanning: -1 }
    });
    steps.push({
      caption: '<b>Route:</b> compute the distance from the query to all ' + IX.nlist + ' centroids and sort. Nearest: list ' + search.order[0].id +
        ' (dist² ' + search.order[0].dist + '), then list ' + search.order[1].id + ' (dist² ' + search.order[1].dist + '). The ' + nprobe +
        ' nearest list' + (nprobe > 1 ? 's' : '') + ' will be read; the rest are never touched.',
      state: { ranked: true, probed: 0, scanning: -1 }, lines: { zig: [3, 4], rust: [3] }
    });
    search.probes.forEach(function (pr, i) {
      scanned += pr.scanned;
      steps.push({
        caption: '<span class="bt-chip s-compare">probe ' + (i + 1) + ' of ' + search.probes.length + '</span> Scan list ' + pr.list + ': ' + pr.scanned +
          ' distance computations, one sequential pass over the list (like reading a leaf page). Best so far: id ' + pr.top[0].id + ' at dist² ' + pr.top[0].dist +
          '. Scanned ' + scanned + ' of ' + S.points.length + ' vectors.',
        state: { ranked: true, probed: i + 1, scanning: pr.list }, lines: { zig: [[8, 12]], rust: [[7, 11]] }
      });
    });
    var found = C.overlap(search.top, truth), miss = truth.filter(function (t) { return !search.top.some(function (h) { return h.id === t.id; }); });
    var verdict;
    if (!miss.length) verdict = 'All ' + K + ' true neighbours were found: recall ' + K + '/' + K + ', after scanning ' + search.scanned + ' of ' + S.points.length + ' vectors.';
    else {
      var m = miss[0], home = IX.assign[m.id], rank = 0;
      while (search.order[rank].id !== home) rank++;
      verdict = 'Recall ' + found + '/' + K + '. Missed id ' + m.id + ' at dist² ' + m.dist + ': it is stored in list ' + home + ', whose centroid ranks ' + (rank + 1) +
        ' for this query, across a cell boundary. nprobe = ' + (rank + 1) + ' would reach it.';
    }
    steps.push({
      caption: '<b>Compare with brute force</b> (all ' + S.points.length + ' vectors). ' + verdict,
      state: { ranked: true, probed: search.probes.length, scanning: -1, final: true }, lines: { zig: [14], rust: [13] }
    });
    stepper.setSteps(steps, { index: play ? 0 : steps.length - 1, instant: true, play: !!play });
  }
  function setQuery(x, y, fromList) {
    query = [x, y];
    if (!fromList) querySel.value = 'custom';
    rebuild(false);
  }
  probeSel.addEventListener('change', function () { rebuild(false); });
  querySel.addEventListener('change', function () {
    if (querySel.value !== 'custom') { var q = S.queries[+querySel.value]; setQuery(q[0], q[1], true); }
  });
  randBtn.addEventListener('click', function () { setQuery(rng.int(BOX[0] + 20, BOX[2] - 20), rng.int(BOX[1] + 20, BOX[3] - 20)); });
  C.planeClick(gv, A0, A1, function (x, y) { setQuery(x, y); });
  rebuild(false);
  stepper.go(0, { instant: true });

  /* =============================================================== train */
  var fig2 = BTViz.figure('#fig-train', {
    title: 'k-means, one step at a time',
    legend: [{ token: 'key-compare', label: 'point that changed list in this step' }, { token: 'node-active', label: 'centroid (diamond)' }]
  });
  var gv2 = new BTViz.GraphView(fig2.stage, { height: 400, r: 3.2, ariaLabel: 'k-means training' });
  var H = IX.history, tsteps = [];
  H.forEach(function (h, t) {
    var last = t === H.length - 1;
    tsteps.push({
      caption: t === 0 ? '<b>Start:</b> 8 data points, chosen by a seeded shuffle, serve as centroids. Assign every point to its nearest centroid: the cells appear.' :
        '<b>Update ' + t + ':</b> each centroid moved to the (rounded) mean of its points, then every point was re-assigned. ' + h.changed + ' point' + (h.changed === 1 ? '' : 's') +
        ' changed list.' + (last ? ' Nothing changes any more: training stops after ' + IX.iterations + ' updates. Every point is now in the list of its nearest centroid, the invariant <code>validate</code> checks.' : ''),
      state: { t: t }
    });
  });
  new BTViz.Stepper({
    mount: fig2.controls, caption: fig2.caption, root: fig2.root, steps: tsteps, interval: 1300,
    onStep: function (step) {
      var h = H[step.state.t], prev = step.state.t > 0 ? H[step.state.t - 1].assign : null;
      var cs = {};
      h.centroids.forEach(function (c, i) { cs[i] = 'active'; });
      fitHeight(gv2);
      gv2.render({
        regions: cells(h.centroids, null),
        nodes: anchors.concat(S.points.map(function (pt, id) {
          var moved = prev && prev[id] !== h.assign[id];
          return { id: 'p' + id, x: pt[0], y: pt[1], label: null, state: moved ? 'compare' : null, r: small(gv2) ? (moved ? 3.2 : 2) : (moved ? 4.6 : 3.2) };
        }), centroidNodes(h.centroids, cs))
      });
    }
  });

  /* ----------------------------------------------------------- self-test */
  var exp = window.CH29_EXPECTED;
  BTViz.selfTest('IVF section = expected_output.txt', C.ivfReport(), exp.slice(exp.indexOf('== 3.'), exp.indexOf('\n\n== 4.')));
})();
