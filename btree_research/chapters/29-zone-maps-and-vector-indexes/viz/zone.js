/* Chapter 29, page 1: zone-map pruning. Model: model.js (mirrors zonemap.zig / zonemap.rs). */
(function () {
  'use strict';
  var el = BTViz.el, C = window.Ch29;

  BTViz.page({
    title: 'Zone-map pruning', chapter: 29,
    prev: { href: '../../28-radix-trees-and-hash-indexes/viz/index.html', title: 'Chapter 28: radix trees and hash indexes' },
    next: { href: 'ivf.html', title: 'IVF probing' }
  });
  C.subnav('#subnav', 'index.html');

  var VERDICT = {
    always_false: { state: 'free', note: 'skip', text: 'always false' },
    always_true: { state: 'found', note: 'all', text: 'always true' },
    maybe: { state: 'compare', note: 'scan', text: 'maybe' }
  };
  var LEGEND = [
    { token: 'free', label: 'always false: chunk skipped' },
    { token: 'key-found', label: 'always true: rows counted, not read' },
    { token: 'key-compare', label: 'maybe: every row compared' },
    { token: 'node-active', label: 'values the filter accepts' },
    { token: 'node', label: 'dashed: not tested yet' }
  ];
  // Lines of the snippets in code.js. Zig: three lines per arm (all rows / some row / no row); Rust: one.
  var ARM = ['eq', 'ne', 'ge', 'gt', 'le', 'lt'];
  function armLines(op) { var i = ARM.indexOf(op); return { zig: [[5 + 3 * i, 7 + 3 * i]], rust: [5 + i] }; }
  function codeLines(f) {
    if (f.op !== 'between') return armLines(f.op);
    var ge = armLines('ge'), le = armLines('le');
    return { zig: ge.zig.concat(le.zig, [25]), rust: ge.rust.concat(le.rust, [13]) };
  }
  // "Predict" mode: the three possible answers, in the order of CHOICE_OF.
  var CHOICES = ['always false: skip the chunk', 'always true: count all its rows', 'maybe: compare every row'];
  var CHOICE_OF = { always_false: 0, always_true: 1, maybe: 2 };

  /* ------------------------------------------------------------ controls */
  var fig = BTViz.figure('#fig-scan', { title: 'Scan with a zone map', side: true, legend: LEGEND });
  var layoutSel = el('select.bt-select#layout', { 'aria-label': 'Physical layout' });
  [['sorted', 'sorted (clustered)'], ['arrival', 'arrival order (nearly sorted)'], ['shuffled', 'shuffled']].forEach(function (l) {
    layoutSel.appendChild(el('option', { value: l[0] }, l[1]));
  });
  var opSel = el('select.bt-select#op', { 'aria-label': 'Comparison' });
  [['ge', 'v >= c'], ['gt', 'v > c'], ['le', 'v <= c'], ['lt', 'v < c'], ['eq', 'v = c'], ['ne', 'v != c'], ['between', 'c <= v <= c + 49']].forEach(function (o) {
    opSel.appendChild(el('option', { value: o[0] }, o[1]));
  });
  var cInput = el('input.bt-input#c', { type: 'number', min: 0, max: 2299, value: 1500, 'aria-label': 'Constant c' });
  var cSlide = el('input#c-slide', { type: 'range', min: 0, max: 2299, step: 1, value: 1500, 'aria-label': 'Constant c (slider)', style: { flex: '1 1 140px', minWidth: '120px' } });
  var runBtn = el('button.bt-btn.bt-primary#run', { type: 'button' }, 'Replay scan');
  fig.toolbar.append(el('label.bt-field', 'Layout', layoutSel), el('label.bt-field', 'Filter', opSel),
    el('label.bt-field', 'c', cInput), cSlide, runBtn);

  var bars = new C.RangeBars(fig.stage, { rowH: 22 });
  var counters = el('div');
  fig.side.appendChild(el('div.bt-panel', el('div.bt-panel-title', 'Counters'), el('div.bt-panel-body', counters)));
  var code = C.wrapCode(BTViz.codePanel(fig.side, 'checkZone', { title: 'The three-way test', maxHeight: 560 }));

  var zm, filter, result;
  var stepper = new BTViz.Stepper({
    mount: fig.controls, caption: fig.caption, root: fig.root, interval: 700, predict: false,
    onStep: function (step) { draw(step.state.done, step.state.final); }
  });
  C.sideLast(fig);
  C.wideSide(fig); // room for one arm of checkZone per three lines without wrapping

  /** The constant actually used: whatever was typed, rounded and clamped to 0..2299 (empty or junk counts as 0). */
  function clampC(raw) { return Math.min(2299, Math.max(0, Math.round(+raw || 0))); }
  /** Make both controls show the constant the filter uses, so the picture never disagrees with the box. */
  function showC(c) {
    if (cInput.value !== String(c)) cInput.value = c;
    if (cSlide.value !== String(c)) cSlide.value = c;
  }
  function currentFilter() {
    var c = clampC(cInput.value);
    showC(c);
    return opSel.value === 'between' ? { op: 'between', lo: c, hi: c + 49 } : { op: opSel.value, c: c };
  }
  /** Interval of accepted values, for the shaded band (null for "!="). */
  function band(f) {
    var t = C.filterText(f);
    switch (f.op) {
      case 'between': return { lo: f.lo, hi: f.hi, label: t };
      case 'eq': return { lo: f.c, hi: f.c, label: t };
      case 'ge': case 'gt': return { lo: f.c, hi: 2300, label: t };
      case 'le': case 'lt': return { lo: 0, hi: f.c, label: t };
    }
    return { lo: f.c, hi: f.c, label: t + ' (band marks the one rejected value)' };
  }
  function rowsFor(map, res, done, current) {
    return map.zones.map(function (z, i) {
      var v = VERDICT[res.chunks[i].verdict], decided = i < done;
      return { label: String(i), min: z.min, max: z.max, state: decided ? v.state : null, note: decided ? v.note : '', current: i === current, pending: !decided };
    });
  }
  function draw(done, final) {
    bars.render({ domain: [0, 2300], band: band(filter), rows: rowsFor(zm, result, done, final ? -1 : done - 1) });
    var t = { skipped: 0, all: 0, scanned: 0, rows: 0, matches: 0 };
    for (var i = 0; i < done; i++) {
      var ch = result.chunks[i];
      if (ch.verdict === 'always_false') t.skipped++;
      else if (ch.verdict === 'always_true') t.all++;
      else { t.scanned++; t.rows += zm.zones[i].count; }
      t.matches += ch.matches;
    }
    C.kv(counters, [
      ['chunks tested', done + ' / ' + zm.zones.length],
      ['skipped', t.skipped, 'free'],
      ['counted whole', t.all, 'found'],
      ['scanned', t.scanned, 'compare'],
      ['rows compared', t.rows + ' / ' + zm.values.length],
      ['matches so far', t.matches]
    ]);
    code.highlight(codeLines(filter));
  }

  function plural(n, noun) { return n + ' ' + noun + (n === 1 ? '' : 's'); }
  function rebuild(opts) {
    zm = C.buildLayout(layoutSel.value);
    filter = currentFilter();
    result = zm.scan(filter);
    var text = C.filterText(filter), n = zm.zones.length, steps = [];
    steps.push({
      caption: '<b>' + n + ' chunks of ' + zm.chunkSize + ' rows</b>, layout <b>' + layoutSel.value + '</b>, filter <b>' + BTViz.esc(text) +
        '</b>. The scan visits the chunks in storage order and tests each chunk\'s (min, max) first. Press play, ' +
        'or tick <b>Predict</b> to give each chunk\'s verdict yourself before it is shown.',
      state: { done: 0 }
    });
    zm.zones.forEach(function (z, i) {
      var ch = result.chunks[i], v = VERDICT[ch.verdict];
      var what = ch.verdict === 'always_false' ? 'Skip the chunk: 0 rows read.' :
        ch.verdict === 'always_true' ? 'Add all ' + z.count + ' rows to the count without reading them.' :
          'Read and compare all ' + z.count + ' rows: ' + ch.matches + (ch.matches === 1 ? ' matches' : ' match') + (ch.matches === 0 ? ' (the summary could not rule the chunk out, but nothing was there).' : '.');
      steps.push({
        caption: '<span class="bt-chip s-' + v.state + '">chunk ' + i + ': ' + v.text + '</span> ' + BTViz.esc(C.explain(filter, z)) + '. ' + what,
        state: { done: i + 1 },
        // Asked only when the reader ticks "Predict": the same question exercise 1 asks on paper.
        question: {
          prompt: '<b>Chunk ' + i + '</b> holds values from <b>' + z.min + '</b> to <b>' + z.max + '</b>. What can its summary say about <b>' + BTViz.esc(text) + '</b>?',
          choices: CHOICES, answer: CHOICE_OF[ch.verdict]
        }
      });
    });
    var saved = zm.values.length - result.rowsCompared;
    var tail = result.rowsCompared === 0 ? 'The answer came from the summaries alone.' :
      result.skipped + result.all === 0 ? 'The zone map saved nothing: every chunk\'s range overlaps the filter\'s boundary.' :
        'A full scan would compare ' + zm.values.length + ' rows; the summaries saved ' + saved + ' of them.';
    var order = layoutSel.value === 'sorted' ? ' On this sorted layout the zones are disjoint and in order, so a binary search over them (about ' +
      Math.ceil(Math.log2(n)) + ' tests instead of ' + n + ') would also work: that is a B+tree\'s inner node.' :
      ' All ' + n + ' summaries had to be tested, because the chunks are in no order that a search could use.';
    steps.push({
      caption: '<b>Done:</b> ' + plural(result.matches, 'matching row') + '; ' + plural(result.skipped, 'chunk') + ' skipped, ' + result.all + ' counted whole, ' +
        result.scanned + ' scanned, ' + plural(result.rowsCompared, 'row') + ' compared. ' + tail + order,
      state: { done: n, final: true }
    });
    stepper.setSteps(steps, { index: opts && opts.end ? steps.length - 1 : 0, instant: true, play: !!(opts && opts.play) });
    drawLayouts();
  }

  /* ------------------------------------------------ figure 2: three layouts */
  var fig2 = BTViz.figure('#fig-layouts', { title: 'Final verdicts for the same filter', legend: LEGEND.slice(0, 3) });
  var grid = el('div.c29-grid3');
  fig2.stage.appendChild(grid);
  var small = C.LAYOUTS.map(function (name) {
    var note = el('p'), cell = el('div', el('h4', name));
    grid.appendChild(cell);
    var view = new C.RangeBars(cell, { rowH: 9, labelW: 0, noteW: 0, ariaLabel: 'Chunk ranges, ' + name + ' layout' });
    cell.appendChild(note);
    return { name: name, view: view, note: note, zm: C.buildLayout(name) };
  });
  function drawLayouts() {
    small.forEach(function (s) {
      var res = s.zm.scan(filter);
      s.view.render({ domain: [0, 2300], band: band(filter), rows: rowsFor(s.zm, res, s.zm.zones.length, -1).map(function (r) { r.note = ''; return r; }) });
      s.note.textContent = res.skipped + ' skipped, ' + res.all + ' counted whole, ' + res.scanned + ' scanned: ' + res.rowsCompared + ' of ' + s.zm.values.length + ' rows compared.';
    });
    fig2.caption.innerHTML = 'Filter <b>' + BTViz.esc(C.filterText(filter)) + '</b>. Same summaries, same test; only the physical order of the rows differs.';
  }

  /* -------------------------------------------------------------- wiring */
  layoutSel.addEventListener('change', function () { rebuild({ play: true }); });
  opSel.addEventListener('change', function () { rebuild({ end: true }); });
  // rebuild() reads the box, clamps it and writes the clamped value back to the box and the slider.
  cInput.addEventListener('change', function () { rebuild({ end: true }); });
  cSlide.addEventListener('input', function () { cInput.value = cSlide.value; rebuild({ end: true }); });
  runBtn.addEventListener('click', function () { rebuild({ play: true }); });
  rebuild();

  /* ----------------------------------------------------------- self-test */
  var expected = window.CH29_EXPECTED.split('\n').slice(2, 17).join('\n');
  BTViz.selfTest('zone table = expected_output.txt', C.zoneReport(), expected);
})();
