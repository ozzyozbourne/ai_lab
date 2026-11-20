#!/usr/bin/env node
/* Self-test for the BTViz reference models. Run: node assets/selftest.js  (exits 0 on success) */
'use strict';
const BTViz = require('./viz.js');
const { BTree, BPlusTree, SlottedPage } = BTViz.models;
let checks = 0;
function fail(msg) { console.error('FAIL: ' + msg); process.exit(1); }
function ok(cond, msg) { checks++; if (!cond) fail(msg); }
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

/* ---- 1. randomized insert / delete / search against a sorted-array oracle ---- */
function fuzz(Tree, order, seed, ops, keyRange, opts) {
  const r = BTViz.rng(seed), t = Tree(order, opts), oracle = [];
  const tag = `${t.kind}${opts ? ' ' + JSON.stringify(opts) : ''} order=${order} seed=${seed}`;
  for (let i = 0; i < ops; i++) {
    const key = r.int(0, keyRange), at = oracle.indexOf(key);
    // phases: grow, churn, shrink to empty, regrow
    const phase = i / ops, pIns = phase < 0.35 ? 0.75 : phase < 0.6 ? 0.5 : phase < 0.85 ? 0.15 : 0.7;
    const record = i % 7 === 0;                       // exercise both recording modes
    const x = r();
    let steps;
    if (x < 0.1) {
      steps = t.search(key, { steps: record });
      ok(steps.found === (at >= 0), `${tag} op ${i}: search(${key}) found=${steps.found}`);
    } else if (x < 0.1 + 0.9 * pIns) {
      steps = t.insert(key, { steps: record });
      ok(steps.ok === (at < 0), `${tag} op ${i}: insert(${key}) ok=${steps.ok}`);
      if (at < 0) { oracle.push(key); oracle.sort((a, b) => a - b); }
    } else {
      steps = t.delete(key, { steps: record });
      ok(steps.ok === (at >= 0), `${tag} op ${i}: delete(${key}) ok=${steps.ok}`);
      if (at >= 0) oracle.splice(at, 1);
    }
    const errs = t.validate();
    ok(errs.length === 0, `${tag} op ${i} (key ${key}): invariants broken: ${errs.join('; ')}`);
    ok(t.size === oracle.length && same(t.keys(), oracle), `${tag} op ${i}: contents differ from oracle`);
    if (record) {
      ok(steps.length >= 2, `${tag} op ${i}: expected recorded steps`);
      ok(same(steps[steps.length - 1].state, t.snapshot()), `${tag} op ${i}: last step state != final snapshot`);
      for (const s of steps) {
        ok(typeof s.caption === 'string' && s.caption.length > 0 && s.state && s.highlight && s.type, `${tag} op ${i}: malformed step`);
        const ids = new Set();
        (function walk(n) { ok(!ids.has(n.id), `${tag}: duplicate id in snapshot`); ids.add(n.id); n.children.forEach(walk); })(s.state);
        for (const id of Object.keys(s.highlight.nodes || {})) ok(ids.has(id), `${tag} op ${i} step ${s.type}: highlight for missing node ${id}`);
        if (s.highlight.cursor) ok(ids.has(s.highlight.cursor.node), `${tag} op ${i}: cursor on missing node`);
        BTViz.TreeView.layout(s.state);               // layout must not throw on any intermediate state
      }
    } else ok(steps.length === 0, `${tag} op ${i}: steps recorded although disabled`);
  }
  // drain completely: must end as a single empty leaf
  for (const key of r.shuffle(oracle)) { ok(t.delete(key, { steps: false }).ok, `${tag}: drain delete ${key}`); ok(t.validate().length === 0, `${tag}: invariants during drain`); }
  ok(t.size === 0 && t.root.leaf && t.root.keys.length === 0 && t.height() === 1, `${tag}: not empty after drain`);
}
let total = 0;
for (const Tree of [BTree, BPlusTree]) {
  for (const order of [3, 4, 5, 6, 7, 8, 16]) {
    for (const seed of [1, 2, 3]) { fuzz(Tree, order, seed * 100 + order, 2500, order < 6 ? 120 : 400); total += 2500; }
  }
}
// same fuzz with the guide's B+tree convention (PLAN.md / chapter 07)
for (const order of [3, 4, 5, 6, 7, 8, 16]) {
  for (const seed of [1, 2, 3]) { fuzz(BPlusTree, order, seed * 100 + order, 2500, order < 6 ? 120 : 400, { convention: 'guide' }); total += 2500; }
}

