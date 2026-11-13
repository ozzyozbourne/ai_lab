/* ch03-reorder — drag (or move with buttons) the fields of a struct and watch the padding and size recomputed,
 * under C rules (declaration order: repr(C), extern struct, every Odin struct) or a reordering compiler
 * (Rust default repr, plain Zig struct; modelled as a stable sort by alignment, largest first).
 * <div class="figure-body" data-viz="ch03-reorder" data-opts='{"preset":0}'></div>
 * Options:
 *   preset  index into the built-in structs (0 Monster with a bool, 1 Mixed u8/u64/u8/u32, 2 Kelley's u32/u64/u32 + bool)
 *   mode    0 = C order (default), 1 = reordering compiler
 * Sizes are x86-64: bool/u8 1, u16 2, u32/f32 4, u64/pointer 8; each field's alignment equals its size. */
(window.BookQ ||= []).push((B) => B.viz.register("ch03-reorder", (root, opts) => {
  const { h, viz } = B;
  const KNOWN = ["preset", "mode"];
  for (const k of Object.keys(opts)) viz.check(KNOWN.includes(k), `ch03-reorder: unknown option "${k}" (known: ${KNOWN.join(", ")})`);
  const TYPES = { bool: 1, u8: 1, u16: 2, u32: 4, f32: 4, u64: 8, ptr: 8 };
  const PRESETS = [
    { name: "Monster", fields: [["alive", "bool"], ["anim", "ptr"], ["hp", "u32"], ["kind", "u8"], ["y", "u32"]] },
    { name: "Mixed", fields: [["a", "u8"], ["b", "u64"], ["c", "u8"], ["d", "u32"]] },
    { name: "Quiz", fields: [["a", "u32"], ["b", "u64"], ["c", "u32"], ["d", "bool"]] },
  ];
  let preset = opts.preset ?? 0;
  viz.check(Number.isInteger(preset) && preset >= 0 && preset < PRESETS.length, `ch03-reorder: "preset" must be 0..${PRESETS.length - 1}`);
  let mode = opts.mode ?? 0;
  viz.check(mode === 0 || mode === 1, `ch03-reorder: "mode" must be 0 or 1`);

  const C = B.colors();
  const PALETTE = [C.pos, C.vel, C.hp, C.flag, C.line, "#f59ac0", "#9fe0d8", "#d9c38a"];
  let uidN = 0;
  const mk = (name, type) => ({ name, type, size: TYPES[type], align: TYPES[type], color: PALETTE[uidN++ % PALETTE.length] });
  let fields = [];
  const load = (i) => { uidN = 0; fields = PRESETS[i].fields.map(([n, t]) => mk(n, t)); };
  load(preset);

  function layout(list) {
    let off = 0, maxAlign = 1;
    const items = [];
    for (const f of list) {
      maxAlign = Math.max(maxAlign, f.align);
      const p = (f.align - (off % f.align)) % f.align;
      if (p) items.push({ pad: p, offset: off });
      off += p;
      items.push({ f, offset: off });
      off += f.size;
    }
    const size = Math.ceil(off / maxAlign) * maxAlign || 1;
    if (size > off) items.push({ pad: size - off, offset: off, tail: true });
    const padding = items.filter((x) => x.pad).reduce((s, x) => s + x.pad, 0);
    return { items, size, align: maxAlign, padding, data: off - padding };
  }
  const sorted = () => fields.map((f, i) => ({ f, i })).sort((a, b) => b.f.align - a.f.align || a.i - b.i).map((x) => x.f);

  root.classList.add("ch03-reorder");
  const title = h("p", { class: "viz-title" });
  const list = h("ol", { class: "ch03-fields", "aria-label": "Fields in declaration order" });
  const cnt = B.counters([["size", "size"], ["align", "align"], ["pad", "padding", "bad"], ["best", "best possible"], ["line", "per 64 B line"]]);
  const note = h("p", { class: "ch03-note dim" });
  const left = h("div", { class: "ch03-col" }, h("p", { class: "ch03-cap dim" }, "Declaration order (drag ⠿ or use ▲▼)"), list);
  const right = h("div", { class: "ch03-col" }, h("p", { class: "ch03-cap dim" }, "Memory, 8 bytes per row"));
  const wrap = h("div", { class: "ch03-split" }, left, right);
  root.append(title, wrap);
  const chart = B.chart(right, render);
  const addSel = h("select", { "aria-label": "Type of field to add" }, Object.keys(TYPES).map((t) => h("option", { value: t }, t)));
  addSel.value = "bool";
  let added = 0;
  const controls = h("div", { class: "controls" },
    B.segmented(["C order (as written)", "Reordering compiler"], mode, (i) => { mode = i; update(); }, "Layout rules"),
    h("label", { class: "group" }, "Struct ", h("select", { "aria-label": "Preset struct", onchange: (e) => { preset = +e.target.value; load(preset); update(); } },
      PRESETS.map((p, i) => h("option", { value: i, selected: i === preset ? "" : null }, p.name)))),
    h("span", { class: "group" }, addSel, h("button", { type: "button", onclick: () => { if (fields.length < 10) { fields.push(mk("f" + ++added, addSel.value)); update(); } } }, "Add field")),
    h("button", { type: "button", onclick: () => { fields = sorted(); update(); } }, "Sort by alignment for me"));
  root.append(cnt.el, note, controls);

  const move = (from, to) => {
    if (to < 0 || to >= fields.length || from === to) return;
    const [f] = fields.splice(from, 1);
    fields.splice(to, 0, f);
    update();
  };

  // Pointer drag on the handle: the row under the pointer becomes the target slot.
  function startDrag(ev, f) {
    ev.preventDefault();
    const handle = ev.currentTarget, li = handle.parentElement;
    handle.setPointerCapture(ev.pointerId);
    li.classList.add("dragging");
    const onMove = (e) => {
      const rows = [...list.children];
      let target = rows.length - 1;
      for (let i = 0; i < rows.length; i++) {
        const r = rows[i].getBoundingClientRect();
        if (e.clientY < r.top + r.height / 2) { target = i; break; }
      }
      const cur = fields.indexOf(f);
      if (target !== cur) {
        fields.splice(cur, 1);
        fields.splice(target, 0, f);
        li.remove();
        list.insertBefore(li, list.children[target] || null); // move the node itself: pointer capture survives
        update(false);
      }
    };
    const onUp = () => {
      handle.removeEventListener("pointermove", onMove);
      handle.removeEventListener("pointerup", onUp);
      handle.removeEventListener("pointercancel", onUp);
      update();
      const btn = list.children[fields.indexOf(f)].querySelector(".ch03-handle");
      if (btn) btn.focus();
    };
    handle.addEventListener("pointermove", onMove);
    handle.addEventListener("pointerup", onUp);
    handle.addEventListener("pointercancel", onUp);
  }

  function renderList() {
    const keyMove = (f, d) => {
      move(fields.indexOf(f), fields.indexOf(f) + d);
      list.children[fields.indexOf(f)].querySelector(".ch03-handle").focus();
    };
    list.replaceChildren(...fields.map((f, i) => h("li", { class: "ch03-row" },
      h("button", { type: "button", class: "ch03-handle", "aria-label": `Drag ${f.name}, or press the up and down arrow keys`, onpointerdown: (e) => startDrag(e, f),
        onkeydown: (e) => { if (e.key === "ArrowUp" || e.key === "ArrowDown") { e.preventDefault(); keyMove(f, e.key === "ArrowUp" ? -1 : 1); } } }, "⠿"),
      h("span", { class: "ch03-swatch", style: `background:${f.color}` }),
      h("span", { class: "ch03-name mono" }, f.name, h("span", { class: "dim" }, ": " + f.type)),
      h("span", { class: "ch03-sz dim mono" }, f.size + " B"),
      h("button", { type: "button", "aria-label": `Move ${f.name} up`, disabled: i === 0 ? "" : null, onclick: () => move(fields.indexOf(f), fields.indexOf(f) - 1) }, "▲"),
      h("button", { type: "button", "aria-label": `Move ${f.name} down`, disabled: i === fields.length - 1 ? "" : null, onclick: () => move(fields.indexOf(f), fields.indexOf(f) + 1) }, "▼"),
      h("button", { type: "button", "aria-label": `Remove ${f.name}`, disabled: fields.length <= 1 ? "" : null, onclick: () => { fields.splice(fields.indexOf(f), 1); update(); } }, "×"))));
  }

  function render(W) {
    const lay = layout(mode ? sorted() : fields);
    const perRow = 8, lx = 30, cw = (W - lx) / perRow, rowH = 30;
    const rows = Math.max(1, Math.ceil(lay.size / perRow));
    const H = rows * rowH + 18;
    const svg = B.svg("svg", { viewBox: `0 0 ${W} ${H}`, width: W, height: H, role: "img",
      "aria-label": `${lay.size} bytes, ${lay.padding} of them padding: ` + lay.items.map((it) => it.pad ? `${it.pad} padding` : `${it.f.name} at ${it.offset}`).join(", ") });
    const pid = "ch03h" + Math.random().toString(36).slice(2, 7);
    svg.append(B.svg("defs", {}, B.svg("pattern", { id: pid, width: 6, height: 6, patternUnits: "userSpaceOnUse", patternTransform: "rotate(45)" },
      B.svg("rect", { width: 6, height: 6, fill: C.pad }), B.svg("line", { x1: 0, y1: 0, x2: 0, y2: 6, stroke: "rgba(255,255,255,.3)", "stroke-width": 2 }))));
    for (let i = 0; i < perRow; i++) svg.append(B.svg("text", { x: lx + i * cw + cw / 2, y: 10, "text-anchor": "middle", class: "dim mono" }, "+" + i));
    for (let r = 0; r < rows; r++) svg.append(B.svg("text", { x: 0, y: 18 + r * rowH + rowH / 2 + 3, class: "dim mono" }, String(r * perRow).padStart(2, "0")));
    for (const it of lay.items) {
      let b = it.offset;
      const end = it.offset + (it.pad || it.f.size);
      while (b < end) {
        const r = Math.floor(b / perRow), c0 = b % perRow, take = Math.min(end - b, perRow - c0);
        const x = lx + c0 * cw + 1, y = 18 + r * rowH + 2, w = take * cw - 2, hh = rowH - 5;
        svg.append(B.svg("rect", { x, y, width: w, height: hh, rx: 4, fill: it.pad ? `url(#${pid})` : it.f.color }));
        const label = it.pad ? "" : it.f.name;
        const maxChars = Math.floor((w - 4) / 6.6);
        if (label && maxChars >= 1) svg.append(B.svg("text", { x: x + w / 2, y: y + hh / 2 + 4, "text-anchor": "middle", class: "mono", style: "fill:#06121f;font-weight:600" },
          label.length <= maxChars ? label : label.slice(0, Math.max(1, maxChars - 1)) + (maxChars > 1 ? "…" : "")));
        b += take;
      }
    }
    return svg;
  }

  function update(rebuildList = true) {
    const lay = layout(mode ? sorted() : fields), best = layout(sorted());
    title.textContent = `${PRESETS[preset].name}: ${mode ? "a reordering compiler (Rust default repr, plain Zig struct)" : "C rules (repr(C), extern struct, Odin)"}`;
    cnt.set("size", lay.size + " B");
    cnt.set("align", lay.align + " B");
    cnt.set("pad", `${lay.padding} B (${Math.round((100 * lay.padding) / lay.size)}%)`);
    cnt.set("best", best.size + " B");
    cnt.set("line", (64 / lay.size).toFixed(2).replace(/\.00$/, ""));
    note.textContent = mode
      ? "The compiler ignores the order you wrote, so dragging changes nothing here. Switch to C order to feel the difference."
      : lay.size === best.size
        ? `This order is already as small as a reordering compiler would make it (${lay.data} B of data).`
        : `A reordering compiler would make this ${lay.size - best.size} B smaller. Try putting the 8-byte fields first.`;
    if (rebuildList) renderList();
    chart.redraw();
  }
  update();
}));
