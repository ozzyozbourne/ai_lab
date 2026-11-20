/* Chapter 21 visualization: wiring. Model: model.js. View: local.js. Snippets: code.js. */
(function () {
  'use strict';
  var el = BTViz.el, M = window.Ch21;
  var LEGEND = [
    { token: 'page-dirty', label: 'pending sector (not durable)' },
    { token: 'pointer', label: 'durable sector' },
    { token: 'key-inserted', label: 'new sector in a torn page' },
    { token: 'key-found', label: 'checksum ok' },
    { token: 'key-deleted', label: 'checksum mismatch' },
    { token: 'free', label: 'never written' }
  ];

  BTViz.page({
    title: 'Durability primitives', chapter: 21,
    prev: { href: '../../20-blink-trees/viz/index.html', title: 'Chapter 20: B-link trees' },
    next: { href: '../../22-wal-and-crash-recovery/viz/index.html', title: 'Chapter 22: WAL and crash recovery' }
  });

  function sectorList(mask) {
    var on = [];
    for (var s = 0; s < M.SECTORS; s++) if (mask & (1 << s)) on.push(s);
    return on.join(', ');
  }

  /* ------------------------------------------------------------ 1. guided */
  function guidedSteps() {
    var steps = [], disk = new M.SimDisk(2121), labels = {};
    function push(caption, lines, hl, question) {
      steps.push({ caption: caption, state: M.snapshot(disk), hl: hl || {}, lines: lines || [], labels: labels, question: question });
    }
    var A0 = M.sealedPage('A', 0), B0 = M.sealedPage('B', 0);

    push('<b>Experiment 1.</b> An empty simulated disk. Left: writes the process has issued but not synced. Right: what is really on the disk.');
    disk.writePage(0, A0);
    push('<code>writePage(0, A)</code>: the page is copied into the pending list. The disk itself has not changed.', [[2, 6]]);
    push('<code>readPage(0)</code> returns <code>AAAAAAAA</code>, checksum ok. The <em>cache</em> answered. Reading back what you wrote proves nothing about the disk.',
      [], { read: { side: 'pending', page: 0 } });
    disk.crash('drop');
    push('<code>crash(drop)</code>: the power fails and the cache is gone. Page 0 never existed; a read now fails with "out of bounds". Nothing was promised, so nothing was broken.',
      [[13, 15]], {}, {
        prompt: 'The power fails now, before any sync, in mode <code>drop</code>. What is on the disk afterwards?',
        choices: ['Page 0 with version A', 'Nothing: the disk is still empty', 'Half of page 0'],
        answer: 1,
        explain: 'With mode <code>drop</code> every pending write is lost. (The other modes keep or tear it: an unsynced write can end up in any of the three states, and you do not get to choose.)'
      });
    disk.writePage(0, A0);
    push('Write A again…', [[2, 6]]);
    disk.sync();
    push('…and <code>sync()</code>: every pending write is applied to the disk, all eight sectors, and the pending list is emptied. Only now is A durable.',
      [[8, 11]], { touched: { 0: true } });
    disk.crash('drop');
    push('<code>crash(drop)</code> again: nothing was pending, so nothing is lost. Page 0 still verifies.', [[13, 15]], { read: { side: 'durable', page: 0 } });

    disk.writePage(0, B0);
    push('<b>Experiment 2.</b> Overwrite page 0 with version B and do <em>not</em> sync. Reads already return B, the disk still holds A.',
      [[2, 6]], { read: { side: 'pending', page: 0 } });
    disk.crash('tear');
    var mask = disk.lastMasks[0].mask, snap = M.snapshot(disk).durable[0];
    push('<code>crash(tear)</code>: the drive had written only sectors ' + sectorList(mask) + ' when the power failed. The page is now <code>' + snap.map +
      '</code>. Its last four bytes hold B\'s checksum <code>' + snap.stored + '</code>, but the bytes actually there hash to <code>' + snap.computed +
      '</code>: <b>corrupt</b>. The checksum detects the damage; it cannot say which sectors to trust, and neither A nor B can be rebuilt.',
      [17, [23, 25]], { touched: { 0: true } }, {
        prompt: 'The power fails during the unsynced overwrite, in mode <code>tear</code>. What will a reader find on page 0?',
        choices: ['The old page A, intact', 'The new page B, intact', 'A mix of A and B sectors that fails its checksum'],
        answer: 2,
        explain: 'A tear writes between 1 and 7 of the 8 sectors. A and B differ in every sector, so every mix fails the checksum.'
      });
    var tornState = snap.map + ' ' + snap.check;

    disk = new M.SimDisk(2121);
    labels = { 0: 'slot', 1: 'home' };
    var dw = new M.DoubleWrite(disk, 1);
    push('<b>Experiment 4: double write.</b> A fresh disk with the same seed. The logical page now has two locations: a <em>slot</em> (page 0) and its <em>home</em> (page 1). Rule: the two copies are never both in flight (written but not yet synced) at the same time.');
    dw.update(0, M.filled('A'));
    push('<code>update(A)</code> ran to completion: write slot, sync, write home, sync. Both copies hold A, each sealed for its own address. Cost: 2 writes and 2 syncs instead of 1 and 1.',
      [[30, 35]], { touched: { 0: true, 1: true } });

    var B = M.filled('B');
    M.seal(B, 0);
    disk.writePage(0, B);
    push('<code>update(B)</code>, step 1: write B to the <em>slot</em>. Home is untouched and still a perfect A, whatever happens to this write.', [30, 31]);
    disk.sync();
    push('Sync. The slot now holds a complete, durable B. This sync is the whole trick: home must not be touched before it returns.', [32], { touched: { 0: true } });
    M.seal(B, 1);
    disk.writePage(1, B);
    push('Step 2: write B to <em>home</em>. The final sync has not happened yet…', [33, 34]);
    disk.crash('tear');
    mask = disk.lastMasks[0].mask;
    push('…and the power fails: <code>crash(tear)</code>. Home was being written and is torn (sectors ' + sectorList(mask) + ' are new): corrupt. In experiment 2 this was the end. Here the slot is intact.',
      [17, [23, 25]], { touched: { 1: true } }, {
        prompt: 'The power fails while home is being overwritten. Home will be torn. Is the page lost?',
        choices: ['Yes: a torn page cannot be repaired', 'No: the slot holds a complete copy of B', 'No: the old version A is still in home'],
        answer: 1,
        explain: 'The slot was synced before home was touched, so exactly one complete copy of the new version is guaranteed to exist.'
      });
    var rep = dw.recover({ noSync: true });
    push('<code>recover()</code>: the slot\'s checksum is ok, home\'s is not, so copy the slot over home (restored=' + rep.restored + '). If this write tore as well, the slot would still be there for the next attempt.',
      [[39, 41]], { read: { side: 'durable', page: 0 } });
    disk.sync();
    push('Sync. Home is a clean B again. After recovery the page is always entirely old or entirely new: one page write has become atomic. Chapter 22 gets the same guarantee for many pages at once from a log.',
      [45], { touched: { 1: true } });

    var fin = M.snapshot(disk).durable;
    return { steps: steps, torn: tornState, final: fin.map(function (p) { return 'page ' + p.page + ' -> ' + p.map + ' ' + p.check; }) };
  }

  var guided = guidedSteps();
  (function () {
    var fig = BTViz.figure('#fig-guided', { title: 'Pending vs durable, with the chapter\'s crashes', side: true, legend: LEGEND });
    var view = new window.Ch21DiskView(fig.stage, {});
    var code = BTViz.codePanel(fig.side, 'durability', { title: 'The code that runs', maxHeight: 330 });
    new BTViz.Stepper({
      mount: fig.controls, caption: fig.caption, root: fig.root, steps: guided.steps, predict: false, interval: 2600,
      onStep: function (step) {
        view.opts.labels = step.labels;
        view.render(step.state, step.hl);
        code.highlight(step.lines);
      }
    });
  })();

  /* ------------------------------------------------------------ 2. sandbox */
  (function () {
    var fig = BTViz.figure('#fig-sandbox', { title: 'Sandbox: lose a page if you can', legend: LEGEND });
    var view = new window.Ch21DiskView(fig.stage, {});
    var disk, steps, letterIx, protocol;

    var selProto = el('select.bt-select#sb-protocol', { 'aria-label': 'Protocol' },
      el('option', { value: 'inplace' }, 'in place'), el('option', { value: 'double' }, 'double write'));
    var selMode = el('select.bt-select#sb-mode', { 'aria-label': 'Crash mode' });
    ['tear', 'drop', 'keep', 'random'].forEach(function (m) { selMode.appendChild(el('option', { value: m }, m)); });
    var seed = el('input.bt-input#sb-seed', { type: 'number', inputmode: 'numeric', min: 0, max: 999999, value: 2121, 'aria-label': 'Seed', style: { width: '5.5em' } });
    var nextChip = el('span.bt-chip#sb-next');
    // No action may fail silently: an exception becomes a step with its message.
    function guard(fn) {
      return function () {
        try { fn(); } catch (e) {
          record('<b>That action failed:</b> ' + BTViz.esc(e && e.message ? e.name + ': ' + e.message : String(e)) + '. Press Reset to start again.');
        }
      };
    }
    function btn(id, text, fn, primary) { return el('button.bt-btn' + (primary ? '.bt-primary' : '') + '#' + id, { type: 'button', onclick: guard(fn) }, text); }
    var bSlot = btn('sb-slot', 'Write slot', function () { write(0, false); });
    var bHome = btn('sb-home', 'Write home', function () { write(homeNo(), true); }, true);
    var bSync = btn('sb-sync', 'Sync', sync);
    var bCrash = btn('sb-crash', 'Crash', crash);
    var bRecover = btn('sb-recover', 'Recover', recover);
    fig.toolbar.append(
      el('label.bt-field', 'Protocol', selProto), nextChip, el('span.bt-toolbar-sep'),
      bSlot, bHome, bSync, el('span.bt-toolbar-sep'),
      el('label.bt-field', 'Power cut', selMode), bCrash, bRecover, el('span.bt-toolbar-sep'),
      el('label.bt-field', 'Seed', seed), btn('sb-reset', 'Reset', reset));

    var stepper = new BTViz.Stepper({
      mount: fig.controls, caption: fig.caption, root: fig.root, interval: 1600,
      onStep: function (step) { view.opts.labels = step.labels; view.render(step.state, step.hl); }
    });

    function homeNo() { return protocol === 'double' ? 1 : 0; }
    function letter() { return String.fromCharCode(65 + letterIx % 26); }
    function labels() { return protocol === 'double' ? { 0: 'slot', 1: 'home' } : { 0: 'home' }; }
    function record(caption, hl) {
      steps.push({ caption: caption, state: M.snapshot(disk), hl: hl || {}, labels: labels() });
      stepper.setSteps(steps, { index: steps.length - 1, instant: true });
      nextChip.textContent = 'next version: ' + letter();
    }
    function reset() {
      protocol = selProto.value;
      var s = Math.max(0, Math.min(999999, Math.floor(+seed.value || 0)));
      seed.value = s;
      disk = new M.SimDisk(s);
      steps = [];
      letterIx = 0;
      bSlot.style.display = bRecover.style.display = protocol === 'double' ? '' : 'none';
      record(protocol === 'double'
        ? 'Double write, seed ' + s + '. Protocol for one update: <b>Write slot → Sync → Write home → Sync</b>. After a crash press <b>Recover</b>. Then try breaking the rule: write slot and home without a sync in between, and crash.'
        : 'In place, seed ' + s + '. One page, one location. <b>Write home</b> then <b>Sync</b> to store version A; then write B and press <b>Crash</b> before syncing.');
    }
    function write(pageNo, advance) {
      var l = letter(), page = M.sealedPage(l, pageNo);
      disk.writePage(pageNo, page);
      if (advance) letterIx++;
      var name = (labels()[pageNo] || 'page') + ' (page ' + pageNo + ')';
      record('Wrote version ' + l + ' to ' + name + '. It is pending: reads see it, a crash may drop, keep or tear it.');
    }
    function sync() {
      var n = disk.pending.length, touched = {};
      disk.pending.forEach(function (w) { touched[w.pageNo] = true; });
      disk.sync();
      record(n ? 'Sync: ' + n + ' pending write' + (n > 1 ? 's are' : ' is') + ' now durable.' : 'Sync with nothing pending: nothing to do.', { touched: touched });
    }
    function crash() {
      var mode = selMode.value, n = disk.pending.length;
      var r = disk.crash(mode), touched = {};
      var parts = disk.lastMasks.map(function (m) {
        touched[m.pageNo] = true;
        return 'page ' + m.pageNo + ' ' + (m.fate === 'tear' ? 'torn (sectors ' + sectorList(m.mask) + ' written)' : m.fate === 'keep' ? 'kept' : 'dropped');
      });
      var bad = M.snapshot(disk).durable.filter(function (p) { return p.check === 'corrupt'; }).length;
      record('crash(' + mode + '): ' + (n ? parts.join('; ') + '.' : 'nothing was pending, nothing is lost.') +
        ' dropped=' + r.dropped + ' kept=' + r.kept + ' torn=' + r.torn + '. ' +
        (bad ? '<b>' + bad + ' page' + (bad > 1 ? 's fail' : ' fails') + ' the checksum.</b>' + (protocol === 'double' ? ' Press Recover.' : ' In place there is no second copy: the page is lost.') : 'Every page on disk verifies.'),
        { touched: touched });
    }
    function recover() {
      var dw = new M.DoubleWrite(disk, 1);
      var r = dw.recover();
      var msg = r.unrecoverable ? '<b>Unrecoverable:</b> slot and home are both damaged. This can only happen when both copies were in flight at once, i.e. the sync between the two writes was skipped.'
        : r.restored ? 'Recover: the slot verifies and home does not, so home was rebuilt from the slot and synced.'
        : r.rolled_forward ? 'Recover: both verify but the slot is newer. The update had stopped between its two steps; it is now finished (home := slot).'
        : r.blank ? 'Recover: neither copy was ever written. Nothing to do.'
        : 'Recover: home verifies and the slot is not a newer complete copy (same version, or a torn or dropped slot write). Home is kept as it is.';
      record(msg, { touched: { 1: true } });
    }
    selProto.addEventListener('change', reset);
    seed.addEventListener('change', reset);
    reset();
  })();

  /* ------------------------------------------------------------ 3. self-tests */
  // Runs ~2000 simulated crashes; defer it so the page paints first.
  setTimeout(function () {
    var out = M.runProgram();
    document.getElementById('program-output').textContent = out;
    BTViz.selfTest('program output = expected_output.txt', out, window.CH21_EXPECTED_OUTPUT, '#selftests');
    var want = /== 2\.[\s\S]*?crash\(tear\)[^\n]*\nread {2}page 0 -> (\S+ \S+)/.exec(window.CH21_EXPECTED_OUTPUT)[1];
    BTViz.selfTest('guided torn page = ' + want, guided.torn, want, '#selftests');
    BTViz.selfTest('guided final state', guided.final, ['page 0 -> BBBBBBBB ok', 'page 1 -> BBBBBBBB ok'], '#selftests');
    BTViz.selfTest('storage contract: holes, bounds, power loss', M.contractChecks(), M.CONTRACT_EXPECTED, '#selftests');
    document.documentElement.setAttribute('data-selftests', 'done');
  }, 30);
})();