/* ---- 2. conventions: order M = max children, default 4, B+ separators are copies ---- */
ok(BTree().order === 4 && BPlusTree().order === 4, 'default order must be 4');
ok(same(BTree(4).limits(), { maxKeys: 3, minLeafKeys: 1, minInternalKeys: 1, maxChildren: 4 }), 'BTree(4) limits');
ok(same(BTree(5).limits(), { maxKeys: 4, minLeafKeys: 2, minInternalKeys: 2, maxChildren: 5 }), 'BTree(5) limits');
{
  const t = BTree(4).insertMany([10, 20, 30, 40]);
  ok(same(t.snapshot().keys, [30]) && same(t.snapshot().children.map(c => c.keys), [[10, 20], [40]]), 'BTree(4) first split shape: ' + JSON.stringify(t.snapshot()));
  const p = BPlusTree(4).insertMany([10, 20, 30, 40]);
  ok(same(p.snapshot().keys, [30]) && same(p.snapshot().children.map(c => c.keys), [[10, 20], [30, 40]]), 'B+tree separator must be a copy of the right leaf\'s first key');
  ok(p.snapshot().children[0].next === p.snapshot().children[1].id && p.snapshot().children[1].next === null, 'B+tree leaf chain');
  const types = BTree(4).insertMany([10, 20, 30]).insert(40).map(s => s.type);
  for (const want of ['start', 'compare', 'insert-leaf', 'overflow', 'root-grow', 'done']) ok(types.includes(want), 'insert steps should include ' + want + ': ' + types);
  const sc = BPlusTree(4).insertMany([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]).scan(3, 8);
  ok(same(sc.result, [3, 4, 5, 6, 7, 8]), 'scan result ' + sc.result);
  const seen = new Set();
  for (const seed of [5, 6, 7]) {
    const big = BTree(4).insertMany(BTViz.rng(seed).sample(40, 1, 99));
    for (const key of BTViz.rng(seed).shuffle(big.keys())) for (const s of big.delete(key)) seen.add(s.type);
  }
  for (const want of ['remove', 'found-internal', 'predecessor', 'replace', 'underflow', 'borrow-left', 'borrow-right', 'merge', 'root-shrink']) ok(seen.has(want), 'delete steps never produced ' + want);
  let threw = false; try { BTree(2); } catch (e) { threw = true; } ok(threw, 'order 2 must be rejected');
  const s = BTree(4, { detail: 'key' }).insertMany([1, 2, 3]).search(3);
  ok(s.filter(x => x.type === 'compare-key').length === 3, 'detail:"key" emits one step per comparison');
}

/* ---- 2b. {convention: 'guide'}: the B+tree of PLAN.md and chapter 07 ---- */
{
  const G = { convention: 'guide' };
  const shape = n => n.leaf ? n.keys : { k: n.keys, c: n.children.map(shape) };
  // every non-root node, leaves included, holds at least ceil(M/2) - 1 keys
  for (const m of [3, 4, 5, 6, 7, 8, 16]) {
    const min = Math.ceil(m / 2) - 1;
    ok(same(BPlusTree(m, G).limits(), { maxKeys: m - 1, minLeafKeys: min, minInternalKeys: min, maxChildren: m }), `guide B+tree(${m}) limits`);
    // leaf split: the left leaf keeps the lower floor(M/2) keys, the separator is a copy of the right leaf's first key
    const keys = []; for (let i = 1; i <= m; i++) keys.push(i * 10);
    const s = BPlusTree(m, G).insertMany(keys).snapshot(), half = Math.floor(m / 2);
    ok(same(s.children.map(c => c.keys), [keys.slice(0, half), keys.slice(half)]) && same(s.keys, [keys[half]]), `guide B+tree(${m}) first leaf split: ${JSON.stringify(s)}`);
  }
  // the default convention is unchanged
  ok(same(BPlusTree(4).limits(), { maxKeys: 3, minLeafKeys: 2, minInternalKeys: 1, maxChildren: 4 }), 'default B+tree(4) limits must not change');
  ok(same(BPlusTree(5).insertMany([1, 2, 3, 4, 5]).snapshot().children.map(c => c.keys), [[1, 2, 3], [4, 5]]), 'default B+tree(5) split point must not change');
  ok(BPlusTree(4).convention === 'default' && BPlusTree(4, G).convention === 'guide' && same(BTree(4, G).limits(), BTree(4).limits()), 'convention property');
  // canonical hand example, M = 4: the shapes printed by chapters/07-bplus-trees (zig/src, viz/local.js)
  const t = BPlusTree(4, G).insertMany([10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15]);
  ok(same(shape(t.root), { k: [15], c: [{ k: [6, 10], c: [[1, 3, 5], [6, 7], [10, 12]] }, { k: [20], c: [[15, 17], [20, 25, 30]] }] }), 'guide canonical insert shape: ' + JSON.stringify(shape(t.root)));
  // a key equal to a separator goes right
  ok(t.search(15).found && t.search(15).filter(x => x.type === 'compare').length === 2 && t.insert(15).ok === false, 'guide: key equal to a separator is found in the right subtree');
  for (const key of [15, 17, 20, 25, 30, 12]) ok(t.delete(key).ok, 'guide canonical delete ' + key);
  ok(same(shape(t.root), { k: [6, 10], c: [[1, 3, 5], [6, 7], [10]] }) && t.validate().length === 0, 'guide canonical delete shape: ' + JSON.stringify(shape(t.root)));
  // a one-key leaf is legal under the guide's minimum for M = 4 and illegal under the default one
  const d = BPlusTree(4).insertMany([1, 3, 5, 6, 7, 10]);
  d.root.children[d.root.children.length - 1].keys.length = 1; d.size = d.keys().length;
  ok(d.validate().length > 0, 'default convention rejects a one-key leaf at M = 4');
}

