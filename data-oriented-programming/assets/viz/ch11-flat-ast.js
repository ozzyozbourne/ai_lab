/* ch11-flat-ast — type or pick a snippet of the chapter's tiny language and see, live, the three arrays the front end
 * builds: tokens (u8 tag + u32 start), nodes (tag, main_token, lhs, rhs) and the shared extra array. Hover, focus or
 * tap a node row to light up its main token, the source text of its subtree, its children and its extra cells; tap a
 * token (in the source or the table) to select the node whose main_token it is.
 * <div class="figure-body" data-viz="ch11-flat-ast" data-opts='{"preset":1}'></div>
 * Options:
 *   preset  0..3 initial snippet (default 0)
 *   select  initial node index to select (default: the first call/fn node)
 * Model: a line-for-line JS port of tokenize() and Parser in code/ch11-capstone-flat-ast-compiler/rust/src/main.rs
 * (same tags, same encodings, same scratch-then-extra list building, same interning), so node and extra indices are
 * the ones the Rust, Zig and Odin programs build for the same text. Bytes: 5 per token, 13 per node, 4 per extra u32. */
(window.BookQ ||= []).push((B) => {
  const TOK = ["eof", "invalid", "int", "ident", "kw_fn", "kw_let", "kw_if", "kw_else", "kw_return", "l_paren", "r_paren",
    "l_brace", "r_brace", "comma", "semicolon", "equal", "equal_equal", "plus", "minus", "star", "slash", "percent", "less"];
  const T = Object.fromEntries(TOK.map((n, i) => [n, i]));
  const TAG = ["root", "fn_decl", "block_two", "block", "let_decl", "return_stmt", "if_simple", "if_else", "int_literal",
    "identifier", "negate", "add", "sub", "mul", "div", "mod", "less_than", "equal_equal", "call_one", "call"];
  const G = Object.fromEntries(TAG.map((n, i) => [n, i]));
  const KW = { fn: T.kw_fn, let: T.kw_let, if: T.kw_if, else: T.kw_else, return: T.kw_return };
  const PUNCT = { "(": T.l_paren, ")": T.r_paren, "{": T.l_brace, "}": T.r_brace, ",": T.comma, ";": T.semicolon,
    "=": T.equal, "+": T.plus, "-": T.minus, "*": T.star, "/": T.slash, "%": T.percent, "<": T.less };
  const isDigit = (c) => c >= "0" && c <= "9";
  const isIdent = (c) => /[A-Za-z0-9_]/.test(c);
  const scan = (s, i, f) => { while (i < s.length && f(s[i])) i++; return i; };

  function tokenize(src) {
    const tag = [], start = [];
    let i = 0;
    for (;;) {
      i = scan(src, i, (c) => c === " " || c === "\n" || c === "\t" || c === "\r");
      if (src.startsWith("//", i)) { i = scan(src, i, (c) => c !== "\n"); continue; }
      const s = i;
      if (i >= src.length) { tag.push(T.eof); start.push(s); return { tag, start }; }
      const c = src[i];
      let t;
      if (isDigit(c)) { i = scan(src, i, isDigit); t = T.int; }
      else if (/[A-Za-z_]/.test(c)) { const e = scan(src, i, isIdent); t = KW[src.slice(i, e)] ?? T.ident; i = e; }
      else if (c === "=" && src[i + 1] === "=") { i += 2; t = T.equal_equal; }
      else { i += 1; t = PUNCT[c] ?? T.invalid; }
      tag.push(t); start.push(s);
    }
  }
  function tokenEnd(src, tag, s) {
    if (tag === T.int) return scan(src, s, isDigit);
    if (tag === T.ident || (tag >= T.kw_fn && tag <= T.kw_return)) return scan(src, s, isIdent);
    if (tag === T.equal_equal) return s + 2;
    if (tag === T.eof) return s;
    return s + 1;
  }
  const BIN = { [T.equal_equal]: [1, G.equal_equal], [T.less]: [2, G.less_than], [T.plus]: [3, G.add], [T.minus]: [3, G.sub],
    [T.star]: [4, G.mul], [T.slash]: [4, G.div], [T.percent]: [4, G.mod] };

  class ParseError extends Error { constructor(token, expected) { super(expected); this.token = token; this.expected = expected; } }

  function parse(src, tk) {
    const nodes = { tag: [], main: [], lhs: [], rhs: [] }, extra = [], scratch = [], syms = [], symOf = new Map();
    let i = 0;
    const peek = () => tk.tag[i], next = () => i++;
    const expect = (t, what) => { if (peek() === t) return next(); throw new ParseError(i, what); };
    const intern = (tok) => {
      const s = src.slice(tk.start[tok], tokenEnd(src, T.ident, tk.start[tok]));
      if (!symOf.has(s)) { symOf.set(s, syms.length); syms.push(s); }
      return symOf.get(s);
    };
    const add = (tag, m, l, r) => { nodes.tag.push(tag); nodes.main.push(m); nodes.lhs.push(l); nodes.rhs.push(r); return nodes.tag.length - 1; };
    const listToExtra = (top) => { const s = extra.length; extra.push(...scratch.splice(top)); return [s, extra.length]; };
    function parseFn() {
      const fnTok = expect(T.kw_fn, "`fn`");
      const name = intern(expect(T.ident, "function name"));
      expect(T.l_paren, "`(`");
      const top = scratch.length;
      if (peek() !== T.r_paren) for (;;) { scratch.push(intern(expect(T.ident, "parameter name"))); if (peek() !== T.comma) break; next(); }
      expect(T.r_paren, "`)`");
      const proto = extra.length;
      extra.push(name, scratch.length - top);
      listToExtra(top);
      return add(G.fn_decl, fnTok, proto, parseBlock());
    }
    function parseBlock() {
      const lb = expect(T.l_brace, "`{`");
      const top = scratch.length;
      while (peek() !== T.r_brace) scratch.push(parseStmt());
      next();
      if (scratch.length - top <= 2) {
        const a = scratch[top] ?? 0, b = scratch[top + 1] ?? 0;
        scratch.length = top;
        return add(G.block_two, lb, a, b);
      }
      const [s, e] = listToExtra(top);
      return add(G.block, lb, s, e);
    }
    function parseStmt() {
      const t = peek();
      if (t === T.kw_let) {
        const lt = next(); const sym = intern(expect(T.ident, "variable name")); expect(T.equal, "`=`");
        const init = parseExpr(0); expect(T.semicolon, "`;`");
        return add(G.let_decl, lt, sym, init);
      }
      if (t === T.kw_return) { const rt = next(); const v = parseExpr(0); expect(T.semicolon, "`;`"); return add(G.return_stmt, rt, v, 0); }
      if (t === T.kw_if) return parseIf();
      if (t === T.eof) throw new ParseError(i, "`}`");
      const e = parseExpr(0); expect(T.semicolon, "`;`"); return e;
    }
    function parseIf() {
      const it = next(); const cond = parseExpr(0); const then = parseBlock();
      if (peek() !== T.kw_else) return add(G.if_simple, it, cond, then);
      next();
      const els = peek() === T.kw_if ? parseIf() : parseBlock();
      const x = extra.length; extra.push(then, els);
      return add(G.if_else, it, cond, x);
    }
    function parseExpr(minPrec) {
      let lhs = parsePrefix();
      for (let op = BIN[peek()]; op && op[0] > minPrec; op = BIN[peek()]) {
        const t = next(); const rhs = parseExpr(op[0]); lhs = add(op[1], t, lhs, rhs);
      }
      return lhs;
    }
    function parsePrefix() {
      const t = peek();
      if (t === T.int) {
        const k = next(); const v = Number(src.slice(tk.start[k], tokenEnd(src, T.int, tk.start[k])));
        if (v > 4294967295) throw new ParseError(k, "integer below 2^32");
        return add(G.int_literal, k, v, 0);
      }
      if (t === T.ident) { const k = next(); const id = add(G.identifier, k, intern(k), 0); return peek() === T.l_paren ? parseCall(id) : id; }
      if (t === T.l_paren) { next(); const e = parseExpr(0); expect(T.r_paren, "`)`"); return e; }
      if (t === T.minus) { const k = next(); return add(G.negate, k, parsePrefix(), 0); }
      throw new ParseError(i, "expression");
    }
    function parseCall(callee) {
      const lp = next(); const top = scratch.length;
      if (peek() !== T.r_paren) for (;;) { scratch.push(parseExpr(0)); if (peek() !== T.comma) break; next(); }
      expect(T.r_paren, "`)`");
      if (scratch.length - top <= 1) { const a = scratch[top] ?? 0; scratch.length = top; return add(G.call_one, lp, callee, a); }
      const [s, e] = listToExtra(top);
      const r = extra.length; extra.push(s, e);
      return add(G.call, lp, callee, r);
    }
    add(G.root, 0, 0, 0);
    const top = scratch.length;
    while (peek() !== T.eof) scratch.push(parseFn());
    const [s, e] = listToExtra(top);
    nodes.lhs[0] = s; nodes.rhs[0] = e;
    return { nodes, extra, syms };
  }

  /* What each field of node n means: children (node indices), extra cells it owns, and a readable lhs/rhs. */
  function explain(a, n) {
    const { nodes: N, extra: X, syms } = a, tag = N.tag[n], l = N.lhs[n], r = N.rhs[n];
    const kids = [], cells = [];
    const range = (s, e) => { for (let k = s; k < e; k++) { cells.push(k); kids.push(X[k]); } };
    let L = String(l), R = String(r), note = "";
    const nd = (x) => (x ? "n" + x : "none");
    switch (tag) {
      case G.root: range(l, r); L = "x" + l; R = "x" + r; note = `functions: extra[${l}..${r}]`; break;
      case G.fn_decl: {
        const np = X[l + 1]; cells.push(l, l + 1); for (let k = 0; k < np; k++) cells.push(l + 2 + k);
        kids.push(r); L = "x" + l; R = nd(r);
        note = `extra[${l}..${l + 2 + np}] = {name "${syms[X[l]]}", ${np} param${np === 1 ? "" : "s"}${np ? ": " + X.slice(l + 2, l + 2 + np).map((s) => syms[s]).join(", ") : ""}}; body n${r}`;
        break;
      }
      case G.block_two: if (l) kids.push(l); if (r) kids.push(r); L = nd(l); R = nd(r); note = "up to two statements inline, no extra"; break;
      case G.block: range(l, r); L = "x" + l; R = "x" + r; note = `${r - l} statements: extra[${l}..${r}]`; break;
      case G.let_decl: kids.push(r); L = `s${l} "${syms[l]}"`; R = nd(r); note = `binds "${syms[l]}" to n${r}`; break;
      case G.return_stmt: kids.push(l); L = nd(l); R = "–"; break;
      case G.if_simple: kids.push(l, r); L = nd(l); R = nd(r); note = "condition, then-block inline"; break;
      case G.if_else: kids.push(l, X[r], X[r + 1]); cells.push(r, r + 1); L = nd(l); R = "x" + r; note = `then n${X[r]}, else n${X[r + 1]} in extra[${r}..${r + 2}]`; break;
      case G.int_literal: L = String(l); R = "–"; note = "the value itself, no child"; break;
      case G.identifier: L = `s${l} "${syms[l]}"`; R = "–"; note = "an interned symbol index"; break;
      case G.negate: kids.push(l); L = nd(l); R = "–"; break;
      case G.call_one: kids.push(l); if (r) kids.push(r); L = nd(l); R = nd(r); note = r ? "callee and its one argument, inline" : "callee, no arguments"; break;
      case G.call: {
        const s = X[r], e = X[r + 1]; cells.push(r, r + 1); range(s, e); kids.push(l);
        L = nd(l); R = "x" + r; note = `extra[${r}..${r + 2}] = {${s}, ${e}} → args extra[${s}..${e}]`; break;
      }
      default: kids.push(l, r); L = nd(l); R = nd(r); note = "binary operator: both operands inline";
    }
    return { kids, cells, L, R, note };
  }

  const PRESETS = [
    ["call_one", "fn main() {\n    return inc(41);\n}\nfn inc(x) { return x + 1; }"],
    ["call", "fn main() {\n    return add3(1, 2, 3);\n}\nfn add3(a, b, c) { return a + b * c; }"],
    ["if / else", "fn abs(x) {\n    if x < 0 { return -x; } else { return x; }\n}"],
    ["block", "fn main() {\n    let a = 2;\n    let b = a * (3 + 4);\n    let c = b - 1;\n    return c;\n}"],
  ];

  B.viz.register("ch11-flat-ast", (root, opts) => {
    const { h, viz } = B;
    const KNOWN = ["preset", "select"];
    for (const k of Object.keys(opts)) viz.check(KNOWN.includes(k), `ch11-flat-ast: unknown option "${k}" (known: ${KNOWN.join(", ")})`);
    const p0 = opts.preset ?? 0;
    viz.check(Number.isInteger(p0) && p0 >= 0 && p0 < PRESETS.length, `ch11-flat-ast: "preset" must be 0..${PRESETS.length - 1}`);
    const MAX = 600;
    root.classList.add("ch11-flat");

    const ta = h("textarea", { class: "ch11-src-input", rows: 6, spellcheck: "false", maxlength: MAX, "aria-label": "Source text (edit me)" });
    const srcView = h("pre", { class: "ch11-src-view", "aria-label": "Source with tokens; tap a token" });
    const status = h("p", { class: "ch11-status", role: "status" });
    const cnt = B.counters([["tok", "tokens"], ["nodes", "nodes"], ["extra", "extra u32s"], ["bytes", "bytes"], ["avg", "B/node incl. extra"], ["npt", "nodes/token"]]);
    const tokBox = h("div", { class: "ch11-tbl", tabindex: "0", role: "region", "aria-label": "token arrays" }), nodeBox = h("div", { class: "ch11-tbl ch11-tbl-nodes", tabindex: "0", role: "region", "aria-label": "node arrays" }), extraBox = h("div", { class: "ch11-tbl", tabindex: "0", role: "region", "aria-label": "extra array" });
    const info = h("p", { class: "ch11-info", "aria-live": "polite" });
    const seg = B.segmented(PRESETS.map((p) => p[0]), p0, (i) => { ta.value = PRESETS[i][1]; pinned = -1; update(); }, "Example");

    let A = null, tk = null, src = "", pinned = opts.select ?? -1, hover = -1, tokRows = [], nodeRows = [], extraRows = [], srcSpans = [];

    function update() {
      src = ta.value.slice(0, MAX);
      tk = tokenize(src);
      try { A = parse(src, tk); status.textContent = ""; status.className = "ch11-status"; }
      catch (e) {
        if (!(e instanceof ParseError)) throw e;
        A = null; status.className = "ch11-status ch11-bad";
        const t = tk.tag[e.token];
        status.textContent = `Parse error at token ${e.token} (${TOK[t]} at byte ${tk.start[e.token]}): expected ${e.expected}. The tokens are still shown.`;
      }
      if (A && (pinned < 0 || pinned >= A.nodes.tag.length)) {
        pinned = A.nodes.tag.findIndex((t) => t === G.call || t === G.call_one || t === G.if_else || t === G.block);
        if (pinned < 0) pinned = A.nodes.tag.length > 1 ? 1 : 0;
      }
      build();
      paint();
    }

    function cell(txt, cls) { return h("td", { class: cls || null }, txt); }
    function build() {
      // source with token spans
      srcSpans = [];
      const kids = []; let at = 0;
      tk.tag.forEach((t, k) => {
        const s = tk.start[k], e = tokenEnd(src, t, s);
        if (s > at) kids.push(src.slice(at, s));
        if (t === T.eof) return;
        const sp = h("span", { class: "ch11-tk", "data-k": k, onclick: () => pickToken(k) }, src.slice(s, e));
        srcSpans[k] = sp; kids.push(sp); at = e;
      });
      if (at < src.length) kids.push(src.slice(at));
      srcView.replaceChildren(...kids, "\u200b");

      const n = tk.tag.length;
      tokRows = [];
      const tb = h("tbody");
      for (let k = 0; k < n; k++) {
        const tr = h("tr", { tabindex: 0, onclick: () => pickToken(k), onkeydown: (ev) => { if (ev.key === "Enter") pickToken(k); } },
          cell(k, "num"), cell(TOK[tk.tag[k]]), cell(tk.start[k], "num"));
        tokRows.push(tr); tb.append(tr);
      }
      tokBox.replaceChildren(h("div", { class: "ch11-cap" }, "tokens · 1 + 4 B"),
        h("table", {}, h("thead", {}, h("tr", {}, h("th", { class: "num" }, "#"), h("th", {}, "tag u8"), h("th", { class: "num" }, "start u32"))), tb));

      nodeRows = []; extraRows = [];
      if (!A) { nodeBox.replaceChildren(h("div", { class: "ch11-cap" }, "nodes"), h("p", { class: "ch11-dim" }, "—")); extraBox.replaceChildren(); return; }
      const N = A.nodes, nb = h("tbody");
      for (let k = 0; k < N.tag.length; k++) {
        const ex = explain(A, k);
        const sel = () => { pinned = k; hover = -1; paint(); };
        const tr = h("tr", { tabindex: 0, onclick: sel, onmouseenter: () => { hover = k; paint(); }, onmouseleave: () => { hover = -1; paint(); },
          onfocus: () => { hover = k; paint(); }, onblur: () => { hover = -1; paint(); }, onkeydown: (ev) => { if (ev.key === "Enter") sel(); } },
          cell("n" + k, "num"), cell(TAG[N.tag[k]], "ch11-tag"), cell(N.main[k], "num"), cell(ex.L, "num"), cell(ex.R, "num"));
        nodeRows.push(tr); nb.append(tr);
      }
      nodeBox.replaceChildren(h("div", { class: "ch11-cap" }, "nodes · 1 + 4 + 4 + 4 B"),
        h("table", {}, h("thead", {}, h("tr", {}, h("th", { class: "num" }, "#"), h("th", {}, "tag"), h("th", { class: "num" }, "main_tok"),
          h("th", { class: "num" }, "lhs"), h("th", { class: "num" }, "rhs"))), nb));
      const xb = h("tbody");
      A.extra.forEach((v, k) => { const tr = h("tr", {}, cell("x" + k, "num"), cell(v, "num")); extraRows.push(tr); xb.append(tr); });
      extraBox.replaceChildren(h("div", { class: "ch11-cap" }, "extra · 4 B"),
        A.extra.length ? h("table", {}, h("thead", {}, h("tr", {}, h("th", { class: "num" }, "#"), h("th", { class: "num" }, "u32"))), xb)
          : h("p", { class: "ch11-dim" }, "empty"));
    }

    function pickToken(k) {
      if (!A) { paintTokens(new Set([k]), -1, -1); return; }
      // the node whose main_token is k
      let best = -1;
      A.nodes.main.forEach((m, n) => { if (m === k && n > 0 && best < 0) best = n; });
      if (best >= 0) { pinned = best; paint(); } else paintTokens(new Set([k]), -1, -1);
    }

    function subtree(n, out) { out.add(n); for (const c of explain(A, n).kids) if (c > 0 && !out.has(c)) subtree(c, out); return out; }

    function paintTokens(main, lo, hi) {
      tokRows.forEach((tr, k) => { tr.classList.toggle("ch11-main", main.has(k)); tr.classList.toggle("ch11-span", k >= lo && k <= hi && !main.has(k)); });
      srcSpans.forEach((sp, k) => { if (!sp) return; sp.classList.toggle("ch11-main", main.has(k)); sp.classList.toggle("ch11-span", k >= lo && k <= hi && !main.has(k)); });
    }

    function paint() {
      const n0 = tk.tag.length;
      cnt.set("tok", n0);
      if (!A) {
        ["nodes", "extra", "avg", "npt"].forEach((k) => cnt.set(k, "–"));
        cnt.set("bytes", 5 * n0 + " B"); info.textContent = ""; paintTokens(new Set(), -1, -1); return;
      }
      const nn = A.nodes.tag.length, nx = A.extra.length;
      cnt.set("nodes", nn); cnt.set("extra", nx);
      cnt.set("bytes", `${5 * n0} + ${13 * nn} + ${4 * nx} = ${5 * n0 + 13 * nn + 4 * nx} B`);
      cnt.set("avg", ((13 * nn + 4 * nx) / nn).toFixed(2)); cnt.set("npt", (nn / n0).toFixed(2));
      const sel = hover >= 0 ? hover : pinned;
      const ex = explain(A, sel), kids = new Set(ex.kids.filter((c) => c > 0)), cells = new Set(ex.cells);
      const sub = subtree(sel, new Set());
      let lo = Infinity, hi = -1;
      if (sel > 0) for (const s of sub) { lo = Math.min(lo, A.nodes.main[s]); hi = Math.max(hi, A.nodes.main[s]); }
      if (sel > 0 && A.nodes.tag[sel] === G.fn_decl) lo = A.nodes.main[sel];
      paintTokens(new Set(sel > 0 ? [A.nodes.main[sel]] : []), lo, hi);
      nodeRows.forEach((tr, k) => { tr.classList.toggle("ch11-sel", k === sel); tr.classList.toggle("ch11-kid", kids.has(k)); });
      extraRows.forEach((tr, k) => tr.classList.toggle("ch11-cell", cells.has(k)));
      const tok = A.nodes.main[sel];
      info.replaceChildren(h("b", {}, `n${sel} ${TAG[A.nodes.tag[sel]]}`),
        ` · main_token ${tok} (${TOK[tk.tag[tok]]} "${src.slice(tk.start[tok], tokenEnd(src, tk.tag[tok], tk.start[tok]))}")`,
        ex.note ? ` · ${ex.note}` : "", kids.size ? ` · children ${[...kids].map((c) => "n" + c).join(", ")}` : "");
      const row = nodeRows[sel];
      if (row && hover < 0 && row.parentElement) {
        const box = nodeBox; const top = row.offsetTop - box.clientHeight / 2;
        if (row.offsetTop < box.scrollTop || row.offsetTop > box.scrollTop + box.clientHeight - 30) box.scrollTop = Math.max(0, top);
      }
    }

    ta.value = PRESETS[p0][1];
    ta.addEventListener("input", () => update());
    root.append(
      h("div", { class: "controls ch11-top" }, seg, h("span", { class: "ch11-dim" }, "or edit the text")),
      h("div", { class: "ch11-srcwrap" }, ta, srcView),
      status, cnt.el, info,
      h("div", { class: "ch11-grid" }, tokBox, nodeBox, extraBox),
      h("div", { class: "legend" },
        h("span", {}, h("i", { class: "ch11-sw-main" }), "main token"), h("span", {}, h("i", { class: "ch11-sw-span" }), "tokens of the subtree"),
        h("span", {}, h("i", { class: "ch11-sw-sel" }), "selected node"), h("span", {}, h("i", { class: "ch11-sw-kid" }), "its children"),
        h("span", {}, h("i", { class: "ch11-sw-cell" }), "its extra cells")));
    update();
  });

  // Exposed for the chapter's own consistency check (not part of any API).
  B.ch11 = { tokenize, parse, TOK, TAG };
});
