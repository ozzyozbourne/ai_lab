/* book.js: shared runtime for "Evaluations for AI: LLMs, Agents and RL Environments".
 * Classic script (not a module), no dependencies, works from file://.
 * Load with: <script defer src="assets/book.js"></script>
 *
 * What it does on every page:
 *   - builds the top bar (menu, book title, chapter title, theme toggle) and a reading-progress bar
 *   - builds the sidebar: the chapter list (from the manifest below) and an "On this page" TOC from h2/h3
 *   - highlights the current section while scrolling, adds "#" anchors to headings with an id
 *   - appends prev/next chapter links (unless the page has <body data-nav="off">)
 *   - adds a Copy button to every <pre> (except pre.output)
 *   - syntax-highlights <pre><code class="language-python"> (also language-bash, language-yaml, language-json)
 *   - renders the cover TOC into any <ol data-book-toc>
 * Chapter authors: never edit this file. Give every h2/h3 a unique id.
 */
(function () {
  "use strict";
  const Book = (window.Book = window.Book || {});
  Book.version = "1.0.0";

  /* ---------------- manifest: single source of truth for navigation ---------------- */
  Book.title = "Evaluations for AI";
  Book.chapters = [
    { n: 1, file: "01-foundations.html", title: "Why Evals: Foundations, Taxonomy and Eval-Driven Development",
      blurb: "What an eval is (task, trial, grader, transcript, harness), the axes every eval sits on, a 60-line harness, and the eval-driven development loop." },
    { n: 2, file: "02-benchmarks-metrics.html", title: "Benchmarks and Metrics for LLMs",
      blurb: "The benchmark landscape from MMLU to HLE, and every scoring rule underneath it: exact match, F1, BLEU/ROUGE, log-prob scoring, pass@k, calibration, Elo and Bradley-Terry." },
    { n: 3, file: "03-datasets-contamination.html", title: "Building Eval Datasets and Fighting Contamination",
      blurb: "Golden sets from real traces, sampling, labelling guides and agreement, synthetic generation, and detecting and preventing test-set contamination." },
    { n: 4, file: "04-llm-judges-human-eval.html", title: "LLM-as-a-Judge and Human Evaluation",
      blurb: "Judge protocols and prompts, biases you can measure, validating judges against humans, juries, reward models, and statistically valid judge-assisted estimates." },
    { n: 5, file: "05-statistics.html", title: "Statistics and Rigor in Evals",
      blurb: "Error bars, clustered and paired comparisons, power analysis, multiple comparisons, the bootstrap, nondeterminism, IRT and signal-to-noise." },
    { n: 6, file: "06-agent-evals.html", title: "Evaluating AI Agents",
      blurb: "Coding, tool-use, web and computer-use agents: outcome and trajectory grading, user simulators, pass^k, cost frontiers, time horizons, harnesses and how agent benchmarks break." },
    { n: 7, file: "07-rl-environments.html", title: "RL Environments: Rewards, Verifiers and Reward Hacking",
      blurb: "Environments as evals and as reward sources: the Gym contract, LLM-era environments, RLVR verifiers, reward hacking, environment QA and evaluating trained policies." },
    { n: 8, file: "08-safety-redteaming.html", title: "Safety Evals, Red-Teaming and Dangerous Capabilities",
      blurb: "Refusal and harm judges, attack success rates under budgets, over-refusal, prompt injection, dangerous-capability and alignment evals, sandbagging, eval awareness and frontier safety policies." },
    { n: 9, file: "09-tooling-production.html", title: "Tooling, Production, RAG and Online Evaluation",
      blurb: "The harness landscape (lm-eval, Inspect, Harbor, verifiers, promptfoo and more), CI regression gates, RAG and hallucination metrics, online judges, A/B tests, SLOs and drift." },
    { n: 10, file: "10-capstone.html", title: "Capstone: An End-to-End Eval Suite for an Agent and Its RL Environment",
      blurb: "Build, validate and report a complete eval suite for a tool-using agent and the RL environment that trains it, from error analysis to a CI gate and a results card." },
    { n: null, file: "references.html", title: "References",
      blurb: "Every source cited in the book, grouped by topic." },
  ];
  const pageFile = (() => {
    const f = decodeURIComponent(location.pathname.split("/").pop() || "");
    return f || "index.html";
  })();
  Book.current = Book.chapters.find((c) => c.file === pageFile) || null;

  const el = (tag, attrs, ...kids) => {
    const n = document.createElement(tag);
    if (attrs) for (const [k, v] of Object.entries(attrs)) {
      if (k === "class") n.className = v; else if (k === "text") n.textContent = v; else n.setAttribute(k, v);
    }
    for (const k of kids) if (k != null) n.append(k);
    return n;
  };
  const store = {
    get(k) { try { return localStorage.getItem(k); } catch (e) { return null; } },
    set(k, v) { try { localStorage.setItem(k, v); } catch (e) { /* ignore */ } },
  };

  /* ---------------- theme ---------------- */
  const savedTheme = store.get("evalbook-theme");
  if (savedTheme === "light" || savedTheme === "dark") document.documentElement.setAttribute("data-theme", savedTheme);
  function currentTheme() {
    const t = document.documentElement.getAttribute("data-theme");
    if (t) return t;
    return matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  }

  /* ---------------- syntax highlighting ---------------- */
  const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  const wrap = (cls, s) => `<span class="tok-${cls}">${esc(s)}</span>`;
  const PY_KW = new Set(("False None True and as assert async await break class continue def del elif else except finally for from " +
    "global if import in is lambda nonlocal not or pass raise return try while with yield match case").split(" "));
  const PY_BI = new Set(("abs all any bool bytes callable chr dict dir divmod enumerate eval exec filter float format frozenset getattr " +
    "hasattr hash hex id input int isinstance issubclass iter len list map max min next object oct open ord pow print property range " +
    "repr reversed round set setattr slice sorted staticmethod classmethod str sum super tuple type vars zip " +
    "Exception ValueError TypeError KeyError IndexError RuntimeError AssertionError StopIteration TimeoutError NotImplementedError").split(" "));
  function highlightPython(src) {
    const re = /(#[^\n]*)|([rRbBuUfF]{0,2}(?:"""[\s\S]*?"""|'''[\s\S]*?'''|"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'))|(@[A-Za-z_][\w.]*)|(\b(?:0[xX][0-9a-fA-F_]+|\d[\d_]*\.?\d*(?:[eE][+-]?\d+)?j?|\.\d+(?:[eE][+-]?\d+)?)\b)|([A-Za-z_]\w*)/g;
    let out = "", last = 0, m, prev = "";
    while ((m = re.exec(src))) {
      out += esc(src.slice(last, m.index));
      last = re.lastIndex;
      if (m[1]) out += wrap("com", m[1]);
      else if (m[2]) out += wrap("str", m[2]);
      else if (m[3]) out += wrap("dec", m[3]);
      else if (m[4]) out += wrap("num", m[4]);
      else {
        const w = m[5];
        const after = src.slice(last).match(/^\s*\(/);
        if (prev === "def") out += wrap("fn", w);
        else if (prev === "class") out += wrap("cls", w);
        else if (PY_KW.has(w)) out += wrap("kw", w);
        else if (w === "self" || w === "cls") out += wrap("self", w);
        else if (PY_BI.has(w)) out += wrap("bi", w);
        else if (after) out += wrap("fn", w);
        else out += esc(w);
        prev = w;
        continue;
      }
      prev = "";
    }
    return out + esc(src.slice(last));
  }
  function highlightBash(src) {
    return src.split("\n").map((line) => {
      const m = line.match(/^(\s*)(#.*)$/);
      if (m) return esc(m[1]) + wrap("com", m[2]);
      let s = esc(line);
      s = s.replace(/^(\s*(?:\$\s+)?)([A-Za-z0-9_./-]+)/, (all, a, b) => a + `<span class="tok-fn">${b}</span>`);
      s = s.replace(/(\s)(--?[A-Za-z][\w-]*)/g, '$1<span class="tok-kw">$2</span>');
      s = s.replace(/(\s#\s.*)$/, '<span class="tok-com">$1</span>');
      return s;
    }).join("\n");
  }
  function highlightYaml(src) {
    return src.split("\n").map((line) => {
      const c = line.match(/^(\s*)(#.*)$/);
      if (c) return esc(c[1]) + wrap("com", c[2]);
      const m = line.match(/^(\s*-?\s*)([\w.\-/]+)(:)(.*)$/);
      if (m) {
        let v = esc(m[4]);
        v = v.replace(/(&quot;|")(.*?)(\1)/g, '<span class="tok-str">$&</span>').replace(/(\s#\s.*)$/, '<span class="tok-com">$1</span>');
        v = v.replace(/^(\s*)(-?\d+(?:\.\d+)?|true|false|null)\s*$/, '$1<span class="tok-num">$2</span>');
        return esc(m[1]) + `<span class="tok-key">${esc(m[2])}</span>${m[3]}` + v;
      }
      return esc(line);
    }).join("\n");
  }
  function highlightJson(src) {
    const re = /("(?:\\.|[^"\\])*")(\s*:)?|(-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b)|\b(true|false|null)\b/g;
    let out = "", last = 0, m;
    while ((m = re.exec(src))) {
      out += esc(src.slice(last, m.index)); last = re.lastIndex;
      if (m[1]) out += m[2] ? wrap("key", m[1]) + esc(m[2]) : wrap("str", m[1]);
      else if (m[3]) out += wrap("num", m[3]);
      else out += wrap("kw", m[4]);
    }
    return out + esc(src.slice(last));
  }
  Book.highlight = { python: highlightPython, bash: highlightBash, yaml: highlightYaml, json: highlightJson };
  function highlightAll(root) {
    root.querySelectorAll("pre code[class*='language-']").forEach((code) => {
      if (code.dataset.hl) return;
      const lang = (code.className.match(/language-(\w+)/) || [])[1];
      const alias = { py: "python", sh: "bash", shell: "bash", console: "bash", yml: "yaml" };
      const fn = Book.highlight[alias[lang] || lang];
      if (!fn) return;
      code.innerHTML = fn(code.textContent);
      code.dataset.hl = "1";
    });
  }

  /* ---------------- copy buttons ---------------- */
  function addCopyButtons(root) {
    root.querySelectorAll("pre").forEach((pre) => {
      if (pre.classList.contains("output") || pre.querySelector(".copy-btn")) return;
      const btn = el("button", { class: "copy-btn", type: "button", "aria-label": "Copy code", text: "Copy" });
      btn.addEventListener("click", async () => {
        const code = pre.querySelector("code") || pre;
        const text = code.innerText.replace(/\n$/, "");
        let ok = false;
        try { await navigator.clipboard.writeText(text); ok = true; } catch (e) {
          const ta = el("textarea"); ta.value = text; ta.style.position = "fixed"; ta.style.opacity = "0";
          document.body.append(ta); ta.select();
          try { ok = document.execCommand("copy"); } catch (e2) { ok = false; }
          ta.remove();
        }
        btn.textContent = ok ? "Copied" : "Press Ctrl+C";
        btn.classList.toggle("done", ok);
        setTimeout(() => { btn.textContent = "Copy"; btn.classList.remove("done"); }, 1600);
      });
      pre.append(btn);
    });
  }

  /* ---------------- headings, chrome, sidebar ---------------- */
  function slugify(s) { return s.toLowerCase().replace(/<[^>]+>/g, "").replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 60); }
  function headingText(h) {
    const c = h.cloneNode(true);
    c.querySelectorAll(".anchor, .cite").forEach((x) => x.remove());
    return c.textContent.trim();
  }
  function buildChrome() {
    const main = document.querySelector("main");
    if (!main) return;
    const isCover = main.classList.contains("cover");

    // headings: ensure ids, add anchors
    const used = new Set();
    const heads = Array.from(main.querySelectorAll("h2, h3")).filter((h) => !h.closest("aside, figure, details, .objectives"));
    heads.forEach((h) => {
      if (!h.id) { let id = slugify(h.textContent) || "section"; while (used.has(id) || document.getElementById(id)) id += "-x"; h.id = id; }
      used.add(h.id);
      if (!h.querySelector(".anchor")) h.append(el("a", { class: "anchor", href: "#" + h.id, "aria-label": "Link to this section", text: "#" }));
    });

    // top bar
    const menuBtn = el("button", { type: "button", "aria-label": "Toggle sidebar", title: "Contents (t)", text: "\u2630" });
    const themeBtn = el("button", { type: "button", "aria-label": "Toggle dark mode", title: "Toggle theme" });
    const setThemeLabel = () => { themeBtn.textContent = currentTheme() === "dark" ? "\u2600" : "\u263E"; };
    setThemeLabel();
    themeBtn.addEventListener("click", () => {
      const next = currentTheme() === "dark" ? "light" : "dark";
      document.documentElement.setAttribute("data-theme", next);
      store.set("evalbook-theme", next); setThemeLabel();
    });
    const chapTitle = Book.current ? (Book.current.n ? `${Book.current.n}. ${Book.current.title}` : Book.current.title) : "";
    const topbar = el("header", { class: "topbar" }, menuBtn,
      el("a", { class: "book-title", href: "index.html", text: Book.title }),
      el("span", { class: "chap-title", text: chapTitle ? "/ " + chapTitle : "" }), themeBtn);
    const progress = el("div", { class: "progress", "aria-hidden": "true" });
    document.body.prepend(topbar, progress);

    // sidebar
    const chapList = el("ol", { class: "chap-list" });
    Book.chapters.forEach((c) => {
      const a = el("a", { href: c.file }, el("span", { class: "n", text: c.n ? String(c.n) : "\u2022" }), el("span", { text: c.title }));
      if (Book.current && c.file === Book.current.file) a.classList.add("current");
      chapList.append(el("li", null, a));
    });
    const sidebar = el("nav", { class: "sidebar", "aria-label": "Book navigation" });
    if (heads.length && !isCover) {
      const toc = el("ul", { class: "page-toc" });
      heads.forEach((h) => {
        toc.append(el("li", { class: h.tagName === "H3" ? "toc-h3" : "toc-h2" }, el("a", { href: "#" + h.id, text: headingText(h) })));
      });
      sidebar.append(el("h4", { text: "On this page" }), toc);
    }
    sidebar.append(el("h4", { text: "Chapters" }), chapList, el("h4", { text: "Book" }),
      el("ul", null, el("li", null, el("a", { href: "index.html", text: "Cover and contents" }))));
    const scrim = el("div", { class: "scrim" });
    document.body.append(sidebar, scrim);

    const wide = () => matchMedia("(min-width: 1180px)").matches;
    const toggle = () => {
      if (wide()) { document.body.classList.toggle("sidebar-closed"); store.set("evalbook-sidebar", document.body.classList.contains("sidebar-closed") ? "closed" : "open"); }
      else document.body.classList.toggle("sidebar-open");
    };
    if (isCover || store.get("evalbook-sidebar") === "closed") document.body.classList.add("sidebar-closed");
    menuBtn.addEventListener("click", toggle);
    scrim.addEventListener("click", () => document.body.classList.remove("sidebar-open"));
    sidebar.addEventListener("click", (e) => { if (e.target.closest("a") && !wide()) document.body.classList.remove("sidebar-open"); });
    document.addEventListener("keydown", (e) => {
      if (e.target.closest("input, textarea, select, [contenteditable]")) return;
      if (e.key === "t" && !e.metaKey && !e.ctrlKey && !e.altKey) toggle();
      if (e.key === "Escape") document.body.classList.remove("sidebar-open");
    });

    // scroll spy + progress
    const tocLinks = new Map(Array.from(sidebar.querySelectorAll(".page-toc a")).map((a) => [a.getAttribute("href").slice(1), a]));
    let ticking = false;
    const onScroll = () => {
      ticking = false;
      const y = window.scrollY + 90;
      let cur = null;
      for (const h of heads) { if (h.offsetTop <= y) cur = h; else break; }
      tocLinks.forEach((a) => a.classList.remove("active"));
      if (cur && tocLinks.get(cur.id)) tocLinks.get(cur.id).classList.add("active");
      const max = document.documentElement.scrollHeight - innerHeight;
      progress.style.width = (max > 0 ? Math.min(100, (100 * window.scrollY) / max) : 0) + "%";
    };
    addEventListener("scroll", () => { if (!ticking) { ticking = true; requestAnimationFrame(onScroll); } }, { passive: true });
    onScroll();

    // prev / next
    if (Book.current && document.body.dataset.nav !== "off") {
      const i = Book.chapters.indexOf(Book.current);
      const prev = Book.chapters[i - 1], next = Book.chapters[i + 1];
      const nav = el("nav", { class: "chapter-nav", "aria-label": "Chapter navigation" });
      const label = (c) => (c.n ? `${c.n}. ${c.title}` : c.title);
      if (prev) nav.append(el("a", { class: "prev", href: prev.file }, el("span", { class: "dir", text: "\u2190 Previous" }), el("span", { class: "t", text: label(prev) })));
      else nav.append(el("a", { class: "prev", href: "index.html" }, el("span", { class: "dir", text: "\u2190 Cover" }), el("span", { class: "t", text: "Contents" })));
      if (next) nav.append(el("a", { class: "next", href: next.file }, el("span", { class: "dir", text: "Next \u2192" }), el("span", { class: "t", text: label(next) })));
      main.after(nav);
    }
  }

  /* ---------------- cover TOC ---------------- */
  function renderBookToc() {
    document.querySelectorAll("ol[data-book-toc]").forEach((ol) => {
      if (ol.children.length) return; // static fallback already present
      Book.chapters.forEach((c) => {
        const a = el("a", { class: "card", href: c.file },
          el("span", { class: "num", text: c.n ? String(c.n).padStart(2, "0") : "R" }),
          el("span", { class: "t", text: c.title }), el("span", { class: "b", text: c.blurb }));
        ol.append(el("li", null, a));
      });
    });
  }

  function init() {
    renderBookToc();
    buildChrome();
    highlightAll(document);
    addCopyButtons(document);
    if (location.hash) { const t = document.getElementById(decodeURIComponent(location.hash.slice(1))); if (t) setTimeout(() => t.scrollIntoView(), 0); }
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init); else init();
})();