/* ---- 3. slotted page against an oracle ---- */
for (const seed of [1, 2, 3, 4]) {
  const r = BTViz.rng(seed), pg = SlottedPage({ size: 160 }), oracle = new Map();
  for (let i = 0; i < 3000; i++) {
    const key = r.int(1, 40), rec = i % 5 === 0;
    if (r() < 0.55) {
      const len = r.int(3, 20), before = pg.freeSpace().total;
      const st = pg.insert(key, len, null, { steps: rec });
      const expect = !oracle.has(key) && len + 2 <= before;
      ok(st.ok === expect, `page seed ${seed} op ${i}: insert(${key}, ${len}) ok=${st.ok}, expected ${expect}`);
      if (st.ok) oracle.set(key, len);
      if (rec && st.length) ok(same(st[st.length - 1].state, pg.snapshot()), 'page: last step != snapshot');
    } else if (r() < 0.9) {
      ok(pg.delete(key, { steps: rec }).ok === oracle.has(key), `page seed ${seed} op ${i}: delete(${key})`);
      oracle.delete(key);
    } else { pg.defragment({ steps: rec }); ok(pg.deadBytes() === 0, 'defragment leaves dead bytes'); }
    const errs = pg.validate();
    ok(errs.length === 0, `page seed ${seed} op ${i}: ${errs.join('; ')}`);
    ok(same(pg.keys(), [...oracle.keys()].sort((a, b) => a - b)), `page seed ${seed} op ${i}: keys differ`);
    let used = 0; oracle.forEach(l => { used += l + 2; });
    ok(pg.freeSpace().total === 160 - 8 - used, `page seed ${seed} op ${i}: free space accounting`);
  }
}

