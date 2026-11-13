/* ch05-gen-handles — a generational pool: slots with generation counters, an in-array free list,
 * and handles (index, generation) that go stale when their slot is freed or reused.
 * <div class="figure-body" data-viz="ch05-gen-handles" data-opts='{}'></div>
 * Options:
 *   slots     max slots 4..8 (default 8)
 *   interval  seconds per step while playing (default 0.9)
 * Model: the state is a replay of an operation log (insert / remove / deref). The player steps through a
 * scripted story; the Insert / Remove / Deref buttons append operations at the current position, so Back
 * and Reset work for both. Free list is LIFO (push on remove, pop on insert), as in the chapter's code.
 * Every number on screen is computed by replaying the log. */
(window.BookQ ||= []).push((B) => B.viz.register("ch05-gen-handles", (root, opts) => {
  const { h, viz } = B;
  const KNOWN = ["slots", "interval"];
  for (const k of Object.keys(opts)) viz.check(KNOWN.includes(k), `ch05-gen-handles: unknown option "${k}" (known: ${KNOWN.join(", ")})`);
  const MAX = opts.slots ?? 8;
  viz.check(Number.isInteger(MAX) && MAX >= 4 && MAX <= 8, 'ch05-gen-handles: "slots" must be an integer 4..8');
  const NAMES = ["orc", "elf", "imp", "bat", "rat", "ant", "owl", "yak", "elk", "emu", "gnu", "cat", "dog", "fox", "hen", "pig"];
  const STORY = [
    { t: "ins", name: "orc" }, { t: "ins", name: "elf" }, { t: "ins", name: "imp" },
    { t: "get", ref: "orc" }, { t: "rem", ref: "orc" }, { t: "rem", ref: "imp" },
    { t: "get", ref: "orc" }, { t: "ins", name: "bat" }, { t: "ins", name: "rat" },
    { t: "get", ref: "orc" }, { t: "get", ref: "rat" },
  ];
  let ops = STORY.slice(), k = 0, selected = null;

  // ---- the model: replay ops[0..k) ----
  function replay(n) {
    const slots = [], handles = [];
    let head = -1, caught = 0, checks = 0, last = null;
    const find = (name) => handles.find((x) => x.name === name);
    for (let i = 0; i < n; i++) {
      const op = ops[i];
      if (op.t === "ins") {
        let index, reused = head >= 0;
        if (reused) { index = head; head = slots[index].next; slots[index].val = op.name; slots[index].next = null; }
        else { index = slots.length; slots.push({ gen: 1, val: op.name, next: null }); }
        const hd = { name: op.name, index, gen: slots[index].gen };
        handles.push(hd);
        last = { op, kind: "ins", index, text: `insert ${op.name} → handle ${index}v${hd.gen} (${reused ? "popped slot " + index + " off the free list" : "appended slot " + index})` };
      } else {
        const hd = find(op.ref), s = slots[hd.index];
        const valid = s && s.val !== null && s.gen === hd.gen;
        checks++;
        if (!valid) caught++;
        const why = !s ? "no such slot" : s.val === null ? `slot ${hd.index} is free (gen ${s.gen}), handle has gen ${hd.gen}`
          : `slot ${hd.index} has gen ${s.gen}, handle has gen ${hd.gen}`;
        if (op.t === "get") {
          last = valid ? { op, kind: "ok", index: hd.index, text: `deref ${hd.name} ${hd.index}v${hd.gen} → ${s.val}: generations match` }
            : { op, kind: "stale", index: hd.index, text: `deref ${hd.name} ${hd.index}v${hd.gen} → none. Stale: ${why}.` +
                (s && s.val !== null ? ` A bare index would have handed you the ${s.val}.` : "") };
        } else if (valid) {
          s.val = null; s.gen += 1; s.next = head; head = hd.index;
          last = { op, kind: "rem", index: hd.index, text: `remove ${hd.name} ${hd.index}v${hd.gen}: slot ${hd.index} gen ${hd.gen}→${s.gen}, pushed on the free list` };
        } else {
          last = { op, kind: "stale", index: hd.index, text: `remove ${hd.name} ${hd.index}v${hd.gen} rejected. Stale: ${why}.` };
        }
      }
    }
    const free = [];
    for (let j = head, guard = 0; j >= 0 && guard < 99; j = slots[j].next ?? -1, guard++) free.push(j);
    return { slots, handles, head, free, caught, checks, last, live: slots.filter((s) => s.val !== null).length };
  }

  const C = B.colors();
  const chart = B.chart(root, render);
  const result = h("output", { class: "ch05-result", "aria-live": "polite" }, "–");
  const cnt = B.counters([["op", "step"], ["live", "live"], ["slots", "slots"], ["free", "free list"], ["caught", "stale handles caught", "good"]]);
  const chips = h("div", { class: "ch05-chips", role: "group", "aria-label": "Handles you hold (tap one to select it)" });
  const nextName = () => NAMES.find((nm) => !ops.slice(0, k).some((o) => o.t === "ins" && o.name === nm)) || null;
  const push = (op) => { ops = ops.slice(0, k).concat(op); k++; player.pause(); draw(); };
  const bIns = h("button", { type: "button", onclick: () => { const nm = nextName(); if (nm) { selected = nm; push({ t: "ins", name: nm }); } } }, "Insert");
  const bRem = h("button", { type: "button", onclick: () => selected && push({ t: "rem", ref: selected }) }, "Remove selected");
  const bGet = h("button", { type: "button", onclick: () => selected && push({ t: "get", ref: selected }) }, "Deref selected");

  function render(w) {
    const st = replay(k), narrow = w < 600;
    const cols = narrow ? 4 : MAX, rows = Math.ceil(MAX / cols), pad = 8, gap = narrow ? 6 : 10;
    const bw = (w - 2 * pad - (cols - 1) * gap) / cols, bh = 74, top = 30;
    const H = top + rows * (bh + 26) + 6;
    const svg = B.svg("svg", { viewBox: `0 0 ${w} ${H}`, width: w, height: H, role: "img",
      "aria-label": `Pool with ${st.slots.length} slots, ${st.live} live; free list ${st.free.join(" → ") || "empty"}` });
    const T = (x, y, s, o = {}) => B.svg("text", Object.assign({ x, y, fill: C.text, "font-family": C.mono, "font-size": 12 }, o), s);
    svg.append(T(pad, 16, "free_head → " + (st.free.length ? st.free.join(" → ") + " → end" : "end"), { fill: C.heading, "font-weight": 700 }));
    for (let i = 0; i < MAX; i++) {
      const s = st.slots[i], r = Math.floor(i / cols), c = i % cols;
      const x = pad + c * (bw + gap), y = top + r * (bh + 26);
      const target = st.last && st.last.kind !== "ins" && st.last.index === i;
      const justIns = st.last && st.last.kind === "ins" && st.last.index === i;
      const stroke = !s ? C.border : target ? (st.last.kind === "ok" ? C.hit : st.last.kind === "stale" ? C.miss : C.accent) : justIns ? C.accent : s.val !== null ? C.pos : C.dim;
      svg.append(B.svg("rect", { x, y, width: bw, height: bh, rx: 6, fill: s ? C.elev2 : "none", stroke, "stroke-width": target || justIns ? 3 : 1.5,
        "stroke-dasharray": s && s.val === null ? "5 4" : !s ? "2 4" : null }));
      svg.append(T(x + 6, y + 15, "slot " + i, { fill: C.dim, "font-size": 11 }));
      if (!s) { svg.append(T(x + bw / 2, y + 46, "unused", { fill: C.dim, "text-anchor": "middle", "font-size": 11 })); continue; }
      svg.append(T(x + 6, y + 34, "gen " + s.gen, { fill: C.flag, "font-weight": 700 }));
      svg.append(s.val !== null ? T(x + 6, y + 56, s.val, { fill: C.heading, "font-size": 14, "font-weight": 700 })
        : T(x + 6, y + 56, "free → " + (s.next === null || s.next < 0 ? "end" : s.next), { fill: C.dim, "font-size": 11 }));
      // which held handles point at this slot
      const hs = st.handles.filter((x2) => x2.index === i).map((x2) => x2.name + " v" + x2.gen);
      if (hs.length) svg.append(T(x + bw / 2, y + bh + 16, hs.join(" · "), { fill: C.dim, "font-size": narrow ? 9.5 : 10.5, "text-anchor": "middle" }));
    }
    return svg;
  }

  function draw() {
    const st = replay(k);
    chart.redraw();
    result.textContent = st.last ? st.last.text : "Empty pool. Step through the story, or Insert.";
    result.dataset.kind = st.last ? st.last.kind : "";
    cnt.set("op", k + "/" + ops.length); cnt.set("live", st.live); cnt.set("slots", st.slots.length + "/" + MAX);
    cnt.set("free", st.free.length ? st.free.join("→") : "empty"); cnt.set("caught", st.caught + " of " + st.checks + " checks");
    if (selected && !st.handles.some((x) => x.name === selected)) selected = null;
    if (!selected && st.handles.length) selected = st.handles[st.handles.length - 1].name;
    chips.replaceChildren(h("span", { class: "ch05-chips-label" }, "Handles held:"),
      ...(st.handles.length ? st.handles.map((x) => h("button", { type: "button", "aria-pressed": String(x.name === selected),
        onclick: () => { selected = x.name; draw(); } }, `${x.name} ${x.index}v${x.gen}`)) : [h("span", { class: "ch05-chips-label" }, "none")]));
    bIns.disabled = !nextName() || (st.free.length === 0 && st.slots.length >= MAX);
    bRem.disabled = bGet.disabled = !selected;
  }

  const player = B.player(root, {
    step: () => (k < ops.length ? (k++, true) : false), back: () => (k > 0 ? (k--, true) : false),
    reset: () => { k = 0; ops = STORY.slice(); selected = null; }, atEnd: () => k === ops.length, draw,
    interval: opts.interval ?? 0.9, loop: false,
  });
  root.append(result, cnt.el, chips, h("div", { class: "controls" }, player.el, h("div", { class: "group", role: "group", "aria-label": "Pool operations" }, bIns, bRem, bGet)));
  draw();
}));
