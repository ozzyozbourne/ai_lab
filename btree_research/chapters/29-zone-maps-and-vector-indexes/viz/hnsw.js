/* Chapter 29, page 3: greedy descent on an HNSW-like layered graph (model.js: buildLayered, layeredSearch). */
(function () {
  'use strict';
  var el = BTViz.el, C = window.Ch29;

  BTViz.page({
    title: 'Greedy graph descent', chapter: 29,
    prev: { href: 'ivf.html', title: 'IVF probing' },
    next: { href: '../../30-tracing-a-real-insert/viz/index.html', title: 'Chapter 30: tracing a real insert' }
  });
  C.subnav('#subnav', 'hnsw.html');

  var G = C.buildLayered(C.HNSW), O = C.HNSW, N = G.nodes.length;
  var A0 = { id: 'a0', x: 0, y: 0 }, A1 = { id: 'a1', x: O.width, y: O.height };
  var anchors = [A0, A1].map(function (a) { return { id: a.id, x: a.x, y: a.y, r: 0.5, state: 'dim', label: null }; });

  var fig = BTViz.figure('#fig-hnsw', {
    title: 'Search: greedy on layers 2 and 1, best-first with ef candidates on layer 0', side: true,
    legend: [
      { token: 'node-active', label: 'query (cross), path walked' },
      { token: 'key-compare', label: 'neighbours measured in this step' },
      { token: 'key-inserted', label: 'layer 0: the ef best so far' },
      { token: 'key-found', label: 'answer' },
      { token: 'key-deleted', label: 'true nearest, missed' }
    ]
  });
  var efSel = el('select.bt-select#ef', { 'aria-label': 'ef: candidates kept on layer 0' });
  [1, 2, 4, 8].forEach(function (e) { efSel.appendChild(el('option', { value: e }, 'ef = ' + e)); });
  var randBtn = el('button.bt-btn#random', { type: 'button' }, 'Random query');
  var failBtn = el('button.bt-btn#fail', { type: 'button' }, 'Find a query this ef gets wrong');
  fig.toolbar.append(efSel, randBtn, failBtn);

  var wrap = el('div.c29-layers');
  fig.stage.appendChild(wrap);
  var views = [];
  for (var l = G.maxLevel; l >= 0; l--) {
    var cell = el('div', el('p.c29-layer-title', 'Layer ' + l + ' — ' + G.layers[l].members.length + ' points, up to ' + (l === 0 ? 2 * O.m : O.m) +
      ' links chosen per point' + (l === G.maxLevel ? ' (search starts here)' : l === 0 ? ' (every point)' : '')));
    wrap.appendChild(cell);
    views[l] = new BTViz.GraphView(cell, { height: 300, r: 4.5, ariaLabel: 'Layer ' + l });
  }
  var stats = el('div');
  fig.side.appendChild(el('div.bt-panel', el('div.bt-panel-title', 'This search'), el('div.bt-panel-body', stats)));
  BTViz.codePanel(fig.side, 'descent', { title: 'Descent (FAISS and pseudocode)', active: 'pseudo' });

  var edgesOf = G.layers.map(function (layer) {
    var out = [];
    layer.members.forEach(function (a) { layer.adj[a].forEach(function (b) { if (a < b) out.push({ from: 'n' + a, to: 'n' + b }); }); });
    return out;
  });
  var query = [675, 424], rng = BTViz.rng(4), run;

  var stepper = new BTViz.Stepper({
    mount: fig.controls, caption: fig.caption, root: fig.root, interval: 1500,
    onStep: function (step) { draw(step.state); }
  });

  function draw(st) {
    for (var lv = 0; lv <= G.maxLevel; lv++) {
      var hl = st.layers[lv], view = views[lv], narrow = view.root.clientWidth < 520;
      view.opts.height = Math.round(Math.min(300, view.root.clientWidth * 0.52 + 52)); // same scale on every layer, so a node sits at the same spot
      view.opts.r = narrow ? 3 : 4.5;
      var nodes = G.layers[lv].members.map(function (id) {
        var nd = G.nodes[id];
        return { id: 'n' + id, x: nd.x, y: nd.y, state: hl.nodes[id] || null, label: hl.labels[id] === undefined ? null : hl.labels[id] };
      });
      view.render({
        nodes: anchors.concat(nodes, [{ id: 'q', x: query[0], y: query[1], shape: 'cross', r: narrow ? 5 : 7, label: 'q', state: 'active' }]),
        edges: edgesOf[lv].map(function (e) { return { from: e.from, to: e.to, state: hl.edges[e.from + '>' + e.to] || null }; })
      });
    }
    C.kv(stats, [
      ['query', '(' + query[0] + ', ' + query[1] + ')'],
      ['ef on layer 0', efSel.value],
      ['distances computed', st.final ? run.computed + ' of ' + N : '…'],
      ['answer', st.final ? 'node ' + run.result.id : '…', st.final ? 'found' : null],
      ['true nearest', st.final ? 'node ' + run.truth.id : '(hidden until the end)', st.final && run.truth.id !== run.result.id ? 'deleted' : null]
    ]);
  }

  function rebuild(play) {
    var ef = +efSel.value;
    run = C.layeredSearch(G, query, ef);
    // Persistent highlights per layer; each step takes a snapshot and may add transient marks.
    var keep = G.layers.map(function () { return { nodes: {}, edges: {}, labels: {} }; });
    var snap = function (extra) {
      var layers = BTViz.clone(keep);
      if (extra) extra(layers);
      return { layers: layers };
    };
    var edge = function (a, b) { return 'n' + Math.min(a, b) + '>n' + Math.max(a, b); };
    var here = function (lv, id) { keep[lv].labels = {}; keep[lv].labels[id] = String(id); keep[lv].nodes[id] = 'active'; };
    var steps = [], d2 = function (v) { return 'dist² ' + v; };
    run.trace.forEach(function (t) {
      var lv = t.level;
      if (t.type === 'enter') {
        here(lv, t.node);
        steps.push({
          caption: '<b>Enter</b> at node ' + t.node + ', the fixed entry point on the top layer (layer ' + lv + ', ' + G.layers[lv].members.length +
            ' points). ' + d2(t.dist) + ' to the query. A skip list starts the same way: top level, leftmost node.', state: snap()
        });
      } else if (t.type === 'move') {
        keep[lv].edges[edge(t.from, t.to)] = 'active';
        here(lv, t.to);
        steps.push({
          caption: '<span class="bt-chip s-active">layer ' + lv + '</span> Node ' + t.from + ' has ' + t.nbrs.length + ' neighbours on this layer. Node ' + t.to +
            ' is the closest of them to the query (' + d2(t.dist) + ') and closer than node ' + t.from + ': <b>move</b> there.',
          state: snap(function (ls) { t.nbrs.forEach(function (id) { if (id !== t.to) ls[lv].nodes[id] = 'compare'; }); })
        });
      } else if (t.type === 'stuck') {
        steps.push({
          caption: '<span class="bt-chip s-compare">layer ' + lv + '</span> None of the ' + t.nbrs.length + ' neighbours of node ' + t.node +
            ' is closer to the query (' + d2(t.dist) + '). This is a <b>local minimum</b> on layer ' + lv + ': time to go down.',
          state: snap(function (ls) { t.nbrs.forEach(function (id) { ls[lv].nodes[id] = 'compare'; }); })
        });
      } else if (t.type === 'drop') {
        here(lv, t.node);
        steps.push({
          caption: '<b>Drop</b> to layer ' + lv + '. Node ' + t.node + ' exists here too, among ' + G.layers[lv].members.length + ' points, so its neighbours are nearer and the steps get shorter.' +
            (lv === 0 ? ' Layer 0 is searched differently: keep the best ' + ef + ' (ef) seen so far, and expand the closest one not yet expanded.' : ''),
          state: snap()
        });
      } else if (t.type === 'expand') {
        keep[0].nodes[t.node] = 'active';
        keep[0].labels = {}; keep[0].labels[t.node] = String(t.node);
        var ids = t.W.map(function (h) { return h.id; });
        steps.push({
          caption: '<span class="bt-chip s-inserted">layer 0</span> <b>Expand</b> node ' + t.node + ': ' + (t.fresh.length ? t.fresh.length + ' neighbour' + (t.fresh.length > 1 ? 's' : '') + ' not seen before, measured now' : 'all its neighbours were seen already') +
            '. Best ' + ef + ' so far: ' + ids.map(function (id) { return 'node ' + id; }).join(', ') + '.',
          state: snap(function (ls) {
            t.fresh.forEach(function (id) { ls[0].nodes[id] = 'compare'; });
            t.W.forEach(function (h) { ls[0].nodes[h.id] = 'inserted'; ls[0].labels[h.id] = String(h.id); });
          })
        });
      } else if (t.type === 'stop') {
        var ok = run.result.id === run.truth.id;
        steps.push({
          caption: (t.node === null ? '<b>Stop:</b> nothing left to expand. ' : '<b>Stop:</b> the closest unexpanded candidate (node ' + t.node + ') is farther than everything kept, so no link from it is followed. ') +
            'Answer: node ' + run.result.id + ' (' + d2(run.result.dist) + '), after ' + run.computed + ' distance computations; brute force needs ' + N + '. ' +
            (ok ? '<span class="bt-chip s-found">correct</span> It is the true nearest point.' :
              '<span class="bt-chip s-deleted">missed</span> The true nearest is node ' + run.truth.id + ' (' + d2(run.truth.dist) + '). No kept point links towards it through closer points, and nothing in a graph says "the answer is further that way". A larger ef explores more before giving up.'),
          state: (function () {
            var s = snap(function (ls) {
              t.W.forEach(function (h) { ls[0].nodes[h.id] = 'inserted'; });
              ls[0].labels = {};
              ls[0].nodes[run.result.id] = 'found'; ls[0].labels[run.result.id] = String(run.result.id);
              if (!ok) { ls[0].nodes[run.truth.id] = 'deleted'; ls[0].labels[run.truth.id] = String(run.truth.id); }
            });
            s.final = true;
            return s;
          })()
        });
      }
    });
    stepper.setSteps(steps, { index: 0, instant: true, play: !!play });
  }

  function setQuery(x, y, play) { query = [x, y]; rebuild(play); }
  efSel.addEventListener('change', function () { rebuild(true); });
  randBtn.addEventListener('click', function () { setQuery(rng.int(20, O.width - 20), rng.int(20, O.height - 20), true); });
  failBtn.addEventListener('click', function () {
    var ef = +efSel.value;
    for (var i = 0; i < 3000; i++) {
      var q = [rng.int(20, O.width - 20), rng.int(20, O.height - 20)], r = C.layeredSearch(G, q, ef);
      if (r.result.id !== r.truth.id) { setQuery(q[0], q[1], true); return; }
    }
    fig.caption.innerHTML = 'No failing query found for ef = ' + ef + ' in 3000 random tries. On this small graph that many candidates reach everything.';
  });
  views.forEach(function (v) { C.planeClick(v, A0, A1, function (x, y) { setQuery(x, y, true); }); });
  rebuild(false);

  /* ----------------------------------------------------------- self-test */
  // There is no Zig/Rust program for HNSW (the chapter keeps it to prose), so this pins the JS model itself.
  var a = C.layeredSearch(G, [675, 424], 1), b = C.layeredSearch(G, [675, 424], 4);
  BTViz.selfTest('layered graph model is unchanged',
    { layers: G.layers.map(function (x) { return x.members.length; }), entry: G.entry, ef1: a.result.id, ef4: b.result.id, truth: a.truth.id },
    { layers: [56, 19, 9], entry: 3, ef1: 29, ef4: 6, truth: 6 });
})();
