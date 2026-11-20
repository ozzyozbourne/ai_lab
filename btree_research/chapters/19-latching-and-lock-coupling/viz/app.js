/* Chapter 19: page wiring. The model lives in local.js (window.Ch19). */
(function () {
  'use strict';
  var el = BTViz.el, Tree = Ch19.Tree, Sim = Ch19.Sim;

  BTViz.page({
    title: 'Latching and lock coupling', chapter: 19,
    prev: '../../18-indexes-in-a-database/viz/index.html',
    next: '../../20-blink-trees/viz/index.html'
  });

  var LEGEND = [
    { token: 'lock-shared', label: 'shared latch (S)' },
    { token: 'lock-exclusive', label: 'exclusive latch (X)' },
    { token: 'split', label: 'node changed by the last step' },
    { token: 'key-inserted', label: 'key just inserted' }
  ];
  var PROTOCOLS = ['mutex', 'rwlock', 'coupling', 'optimistic'];

  function protocolSelect(id, value) {
    var sel = el('select.bt-select#' + id, { 'aria-label': 'Protocol' });
    PROTOCOLS.forEach(function (p) { sel.appendChild(el('option', { value: p }, Sim.NAMES[p])); });
    sel.value = value;
    return sel;
  }

  /** The strip above the tree: who holds the tree-wide lock (global protocols). */
  function GlobalStrip(target) {
    this.root = el('div.ch19-glock');
    target.appendChild(this.root);
  }
  GlobalStrip.prototype.render = function (g, protocol) {
    var r = this.root;
    r.textContent = '';
    if (protocol === 'coupling') { r.appendChild(el('span', 'No tree-wide lock: one latch per node, shown as badges on the nodes.')); return; }
    if (protocol === 'optimistic') { r.appendChild(el('span', 'No tree-wide lock. Next to each node id is its version (v0, v1 …); readers take no latch.')); return; }
    r.appendChild(el('strong', protocol === 'mutex' ? 'Tree-wide mutex: ' : 'Tree-wide reader-writer lock: '));
    var any = false;
    if (g.x !== null) { r.appendChild(el('span.bt-lock.is-exclusive', g.x + (protocol === 'mutex' ? '' : ':X'))); any = true; }
    g.s.forEach(function (tid) { r.appendChild(el('span.bt-lock.is-shared', tid + ':S')); any = true; });
    g.waiting.forEach(function (tid) { r.appendChild(el('span.bt-chip.s-compare', tid + ' waits')); any = true; });
    if (!any) r.appendChild(el('span.ch19-free', 'free'));
  };

  /* Code panel helpers: lines of a snippet that contain one of the fragments
   * listed for a step kind in CH19_MARKS. `latch(` must not match `unlatch(`. */
  function linesFor(snippet, mark) {
    var needles = (window.CH19_MARKS[snippet] || {})[mark] || [], out = {};
    Object.keys(window.CHAPTER_CODE[snippet]).forEach(function (lang) {
      out[lang] = [];
      window.CHAPTER_CODE[snippet][lang].split('\n').forEach(function (line, i) {
        var hit = needles.some(function (nd) {
          var at = line.indexOf(nd);
          return at >= 0 && (at === 0 || !/[A-Za-z_]/.test(line.charAt(at - 1)));
        });
        if (hit) out[lang].push(i + 1);
      });
    });
    return out;
  }
  function snippetFor(protocol, mark) {
    if (protocol === 'mutex' || protocol === 'rwlock') return 'global';
    if (protocol === 'optimistic' && /^opt/.test(mark || 'opt')) return 'optimistic';
    return 'coupled';
  }

  /* ---------------------------------------------- 1. the programs' experiments */

  var EXPERIMENTS = [
    { label: 'T1 get 12 frozen on leaf #1; T2 put 11 (same leaf)', setup: [], a: { kind: 'get', key: 12 }, b: { kind: 'put', key: 11 } },
    { label: 'T1 get 12 frozen on leaf #1; T2 put 16 (other leaf)', setup: [], a: { kind: 'get', key: 12 }, b: { kind: 'put', key: 16 } },
    { label: 'T1 put 11 frozen on leaf #1; T2 get 12 (same leaf)', setup: [], a: { kind: 'put', key: 11 }, b: { kind: 'get', key: 12 } },
    { label: 'T1 put 26 into the full leaf #3; T2 get 17 (same parent)', setup: [], a: { kind: 'put', key: 26 }, b: { kind: 'get', key: 17 } },
    { label: 'T1 put 26 into the full leaf #3; T2 get 12 (other subtree)', setup: [], a: { kind: 'put', key: 26 }, b: { kind: 'get', key: 12 } },
    { label: 'T1 put 2: full leaf under a full parent; T2 get 25', setup: [8, 9], a: { kind: 'put', key: 2 }, b: { kind: 'get', key: 25 } },
    { label: 'Root replaced: T1 get 20 has read the root id; T2 put 6 splits the root', keys: [10, 20, 5], capacity: 16, setup: [], a: { kind: 'get', key: 20 }, b: { kind: 'put', key: 6 }, freeze: 'afterRootLoad' },
    { label: 'Convoy, four threads: T1 put 26 frozen; then T2 get 17, T3 get 12, T4 put 11', setup: [], a: { kind: 'put', key: 26 },
      others: [{ kind: 'get', key: 17 }, { kind: 'get', key: 12 }, { kind: 'put', key: 11 }] }
  ];

  function experimentTree(ex) {
    return Tree.build(ex.capacity || 64, (ex.keys || Ch19.CANONICAL).concat(ex.setup));
  }

  function heldText(view, tid) {
    var lane = view.lanes.filter(function (l) { return l.id === tid; })[0];
    var m = /holds (.*)$/.exec(lane.status);
    return m ? m[1] : 'nothing';
  }

  /**
   * Section 7 of the programs: T1 frozen, then several threads start one after
   * the other. A thread that waits keeps what it holds, so a later one can
   * wait for a thread that is itself only waiting.
   */
  function convoySteps(ex, protocol) {
    var c = Sim.convoy(experimentTree(ex), protocol, ex.a, ex.others, 'atLeaf');
    var steps = [], last = c.initial, n = ex.others.length;
    function op(o) { return o.kind + ' ' + o.key; }
    function push(caption, view, extra) {
      var s = { caption: caption, state: view };
      for (var key in (extra || {})) s[key] = extra[key];
      steps.push(s);
    }
    function lane(view, tid) { return view.lanes.filter(function (l) { return l.id === tid; })[0]; }
    push('Protocol: <b>' + Sim.NAMES[protocol] + '</b>. Four threads this time. <b>T1</b> will ' + op(ex.a) + ' and is frozen in the middle. Then ' +
      ex.others.map(function (o, i) { return '<b>T' + (i + 2) + '</b> (' + op(o) + ')'; }).join(', ') +
      ' start one after the other; each runs until it finishes or has to wait. Press <kbd>→</kbd> or Play.', c.initial);
    function stopNote(i) {
      var tid = 'T' + (i + 2), out = c.outcomes[i], text;
      if (out === 'finishes') text = '<b>' + tid + ' is done</b> although T1 never moved.';
      else {
        var m = /waiting for (.*?), held by ([^·]*)/.exec(lane(last, tid).status), holds = heldText(last, tid);
        text = '<b>' + tid + ' cannot continue</b>: it ' + (out === 'waits' ? 'waits for the tree-wide lock' : out.replace('#', 'node #')) +
          ', held by <b>' + (m ? m[2].trim() : 'T1') + '</b>. ' +
          (holds === 'nothing' ? tid + ' holds nothing while it waits.' : 'While it waits, ' + tid + ' <b>keeps ' + holds + '</b>: whoever needs that node in a conflicting mode now waits for a thread that is itself waiting.');
      }
      var next = i + 1 < n ? ' Next: T' + (i + 3) + ', ' + op(ex.others[i + 1]) + '.' : ' Now T1 is released and everybody goes on.';
      var extra = { hold: 2 };
      if (i + 1 === n - 1) {
        // Ask before the last thread starts: it is the one the convoy catches (or not).
        var lastOut = c.outcomes[n - 1], t1 = heldText(last, 'T1');
        extra.question = {
          prompt: 'T' + (n + 1) + ' wants to ' + op(ex.others[n - 1]) + ' under <b>' + Sim.NAMES[protocol] + '</b>. T1 is frozen holding <b>' + t1 + '</b>. What happens to T' + (n + 1) + '?',
          choices: ['T' + (n + 1) + ' finishes while T1 is frozen', 'T' + (n + 1) + ' has to wait'],
          answer: lastOut === 'finishes' ? 0 : 1,
          explain: lastOut === 'finishes' ? 'Nothing T' + (n + 1) + ' needs is held in a conflicting mode.' :
            'T' + (n + 1) + ' ' + lastOut + (lastOut === 'waits' ? ' for the tree-wide lock' : '') + '. Look at who holds it.'
        };
      }
      push(text + next, last, extra);
    }
    c.trace.forEach(function (item, i) {
      if (i === c.frozenAt) push('<b>T1 is frozen here.</b> It holds: <b>' + heldText(last, 'T1') + '</b>. Now T2 runs: ' + op(ex.others[0]) + '.', last, { hold: 2 });
      c.stops.forEach(function (at, f) { if (at === i) stopNote(f); });
      push(item.caption, item.view, { mark: item.mark });
      last = item.view;
    });
    var waiting = c.outcomes.filter(function (o) { return o !== 'finishes'; }).length;
    push('All four threads are done. While T1 was frozen, ' + waiting + ' of the other three had to wait. ' +
      (protocol === 'coupling' ? 'With only two threads, the same put 11 finishes next to the same frozen put 26 (section 3 of the programs\' output): here it was stopped by T2, which was itself only waiting. ' : '') +
      'Try this under another protocol.', last);
    return steps;
  }

  function guidedSteps(ex, protocol) {
    if (ex.others) return convoySteps(ex, protocol);
    var p = Sim.probe(experimentTree(ex), protocol, ex.a, ex.b, ex.freeze || 'atLeaf');
    var opA = ex.a.kind + ' ' + ex.a.key, opB = ex.b.kind + ' ' + ex.b.key, steps = [];
    function push(caption, view, extra) {
      var s = { caption: caption, state: view };
      for (var key in (extra || {})) s[key] = extra[key];
      steps.push(s);
    }
    push('Protocol: <b>' + Sim.NAMES[protocol] + '</b>. Thread <b>T1</b> will ' + opA + ', thread <b>T2</b> will ' + opB +
      '. As in the chapter\'s programs, T1 runs first and is frozen in the middle; then T2 runs. Press <kbd>→</kbd> or Play.', p.initial);
    var last = p.initial;
    p.trace.forEach(function (item, i) {
      if (i === p.frozenAt) {
        var holds = heldText(last, 'T1');
        push('<b>T1 is frozen here</b> (the programs use a test hook for this). It holds: <b>' + holds + '</b>. Now T2 runs: ' + opB + '.', last, {
          hold: 2,
          question: {
            prompt: 'T1 stays frozen, holding <b>' + holds + '</b>. T2 wants to ' + opB + ' under <b>' + Sim.NAMES[protocol] + '</b>. What happens to T2?',
            choices: ['T2 finishes while T1 is frozen', 'T2 has to wait for T1'],
            answer: p.outcome === 'finishes' ? 0 : 1,
            explain: p.outcome === 'finishes' ? 'Nothing T2 needs is held by T1 in a conflicting mode.' : 'T2 ' + p.outcome + (p.outcome === 'waits' ? ' for the tree-wide lock' : '') + '.'
          }
        });
      }
      if (i === p.bStoppedAt && p.outcome !== 'finishes') {
        push('<b>T2 cannot continue</b>: it ' + (p.outcome === 'waits' ? 'waits for the tree-wide lock' : p.outcome.replace('#', 'node #')) + ', which T1 holds. ' +
          (protocol === 'optimistic' ? '' : 'The programs print "' + p.outcome + '" for this experiment. ') + 'T1 is released and goes on.', last, { hold: 2 });
      }
      if (i === p.bStoppedAt && p.outcome === 'finishes') {
        push('<b>T2 is done</b> although T1 never moved' + (protocol === 'optimistic' ? '' : ': the programs print "finishes"') + '. T1 is released and goes on.', last, { hold: 2 });
      }
      push(item.caption, item.view, { mark: item.mark });
      last = item.view;
    });
    var t1 = p.sim.threads.T1, t2 = p.sim.threads.T2;
    push('Both threads are done. T1: ' + t1.result + (t1.restarts ? ' after ' + t1.restarts + ' restart' + (t1.restarts === 1 ? '' : 's') : '') + '. T2: ' + t2.result +
      (t2.restarts ? ' after ' + t2.restarts + ' restart' + (t2.restarts === 1 ? '' : 's') : '') + '. Try the same experiment under another protocol.', last);
    return steps;
  }

  (function () {
    var fig = BTViz.figure('#fig-guided', { title: 'One operation frozen, the other one runs', side: true, legend: LEGEND });
    var selProto = protocolSelect('g-protocol', 'coupling');
    var selExp = el('select.bt-select#g-exp', { 'aria-label': 'Experiment' });
    EXPERIMENTS.forEach(function (ex, i) { selExp.appendChild(el('option', { value: i }, ex.label)); });
    fig.toolbar.append(el('label.bt-field', 'Protocol ', selProto), el('label.bt-field.ch19-wide', 'Experiment ', selExp));

    var strip = new GlobalStrip(fig.stage);
    var view = new BTViz.TreeView(fig.stage, { minHeight: 205 });
    var lanes = new BTViz.Lanes(fig.stage, {});
    var panels = {};
    ['coupled', 'global', 'optimistic'].forEach(function (name) {
      var holder = el('div');
      fig.side.appendChild(holder);
      panels[name] = { holder: holder, panel: BTViz.codePanel(holder, name, {
        title: name === 'coupled' ? 'coupled.zig / coupled.rs' : name === 'global' ? 'tree.zig / tree.rs' : 'Sketch (not in the chapter code)', maxHeight: 360 }) };
    });

    var protocol = selProto.value;
    var stepper = new BTViz.Stepper({
      mount: fig.controls, caption: fig.caption, root: fig.root, steps: [], predict: false, interval: 2200,
      onStep: function (step) {
        strip.render(step.state.global, protocol);
        view.render(step.state.tree, step.state.hl);
        lanes.render({ lanes: step.state.lanes });
        var snippet = snippetFor(protocol, step.mark);
        Object.keys(panels).forEach(function (name) { panels[name].holder.hidden = name !== snippet; });
        panels[snippet].panel.highlight(step.mark ? linesFor(snippet, step.mark) : []);
      }
    });
    function load() {
      protocol = selProto.value;
      var ex = EXPERIMENTS[+selExp.value];
      // Four lanes: two by two on a wide screen, so the picture and the controls stay together.
      fig.root.classList.toggle('ch19-many', !!ex.others);
      stepper.setSteps(guidedSteps(ex, protocol));
    }
    selProto.addEventListener('change', load);
    selExp.addEventListener('change', load);
    load();
  })();

  /* ------------------------------------------------------------ 2. sandbox */

  (function () {
    var fig = BTViz.figure('#fig-sandbox', { title: 'Your turn: you are the scheduler', side: true, legend: LEGEND });
    var selProto = protocolSelect('s-protocol', 'coupling');
    function opControls(tid, kind, key) {
      var sel = el('select.bt-select#s-' + tid + '-kind', { 'aria-label': tid + ' operation' }, el('option', { value: 'get' }, 'get'), el('option', { value: 'put' }, 'put'));
      sel.value = kind;
      var input = el('input.bt-input#s-' + tid + '-key', { type: 'text', inputmode: 'numeric', value: key, 'aria-label': tid + ' key', style: { width: '3.6em' } });
      return { sel: sel, input: input, field: el('span.bt-field', el('strong', tid + ' '), sel, input) };
    }
    var c1 = opControls('T1', 'put', 26), c2 = opControls('T2', 'get', 17);
    var btnStart = el('button.bt-btn.bt-primary#s-start', { type: 'button' }, 'Start');
    var btnUndo = el('button.bt-btn#s-undo', { type: 'button' }, 'Undo step');
    var btnReset = el('button.bt-btn#s-reset', { type: 'button' }, 'Reset tree');
    fig.toolbar.append(el('label.bt-field', 'Protocol ', selProto), c1.field, c2.field, btnStart, btnUndo, btnReset);

    var strip = new GlobalStrip(fig.stage);
    var view = new BTViz.TreeView(fig.stage, { minHeight: 230 });
    var lanes = new BTViz.Lanes(fig.stage, { onAdvance: advance });
    var log = new BTViz.Log(fig.side, { title: 'Steps taken' });

    var CAPACITY = 24;
    var tree;          // the tree on screen while no round is active
    var round = null;  // {base: Tree, protocol, ops, schedule: [tid…]} while two operations are in flight (or just finished)
    var sim = null, lastCaption = '';

    function parseKey(input, tid) {
      var raw = input.value.trim();
      if (raw === '') return { error: tid + ': type a key (a whole number from 0 to 99).' };
      if (!/^\d+$/.test(raw)) return { error: tid + ': "' + BTViz.esc(raw) + '" is not a whole number from 0 to 99. Negative numbers and decimals are not accepted.' };
      var v = parseInt(raw, 10);
      if (v > 99) return { error: tid + ': ' + v + ' is out of range. Keys on this page are 0 to 99.' };
      return { value: v };
    }

    /** Replays the round's schedule on a copy of the tree the round started from. */
    function rebuild() {
      sim = new Sim(round.base.clone(), round.protocol, round.ops);
      log.clear();
      lastCaption = '';
      round.schedule.forEach(function (tid) {
        var r = sim.advance(tid);
        lastCaption = r.caption;
        log.add('<b>' + tid + '</b> ' + r.text);
      });
    }

    function active() { return round !== null && !sim.allDone(); }

    function draw(message) {
      var v;
      if (round) v = sim.view();
      else v = new Sim(tree.clone(), selProto.value, {}).view();
      strip.render(v.global, round ? round.protocol : selProto.value);
      view.render(v.tree, v.hl);
      var next = null;
      v.lanes.forEach(function (l) { if (l.canStep && next === null) next = l.id; });
      lanes.render({ lanes: v.lanes, next: next });
      var busy = active();
      [selProto, c1.sel, c1.input, c2.sel, c2.input, btnStart].forEach(function (c) { c.disabled = busy; });
      btnUndo.disabled = !round;
      var text;
      if (message) text = message;
      else if (!round) text = 'Choose a protocol and one operation per thread, then press <b>Start</b>. The two operations run on the tree shown here; keys are 0 to 99.';
      else if (!round.schedule.length) text = 'Both operations are ready. Press a <b>Step</b> button to let that thread take its next step. A thread that needs a latch the other one holds cannot step.';
      else if (sim.allDone()) text = lastCaption + ' <b>Both threads are done.</b> Choose the next two operations (they will run on this tree), or undo to try another order.';
      else if (!v.lanes.some(function (l) { return l.canStep; })) text = lastCaption + ' <b>Neither thread can step: a deadlock.</b> The protocols on this page take latches top-down only, so this should be impossible.';
      else text = lastCaption;
      fig.caption.innerHTML = text;
    }

    function advance(tid) {
      if (!round || !sim.canStep(tid)) return;
      var r = sim.advance(tid);
      round.schedule.push(tid);
      lastCaption = r.caption;
      log.add('<b>' + tid + '</b> ' + r.text);
      if (sim.allDone()) tree = sim.tree;
      draw();
    }

    function start() {
      if (active()) return;
      var k1 = parseKey(c1.input, 'T1'), k2 = parseKey(c2.input, 'T2');
      if (k1.error || k2.error) {
        draw('<span class="ch19-error" role="alert">' + (k1.error || k2.error) + '</span> Nothing was started.');
        return;
      }
      round = {
        base: tree.clone(), protocol: selProto.value, schedule: [],
        ops: { T1: { kind: c1.sel.value, key: k1.value }, T2: { kind: c2.sel.value, key: k2.value } }
      };
      rebuild();
      draw();
    }

    function undo() {
      if (!round) return;
      if (round.schedule.length) {
        round.schedule.pop();
        rebuild();
        draw(round.schedule.length ? 'Undone. ' + lastCaption : 'Undone: both operations are back at their first step.');
      } else {
        tree = round.base;
        round = null;
        sim = null;
        log.clear();
        draw('The two operations were withdrawn. The tree is as it was before them.');
      }
    }

    function reset() {
      tree = Tree.build(CAPACITY, Ch19.CANONICAL);
      round = null;
      sim = null;
      log.clear();
      draw();
    }

    btnStart.addEventListener('click', start);
    btnUndo.addEventListener('click', undo);
    btnReset.addEventListener('click', reset);
    [c1.input, c2.input].forEach(function (input) {
      input.addEventListener('keydown', function (e) { if (e.key === 'Enter') start(); });
    });
    selProto.addEventListener('change', function () { if (!active()) { round = null; sim = null; log.clear(); draw(); } });
    reset();
  })();

  /* --------------------------------------------------------- 3. self-tests */

  (function () {
    var expected = window.CH19_EXPECTED;
    document.getElementById('program-output').textContent = expected;
    // Sections of the programs' output: text between "== n. … ==" headers.
    var sections = {};
    expected.split(/\n?== (\d)\. [^\n]*==\n/).forEach(function (part, i, all) { if (i % 2 === 1) sections[part] = all[i + 1]; });

    var NAME = { mutex: 'global mutex', rwlock: 'global rwlock', coupling: 'latch coupling' };
    var THREE = ['mutex', 'rwlock', 'coupling'];
    function pad(s, w) { while (s.length < w) s += ' '; return s; }

    /** One put through the simulator, alone: what tree.put() does in the programs. */
    function putVia(tree, protocol, key) {
      var sim = new Sim(tree, protocol, { T1: { kind: 'put', key: key } });
      while (!sim.allDone()) sim.advance('T1');
      return { result: sim.threads.T1.result, locksLeft: sim.held('T1').length };
    }
    function buildVia(protocol, capacity, keys) {
      var t = new Tree(capacity);
      keys.forEach(function (k) { putVia(t, protocol, k); });
      return t;
    }

    // Section 1: the same tree under every protocol.
    var s1 = '', ref = null;
    THREE.forEach(function (p) {
      var text = buildVia(p, 64, Ch19.CANONICAL).dump();
      if (ref === null) { ref = text; s1 += NAME[p] + ':\n  ' + text; } else s1 += NAME[p] + ': same tree: ' + (text === ref ? 'yes' : 'NO') + '\n';
    });
    BTViz.selfTest('1 tree', s1, sections['1'], '#selftests');

    // Section 3: the frozen-operation experiments.
    var SCENARIOS = [
      { title: 'A = get 12 (latch coupling holds: #1 shared)', setup: [], a: ['get', 12], others: [['get', 25, 'other leaf'], ['get', 10, 'same leaf'], ['put', 16, 'other leaf'], ['put', 11, 'same leaf']] },
      { title: 'A = put 11 (latch coupling holds: #1 exclusive; leaf #1 has room)', setup: [], a: ['put', 11], others: [['get', 25, 'other leaf'], ['get', 12, 'same leaf'], ['put', 16, 'other leaf']] },
      { title: 'A = put 26 (latch coupling holds: #6, #3 exclusive; leaf #3 is full, its parent #6 has room)', setup: [], a: ['put', 26], others: [['get', 12, 'under #2'], ['put', 11, 'under #2'], ['get', 17, 'under #6']] },
      { title: 'after put 8, put 9: A = put 2 (latch coupling holds: #7, #2, #0 exclusive; leaf #0 and its parent #2 are full)', setup: [8, 9], a: ['put', 2], others: [['get', 25, 'under #6']] }
    ];
    var s3 = '';
    SCENARIOS.forEach(function (sc) {
      s3 += sc.title + '\n  ' + pad('B', 22) + ' global mutex    global rwlock   latch coupling\n';
      sc.others.forEach(function (o) {
        s3 += '  ' + pad(o[0] + ' ' + o[1] + ' (' + o[2] + ')', 22);
        THREE.forEach(function (p) {
          var tree = Tree.build(64, Ch19.CANONICAL.concat(sc.setup));
          var out = Sim.probe(tree, p, { kind: sc.a[0], key: sc.a[1] }, { kind: o[0], key: o[1] }, 'atLeaf').outcome;
          s3 += ' ' + (p === 'coupling' ? out : pad(out, 15));
        });
        s3 += '\n';
      });
    });
    BTViz.selfTest('3 probes', s3, sections['3'], '#selftests');

    // Section 4: the root is replaced under a reader.
    var t4 = Tree.build(16, [10, 20, 5]);
    var s4 = 'before: ' + t4.dump() + 'reader of 20 has read root = #0 and holds no latch yet; now put 6 splits the root\n';
    var p4 = Sim.probe(t4, 'coupling', { kind: 'get', key: 20 }, { kind: 'put', key: 6 }, 'afterRootLoad');
    var r4 = p4.sim.threads.T1;
    s4 += 'after:  ' + t4.dump() + 'reader latched #0, saw root = #' + t4.root + ', restarted ' + r4.restarts + ' time(s): get 20 = ' + (r4.result === 'found' ? 2000 : 'null') + '\n';
    BTViz.selfTest('4 root', s4, sections['4'], '#selftests');

    // Section 5: a table of 7 nodes.
    var s5 = '';
    THREE.forEach(function (p) {
      var tree = new Tree(7);
      Ch19.CANONICAL.some(function (key) {
        var before = tree.dump(), used = tree.nodes.length, r = putVia(tree, p, key);
        if (r.result !== 'OutOfNodes') return false;
        s5 += pad(NAME[p], 14) + ' put ' + key + ': OutOfNodes; nodes used ' + used + ' -> ' + tree.nodes.length + ' of 7; tree unchanged: ' +
          (tree.dump() === before ? 'yes' : 'NO') + '; locks still held: ' + (r.locksLeft === 0 ? 'none' : 'SOME') + '\n';
        return true;
      });
    });
    BTViz.selfTest('5 full table', s5, sections['5'], '#selftests');

    // Section 7: four threads, a convoy behind the frozen put 26.
    var OTHERS = [['get', 17, 'under #6'], ['get', 12, 'under #2'], ['put', 11, 'under #2']];
    var t7 = Tree.build(64, Ch19.CANONICAL);
    var c7 = Sim.convoy(t7, 'coupling', { kind: 'put', key: 26 }, OTHERS.map(function (o) { return { kind: o[0], key: o[1] }; }), 'atLeaf');
    var s7 = '';
    OTHERS.forEach(function (o, i) { s7 += '  ' + 'BCD'.charAt(i) + ' = ' + pad(o[0] + ' ' + o[1] + ' (' + o[2] + ')', 18) + ' ' + c7.outcomes[i] + '\n'; });
    s7 += 'D needs nothing that A holds. It waits for the shared latch B keeps on the root #7 while B itself waits at #6.\n';
    var left7 = 0;
    c7.sim.order.forEach(function (tid) { left7 += c7.sim.held(tid).length; });
    s7 += 'after A is released: get 26 = ' + (t7.has(26) ? 2600 : 'null') + ', get 11 = ' + (t7.has(11) ? 1100 : 'null') + ', valid=yes, latches still held: ' + (left7 === 0 ? 'none' : 'SOME') + '\n';
    BTViz.selfTest('7 convoy', s7, sections['7'], '#selftests');
  })();
})();
