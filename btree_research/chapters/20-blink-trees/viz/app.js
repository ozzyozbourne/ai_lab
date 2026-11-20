/* Chapter 20: the page. Wires model.js (BLink) to the toolkit views. */
(function () {
  'use strict';
  var el = BTViz.el, clone = BTViz.clone;
  var CANONICAL = [10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15];
  var MAX_NODES = 40;

  BTViz.page({
    title: 'B-link trees', chapter: 20,
    prev: { href: '../../19-latching-and-lock-coupling/viz/index.html', title: 'Chapter 19: latching and lock coupling' },
    next: { href: '../../21-durability-primitives/viz/index.html', title: 'Chapter 21: durability primitives' }
  });

  /* ------------------------------------------------------------- figure */
  var fig = BTViz.figure('#fig', {
    title: 'A search meets a split (order 4)', side: true,
    legend: ['node-active', 'key-compare', 'key-found', 'key-inserted', 'key-deleted', 'split', 'lock-shared', 'lock-exclusive',
      { token: 'pointer', label: 'right link (dashed arrow)', line: true }]
  });
  fig.legend.appendChild(el('span.bt-legend-item', el('span.bt-chip', '<26'), 'dashed cell: high key'));

  var scenario = el('select.bt-select#scenario', { 'aria-label': 'Scenario' },
    el('option', { value: 'stale' }, 'Reader overtaken by a split'),
    el('option', { value: 'crash' }, 'Writer dies after step 1'),
    el('option', { value: 'free' }, 'Free play'));
  var follow = el('input#follow', { type: 'checkbox', checked: true });
  var abandon = el('input#abandon', { type: 'checkbox' });
  var key = el('input.bt-input#key', { type: 'text', inputmode: 'numeric', placeholder: 'key', 'aria-label': 'Key (0 to 999)', size: 5, maxlength: 6 });
  var btn = function (id, text, fn, primary) {
    return el('button.bt-btn' + (primary ? '.bt-primary' : '') + '#' + id, { type: 'button', onclick: fn }, text);
  };
  fig.toolbar.append(scenario, btn('replay', 'Replay', function () { load(scenario.value, true); }),
    el('span.bt-toolbar-sep'),
    el('label.c20-check', follow, 'Reader follows right links'),
    el('span.bt-toolbar-sep'),
    key, btn('btn-search', 'Search', search, true), btn('btn-insert', 'Insert', insert),
    el('label.c20-check', abandon, 'writer stops after step 1'));

  var view = new BTViz.TreeView(fig.stage, { minHeight: 250, ariaLabel: 'B-link tree' });
  var status = el('p.c20-status', { role: 'status', 'aria-live': 'polite' });
  var lanesBox = el('div.c20-lanes');
  fig.stage.append(status, lanesBox);
  var lanes = new BTViz.Lanes(lanesBox, { onAdvance: advance });
  var log = new BTViz.Log(fig.side, { title: 'What happened' });

  /* -------------------------------------------------------- code panels */
  var panels = {
    search: BTViz.codePanel('#code', 'search', { title: 'search — one node per step, move right', maxHeight: 340 }),
    split: BTViz.codePanel('#code', 'split', { title: 'insert — a split in two steps', maxHeight: 340 })
  };
  panels.split.root.hidden = true;
  function lineOf(snippet, lang, text, from) {
    var src = String(window.CHAPTER_CODE[snippet][lang]).split('\n');
    for (var i = from || 0; i < src.length; i++) if (src[i].indexOf(text) >= 0) return i;
    return -1;
  }
  function showCode(kind) {
    var part = window.CHAPTER_PARTS[kind];
    if (!part) { panels.search.highlight([]); panels.split.highlight([]); return; }
    Object.keys(panels).forEach(function (sn) { panels[sn].root.hidden = sn !== part.snippet; });
    var spec = {};
    ['zig', 'rust'].forEach(function (lang) {
      var a = lineOf(part.snippet, lang, part[lang][0], 0), b = lineOf(part.snippet, lang, part[lang][1], a);
      spec[lang] = [[a + 1, b + 1]];
    });
    panels[part.snippet].highlight(spec);
  }

  /* ---------------------------------------------------------- timeline */
  var history = [], untouched = null;   // untouched: name of the scenario if the reader has not changed it
  function mkStep(S, info) {
    return { state: clone(S), caption: info.caption, hl: info.hl || {}, log: info.log, kind: info.kind || null };
  }
  function canonicalState() {
    var tree = new BLink.Tree(4);
    CANONICAL.forEach(function (k) { tree.put(k); });
    return { t: tree.t, reader: null, writer: null };
  }
  function modeText(f) { return f ? '' : ' It <b>ignores right links</b>, like a search in a plain B+tree.'; }

  function build(name, f) {
    var S = canonicalState(), steps = [];
    function note(caption, logText) { steps.push(mkStep(S, { caption: caption, log: logText })); }
    function run(who, n) { while (n-- > 0 && BLink.canStep(S, who)) steps.push(mkStep(S, BLink.advance(S, who))); }
    if (name === 'stale') {
      S.reader = BLink.newReader(S.t, 30, f);
      S.writer = BLink.newWriter(S.t, 26, 2600, false);
      note('Two threads. The <b>reader</b> looks up ' + BTViz.k(30) + '.' + modeText(f) + ' The <b>writer</b> inserts ' + BTViz.k(26) +
        ' into the full leaf #3. Press play, or use the two <b>Step</b> buttons below the tree to choose the interleaving yourself.', 'get 30 and put 26 start');
      run('R', 2);
      run('W', 99);
      note('The writer is done. The reader still believes "30 is in #3": it read that in #6 <em>before</em> the split. Its next step shows what the high key is for.');
      run('R', 99);
    } else if (name === 'crash') {
      S.writer = BLink.newWriter(S.t, 26, 2600, true);
      note('The <b>writer</b> inserts ' + BTViz.k(26) + ' into the full leaf #3, and in this scenario it will die between the two steps of the split.', 'put 26 starts');
      run('W', 99);
      S.reader = BLink.newReader(S.t, 30, f);
      note('A <b>reader</b> arrives and looks up ' + BTViz.k(30) + ', which now lives in #8, the node without a downlink.' + modeText(f), 'get 30 starts');
      run('R', 99);
      S.writer = BLink.newWriter(S.t, 27, 2700, false);
      note('A second <b>writer</b> inserts ' + BTViz.k(27) + '. It is routed to #3, because that is where the parent sends every key from 20 upwards.', 'put 27 starts');
      run('W', 99);
      S.reader = BLink.newReader(S.t, 30, f);
      note('The split is complete now. One more lookup of ' + BTViz.k(30) + ':' + modeText(f), 'get 30 starts');
      run('R', 99);
    } else {
      note('Free play: the canonical tree, nobody running. Type a key and press <b>Search</b> or <b>Insert</b>, then use the <b>Step</b> buttons of the two threads. Keys 26, 13 or 2 go into full leaves.');
    }
    return steps;
  }

  var stepper = new BTViz.Stepper({
    mount: fig.controls, caption: fig.caption, root: fig.root, interval: 2200,
    onStep: function (step, i) {
      Ch20.render(view, step.state, step.hl);
      drawLanes(step.state);
      log.sync(stepper ? stepper.steps : history, i);
      showCode(step.kind);
    }
  });

  function load(name, play) {
    history = build(name, follow.checked);
    untouched = name;
    say('');
    stepper.setSteps(history, { play: !!play && history.length > 1 });
  }

  /** Show the step just appended, animating from the one before it. */
  function showLast() {
    stepper.setSteps(history, { index: history.length - 2, instant: true });
    stepper.next();
  }

  /* -------------------------------------------------------------- lanes */
  function drawLanes(S) {
    var r = S.reader, w = S.writer, rb = BLink.blocked(S, 'R');
    var rl = { id: 'R', label: 'Reader', events: [], canStep: false, status: 'idle. Type a key and press Search.' };
    if (r) {
      rl.label = 'Reader · get ' + r.key + (r.follow ? '' : ' · right links ignored');
      rl.events = r.events;
      rl.canStep = BLink.canStep(S, 'R');
      rl.state = r.done ? (r.missed ? 'aborted' : 'done') : rb ? 'blocked' : 'running';
      rl.status = r.done ? (r.missed ? 'answered "not found" for a key that is in the tree' : r.value === null ? 'answered "not found"' : 'found ' + r.key + ' after visiting ' + r.visited + ' nodes, moved right ' + r.moves + ' time' + (r.moves === 1 ? '' : 's'))
        : rb ? 'waiting for the latch on #' + r.next + ', held by the writer' : 'holds no latch; next: visit #' + r.next;
    }
    var wl = { id: 'W', label: 'Writer', events: [], canStep: false, status: 'idle. Type a key and press Insert.' };
    if (w) {
      wl.label = 'Writer · put ' + w.key + (w.abandon ? ' · stops after step 1' : '');
      wl.events = w.events;
      wl.canStep = BLink.canStep(S, 'W');
      wl.state = w.done ? (w.events.length && w.events[w.events.length - 1].text === 'stopped' ? 'aborted' : 'done') : 'running';
      wl.status = w.done ? 'finished; holds no latch'
        : w.phase === 'descend' ? 'holds no latch; next: visit #' + w.at
        : w.phase === 'leaf' ? 'holds X on #' + w.held + '; next: insert ' + w.key
        : w.phase === 'abandon' ? 'holds X on #' + w.held + '; next: stop (step 2 never happens)'
        : 'holds X on #' + w.held + '; next: step 2 (downlink into the parent)';
    }
    lanes.render({ lanes: [rl, wl] });
  }

  /** A Step button: act on the state that is on screen, dropping any later steps. */
  function advance(who) {
    var i = stepper.index, S = clone(history[i].state);
    if (!BLink.canStep(S, who)) return;
    history = history.slice(0, i + 1);
    history.push(mkStep(S, BLink.advance(S, who)));
    untouched = null;
    say('');
    showLast();
  }

  /* ------------------------------------------------------ Search / Insert */
  function say(text, error) {
    status.textContent = text;
    status.classList.toggle('is-error', !!error);
  }
  function readKey() {
    var raw = key.value.trim();
    if (!/^[0-9]{1,3}$/.test(raw)) {
      say(raw === '' ? 'Type a key first: a whole number from 0 to 999.' : '"' + raw + '" is not a key. Type a whole number from 0 to 999.', true);
      key.focus();
      return null;
    }
    return +raw;
  }
  function start(mutate, caption, logText) {
    var i = stepper.index, S = clone(history[i].state);
    var problem = mutate(S);
    if (problem) { say(problem, true); return; }
    history = history.slice(0, i + 1);
    history.push(mkStep(S, { caption: caption(S), log: logText }));
    untouched = null;
    say('');
    showLast();
  }
  function search() {
    var k = readKey();
    if (k === null) return;
    start(function (S) { S.reader = BLink.newReader(S.t, k, follow.checked); },
      function (S) {
        return 'A new reader looks up ' + BTViz.k(k) + ', starting at the root #' + S.t.root + '.' + modeText(follow.checked) +
          ' Use the reader\'s <b>Step</b> button' + (S.writer && !S.writer.done ? ', or let the writer go first.' : '.');
      }, 'get ' + k + ' starts');
  }
  function insert() {
    var k = readKey();
    if (k === null) return;
    start(function (S) {
      if (S.writer && !S.writer.done) return 'The writer is in the middle of put ' + S.writer.key + '. Step it to the end first.';
      if (S.t.nodes.length >= MAX_NODES) return 'The tree is as large as this page can show. Choose a scenario to start again.';
      S.writer = BLink.newWriter(S.t, k, k * 100, abandon.checked);
    }, function (S) {
      return 'A new writer inserts ' + BTViz.k(k) + (abandon.checked ? ' and will stop after step 1 if the insert causes a split' : '') +
        '. Use the writer\'s <b>Step</b> button' + (S.reader && !S.reader.done ? ', or let the reader go first.' : '.');
    }, 'put ' + k + ' starts');
  }
  key.addEventListener('keydown', function (e) { if (e.key === 'Enter') search(); e.stopPropagation(); });
  scenario.addEventListener('change', function () { load(scenario.value, false); });
  follow.addEventListener('change', function () {
    if (untouched) {
      load(untouched, true);
      say(follow.checked ? 'Replaying with right links.' : 'Replaying with right links switched off.');
    } else {
      say('This applies to the next Search. The search that is under way keeps its mode.');
    }
  });

  load('stale', false);

  /* ----------------------------------------------------------- self-tests
   * The same operations as sections 1 to 6 of the Zig and Rust programs; the
   * expected text is copied from ../expected_output.txt. */
  (function () {
    var t = new BLink.Tree(4);
    CANONICAL.forEach(function (k) { t.put(k); });
    BTViz.selfTest('canonical', t.dump(),
      'height 3, 12 keys, 8 nodes\n  level 2: #7[15]\n  level 1: #2[6 10]<15 -> #6[20]\n' +
      '  level 0: #0(1 3 5)<6 -> #4(6 7)<10 -> #1(10 12)<15 -> #5(15 17)<20 -> #3(20 25 30)\n');
    t.put(26, { abandon: true });
    BTViz.selfTest('half split', t.dump(),
      'height 3, 13 keys, 9 nodes\n  level 2: #7[15]\n  level 1: #2[6 10]<15 -> #6[20]\n' +
      '  level 0: #0(1 3 5)<6 -> #4(6 7)<10 -> #1(10 12)<15 -> #5(15 17)<20 -> #3(20 25)<26 {incomplete} -> #8(26 30) {no downlink}\n');
    var keys = CANONICAL.concat([26]);
    var found = function (f) { return keys.filter(function (k) { return t.lookup(k, f).value !== null; }).length; };
    BTViz.selfTest('lookups', found(true) + ' of 13 with, ' + found(false) + ' of 13 without', '13 of 13 with, 11 of 13 without');
    t.put(27);
    BTViz.selfTest('finished', t.dump(),
      'height 3, 14 keys, 9 nodes\n  level 2: #7[15]\n  level 1: #2[6 10]<15 -> #6[20 26]\n' +
      '  level 0: #0(1 3 5)<6 -> #4(6 7)<10 -> #1(10 12)<15 -> #5(15 17)<20 -> #3(20 25)<26 -> #8(26 27 30)\n');
    [30, 28, 32, 31].forEach(function (k) { t.put(k); });
    BTViz.selfTest('section 5', t.dump(),
      'height 3, 17 keys, 12 nodes\n  level 2: #7[15 28]\n  level 1: #2[6 10]<15 -> #6[20 26]<28 -> #11[31]\n' +
      '  level 0: #0(1 3 5)<6 -> #4(6 7)<10 -> #1(10 12)<15 -> #5(15 17)<20 -> #3(20 25)<26 -> #8(26 27)<28 -> #9(28 30)<31 -> #10(31 32)\n');
    var r = new BLink.Tree(4);
    [1, 2, 3].forEach(function (k) { r.put(k); });
    r.put(4, { abandon: true });
    var half = r.dump();
    r.put(5);
    BTViz.selfTest('root split', half + r.dump(),
      'height 1, 4 keys, 2 nodes\n  level 0: #0(1 2)<3 {incomplete} -> #1(3 4) {no downlink}\n' +
      'height 2, 5 keys, 3 nodes\n  level 1: #2[3]\n  level 0: #0(1 2)<3 -> #1(3 4 5)\n');
  })();
})();
