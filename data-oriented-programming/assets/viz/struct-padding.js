/* struct-padding — byte grid of a struct with alignment padding, declaration (C) order vs reordered.
 * <div class="figure-body" data-viz="struct-padding"
 *      data-opts='{"name":"Monster","fields":[["alive","bool"],["hp","u32"],["pos","[3]f32"],["id","u64"]]}'></div>
 * Options:
 *   fields   required. [["name","type"], ...] or [{"name","type"}] or [{"name","size","align"}].
 *            Types: bool u8 i8 u16 i16 f16 u32 i32 f32 char rune u64 i64 f64 usize isize int uint uintptr
 *            u128 i128 (align 16), pointers (*T ^T &T Box<T> rawptr), arrays [3]f32 or [f32; 3]. x86-64 sizes.
 *   name     struct name for labels (default "S")
 *   labels   [declLabel, reorderedLabel] (default C order vs Rust/Zig reordered)
 *   initial  0 = declaration order, 1 = reordered (default 0)
 *   reorder  false hides the toggle and shows declaration order only (default true)
 *   count    multiply the size by this for the memory readout (default 100000; 0 hides it)
 * Reordering model: stable sort by alignment, largest first. rustc and Zig do something like this today, but
 * neither language guarantees an order; use the real offsets from offset_of!/@offsetOf when it matters. */