/* ---- 4. Stepper snapshots (headless), binary search steps, layout, rng ---- */
{
  const seenStates = [];
  const st = new BTViz.Stepper({
    initialState: { n: 0, log: [] },
    steps: [
      { caption: 'a', apply(s) { s.n += 1; s.log.push('a'); } },
      { caption: 'b', apply(s) { return { n: s.n * 10, log: s.log.concat('b') }; } },
      { caption: 'c', state: { n: 99, log: ['x'] } },
      { caption: 'd', apply(s) { s.n += 1; } }
    ],
    onStep(step, i) { seenStates.push([i, JSON.stringify(step.state)]); }
  });
  st.next(); st.next(); st.next(); st.prev(); st.prev(); st.prev(); st.go(3); st.go(1);
  const want = { 0: '{"n":1,"log":["a"]}', 1: '{"n":10,"log":["a","b"]}', 2: '{"n":99,"log":["x"]}', 3: '{"n":100,"log":["x"]}' };
  ok(seenStates.length === 9 && seenStates.every(([i, s]) => s === want[i]), 'Stepper snapshots must be stable when stepping back: ' + JSON.stringify(seenStates));
  ok(st.index === 1 && same(st.state(0), { n: 1, log: ['a'] }), 'Stepper.state()');

  const r = BTViz.rng(9);
  for (let i = 0; i < 300; i++) {
    const vals = r.sample(r.int(0, 20), 0, 50).sort((a, b) => a - b), target = r.int(-1, 52);
    const bs = BTViz.steps.binarySearch(vals, target);
    let idx = vals.findIndex(v => v >= target); if (idx < 0) idx = vals.length;
    ok(bs.index === idx && bs.found === vals.includes(target), `binarySearch(${vals}, ${target}) → ${bs.index}`);
  }
  ok(same(BTViz.rng(42).sample(5, 1, 99), BTViz.rng(42).sample(5, 1, 99)) && BTViz.rng('a')() !== BTViz.rng('b')(), 'rng determinism');

  // layout: no two nodes on the same level may overlap; parents sit above their children
  for (const seed of [1, 2, 3, 4, 5]) {
    const t = (seed % 2 ? BTree : BPlusTree)(3 + seed).insertMany(BTViz.rng(seed).sample(150, 1, 9999));
    const L = BTViz.TreeView.layout(t.snapshot());
    const rows = {};
    L.order.forEach(n => { (rows[n.depth] = rows[n.depth] || []).push(n); });
    Object.values(rows).forEach(row => {
      row.sort((a, b) => a.x - b.x);
      for (let i = 1; i < row.length; i++) ok(row[i].x >= row[i - 1].x + row[i - 1].w + 4, 'layout overlap on level ' + row[i].depth);
      ok(row[0].x >= 0 && row[row.length - 1].x + row[row.length - 1].w <= L.width, 'layout exceeds canvas');
    });
    ok(L.edges.length === L.order.length - 1, 'tree layout edge count');
  }
  // DAG / forest: shared child gets one box and two edges
  const shared = { id: 'L2', keys: [5, 6], leaf: true, children: [] };
  const dag = BTViz.TreeView.layout([
    { id: 'r1', keys: [5], children: [{ id: 'L1', keys: [1], leaf: true, children: [] }, shared] },
    { id: 'r2', keys: [5], children: [{ id: 'L1b', keys: [1, 2], leaf: true, children: [] }, { ref: 'L2' }] }
  ]);
  ok(dag.order.length === 5 && dag.edges.length === 4 && dag.edges.filter(e => e.child === 'L2').length === 2, 'DAG layout');
  // binary trees: an only child with a side hint (or opts.binary) is not centred under its parent
  {
    const mid = n => n.x + n.w / 2, leafL = { id: 'c', keys: [1], leaf: true, children: [] };
    const plain = BTViz.TreeView.layout({ id: 'p', keys: [5], children: [leafL] });
    ok(mid(plain.nodes.get('c')) === mid(plain.nodes.get('p')), 'only child without a hint stays centred (default unchanged)');
    const L1 = BTViz.TreeView.layout({ id: 'p', keys: [5], children: [Object.assign({ side: 'left' }, leafL)] });
    const R1 = BTViz.TreeView.layout({ id: 'p', keys: [5], children: [Object.assign({ side: 'right' }, leafL)] });
    ok(mid(L1.nodes.get('c')) < mid(L1.nodes.get('p')) && mid(R1.nodes.get('c')) > mid(R1.nodes.get('p')), 'side hint moves an only child off-centre');
    ok(L1.edges[0].ci === 0 && R1.edges[0].ci === 1, 'side hint picks the edge anchor');
    const B = BTViz.TreeView.layout({ id: 'p', keys: [5], children: [null, { id: 'r', keys: [8], children: [{ id: 'rl', keys: [6], children: [] }, null] }] }, { binary: true });
    ok(mid(B.nodes.get('r')) > mid(B.nodes.get('p')) && mid(B.nodes.get('rl')) < mid(B.nodes.get('r')) && B.order.length === 3 && B.edges.length === 2, 'binary: true places [null, right] and [left, null]');
    B.order.forEach(n => ok(n.x >= 0 && n.x + n.w <= B.width, 'binary layout exceeds canvas'));
  }
  // Stepper (headless): restart() forgets answered predict questions, like setSteps()
  {
    const st = new BTViz.Stepper({ steps: [{ state: 0 }, { state: 1, question: { prompt: '?', choices: ['a'], answer: 0 } }, { state: 2 }] });
    st.go(2); st._answered[1] = true; st.restart();
    ok(st.index === 0 && Object.keys(st._answered).length === 0, 'Stepper.restart() clears the answered set');
  }
  ok(BTViz.selfTest('selftest-internal', { b: 1, a: [1, 2] }, { a: [1, 2], b: 1 }) === true && BTViz.selfTest.results.length === 1, 'selfTest structural equality');
}

console.log(`BTViz self-test OK — ${total} random tree operations (B-tree + B+tree + guide-convention B+tree, orders 3–16), 12000 slotted-page operations, ${checks} checks passed.`);