(window.BookQ ||= []).push((B) => B.viz.register("struct-padding", (root, opts) => {
  const { h, viz } = B;
  const KNOWN = ["fields", "name", "labels", "initial", "reorder", "count"];
  for (const k of Object.keys(opts)) viz.check(KNOWN.includes(k), `struct-padding: unknown option "${k}" (known: ${KNOWN.join(", ")})`);
  const BASE = {
    bool: 1, u8: 1, i8: 1, b8: 1, byte: 1, c_char: 1,
    u16: 2, i16: 2, f16: 2, b16: 2,
    u32: 4, i32: 4, f32: 4, char: 4, rune: 4, b32: 4,
    u64: 8, i64: 8, f64: 8, usize: 8, isize: 8, int: 8, uint: 8, uintptr: 8, rawptr: 8, b64: 8,
    u128: 16, i128: 16,
  };
  function typeInfo(t) {
    t = String(t).trim();
    if (t in BASE) return { size: BASE[t], align: BASE[t] };
    let m = /^\[(\d+)\]\s*(.+)$/.exec(t); // Zig / Odin: [3]f32
    if (m) { const el = typeInfo(m[2]); return { size: el.size * +m[1], align: el.align }; }
    m = /^\[(.+);\s*(\d+)\]$/.exec(t); // Rust: [f32; 3]
    if (m) { const el = typeInfo(m[1]); return { size: el.size * +m[2], align: el.align }; }
    if (/^(\*|\^|&|\?\*|Box<|Option<&|Option<Box<|NonNull<)/.test(t)) return { size: 8, align: 8 };
    throw new Error(`struct-padding: unknown type "${t}". Give {"name", "size", "align"} for anything else.`);
  }
  viz.check(Array.isArray(opts.fields) && opts.fields.length > 0, `struct-padding: "fields" must be a non-empty array`);
  const fields = opts.fields.map((f, i) => {
    let name, type, size, align;
    if (Array.isArray(f)) [name, type] = f;
    else if (f && typeof f === "object") ({ name, type, size, align } = f);
    viz.check(typeof name === "string" && name, `struct-padding: field ${i} has no name`);
    if (type !== undefined) ({ size, align } = typeInfo(type));
    else type = size + " B";
    viz.check(Number.isInteger(size) && size > 0, `struct-padding: field "${name}" needs a positive integer size`);
    viz.check(Number.isInteger(align) && align > 0 && (align & (align - 1)) === 0, `struct-padding: field "${name}" align must be a power of two`);
    return { name, type, size, align, idx: i };
  });
  const NAME = opts.name || "S";
  const labels = opts.labels || ["Declaration order: repr(C) · extern struct · Odin", "Reordered: Rust default · Zig struct"];
  viz.check(Array.isArray(labels) && labels.length === 2, `struct-padding: "labels" must be two strings`);
  const count = opts.count ?? 100000;
  const reorder = opts.reorder !== false;
  let order = reorder ? opts.initial ?? 0 : 0;
  viz.check(order === 0 || order === 1, `struct-padding: "initial" must be 0 or 1`);

  function layout(list) {
    let off = 0, maxAlign = 1;
    const items = [];
    for (const f of list) {
      maxAlign = Math.max(maxAlign, f.align);
      const p = (f.align - (off % f.align)) % f.align;
      if (p) items.push({ pad: p, offset: off });
      off += p;
      items.push({ ...f, offset: off });
      off += f.size;
    }
    const size = Math.ceil(off / maxAlign) * maxAlign;
    if (size > off) items.push({ pad: size - off, offset: off, tail: true });
    const padding = items.filter((x) => x.pad).reduce((s, x) => s + x.pad, 0);
    return { items, size, align: maxAlign, padding };
  }
  const L = [layout(fields), layout([...fields].sort((a, b) => b.align - a.align || a.idx - b.idx))];

  const C = B.colors();
  const PALETTE = [C.pos, C.vel, C.hp, C.flag, C.line, "#f59ac0", "#9fe0d8", "#d9c38a", "#b0b8ff", "#ffb38a"];
  const colorOf = (f) => PALETTE[f.idx % PALETTE.length];
  const uid = "sp" + Math.random().toString(36).slice(2, 8);

  const cnt = B.counters([["size", "size"], ["align", "align"], ["pad", "padding", "bad"], ["mem", count ? "× " + B.fmtInt(count) : ""], ["cmp", ""]]);
  if (!count) cnt.outs.mem.parentElement.remove();
  const table = h("table", { class: "viz-table sp-table" });
  const tableWrap = h("div", { class: "table-wrap" }, table);
  root.classList.add("viz-struct-padding");
  root.append(h("p", { class: "viz-title" }, ""));
  const chart = B.chart(root, render);
  const controls = h("div", { class: "controls" });
  if (reorder) controls.append(B.segmented(labels, order, (i) => { order = i; update(); }, "Field order"));
  root.append(cnt.el, controls, tableWrap);

  function render(W) {
    const lay = L[order], perRow = 8, left = 44, cw = (W - left) / perRow, rowH = 34;
    const rows = Math.max(1, Math.ceil(lay.size / perRow));
    const svg = B.svg("svg", { viewBox: `0 0 ${W} ${rows * rowH + 22}`, width: W, height: rows * rowH + 22, role: "img",
      "aria-label": `${NAME} in ${labels[order]}: ${lay.size} bytes, ${lay.padding} of them padding.` });
    svg.append(B.svg("defs", {}, B.svg("pattern", { id: uid + "-hatch", width: 6, height: 6, patternUnits: "userSpaceOnUse", patternTransform: "rotate(45)" },
      B.svg("rect", { width: 6, height: 6, fill: C.pad }), B.svg("line", { x1: 0, y1: 0, x2: 0, y2: 6, stroke: "rgba(255,255,255,.3)", "stroke-width": 2 }))));
    for (let i = 0; i < perRow; i++) svg.append(B.svg("text", { x: left + i * cw + cw / 2, y: 11, "text-anchor": "middle", class: "dim mono" }, "+" + i));
    for (let r = 0; r < rows; r++) svg.append(B.svg("text", { x: 0, y: 22 + r * rowH + rowH / 2 + 4, class: "dim mono" }, String(r * perRow).padStart(2, "0")));
    for (const it of lay.items) {
      let b = it.offset;
      const end = it.offset + (it.pad || it.size);
      while (b < end) {
        const r = Math.floor(b / perRow), c0 = b % perRow, take = Math.min(end - b, perRow - c0);
        const x = left + c0 * cw + 1, y = 22 + r * rowH + 2, w = take * cw - 2, hh = rowH - 6;
        svg.append(B.svg("rect", { x, y, width: w, height: hh, rx: 4, fill: it.pad ? `url(#${uid}-hatch)` : colorOf(it), opacity: it.pad ? 0.9 : 1 }));
        for (let k = 1; k < take; k++) svg.append(B.svg("line", { x1: x + k * cw - 1, x2: x + k * cw - 1, y1: y + hh - 5, y2: y + hh, stroke: "rgba(6,18,31,.45)" }));
        const label = it.pad ? (w > 34 ? "pad" : "") : it.name;
        if (label) {
          const maxChars = Math.floor((w - 6) / 6.6);
          const text = label.length <= maxChars ? label : maxChars >= 2 ? label.slice(0, maxChars - 1) + "…" : "";
          if (text) svg.append(B.svg("text", { x: x + w / 2, y: y + hh / 2 + 4, "text-anchor": "middle", class: "mono", style: `fill:${it.pad ? C.text : "#06121f"};font-weight:600` }, text));
        }
        b += take;
      }
    }
    return svg;
  }
  function update() {
    const lay = L[order], other = L[1 - order];
    root.querySelector(".viz-title").textContent = `${NAME} — ${labels[order]}`;
    cnt.set("size", lay.size + " B");
    cnt.set("align", lay.align + " B");
    cnt.set("pad", `${lay.padding} B (${Math.round((100 * lay.padding) / lay.size)}%)`);
    if (count) cnt.set("mem", B.fmtBytes(lay.size * count));
    const d = other.size - lay.size;
    cnt.outs.cmp.parentElement.hidden = !reorder;
    cnt.set("cmp", d === 0 ? "same size in the other order" : d > 0 ? `other order is ${d} B bigger` : `other order saves ${-d} B (${Math.round((-100 * d) / lay.size)}%)`);
    table.replaceChildren(h("tr", {}, h("th", {}, "field"), h("th", {}, "type"), h("th", { class: "num" }, "offset"), h("th", { class: "num" }, "size"), h("th", { class: "num" }, "align")),
      ...lay.items.map((it) => it.pad
        ? h("tr", {}, h("td", { class: "pad" }, it.tail ? "(tail padding)" : "(padding)"), h("td", {}), h("td", { class: "num" }, it.offset), h("td", { class: "num" }, it.pad), h("td", {}))
        : h("tr", {}, h("td", {}, h("span", { class: "swatch", style: `background:${colorOf(it)}` }), it.name), h("td", {}, it.type),
          h("td", { class: "num" }, it.offset), h("td", { class: "num" }, it.size), h("td", { class: "num" }, it.align))));
    chart.redraw();
  }
  update();
}));
