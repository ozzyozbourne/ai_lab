#!/usr/bin/env python3
"""Build references.html: a de-duplicated bibliography of every <ol class="sources"> entry in the chapters.

Usage: python3 tools/build_references.py   (run from anywhere; writes ../references.html)

Each chapter cites sources as <li id="src-N"> items in its "Sources" section. Entries are merged on a
normalised URL (arXiv id, GitHub owner/repo, DOI, otherwise scheme-less URL), grouped into four themes
(papers, benchmarks and datasets, repositories and tools, articles and guides) and listed with links back
to every chapter citation.
"""
import html
import pathlib
import re
from urllib.parse import urlparse

ROOT = pathlib.Path(__file__).resolve().parent.parent
CHAPTERS = sorted(ROOT.glob("[01][0-9]-*.html"))

LI_RE = re.compile(r'<li id="(src-\d+)">(.*?)</li>', re.S)
HREF_RE = re.compile(r'href="([^"]+)"')
TITLE_RE = re.compile(r"&ldquo;(.*?)&rdquo;", re.S)
TAG_RE = re.compile(r"<[^>]+>")

PAPER_HOSTS = {"arxiv.org", "doi.org", "aclanthology.org", "proceedings.mlr.press", "openreview.net",
               "proceedings.neurips.cc", "papers.nips.cc", "dl.acm.org", "www.nature.com", "nature.com",
               "jmlr.org", "www.jmlr.org", "ojs.aaai.org", "www.science.org", "link.springer.com",
               "www.jstor.org", "academic.oup.com", "onlinelibrary.wiley.com", "www.tandfonline.com",
               "openaccess.thecvf.com", "ieeexplore.ieee.org", "www.semanticscholar.org"}
TOOL_HOSTS = {"github.com", "pypi.org", "docs.ragas.io", "deepeval.com", "inspect.aisi.org.uk", "docs.vllm.ai",
              "docs.sglang.ai", "docs.harborframework.com", "gymnasium.farama.org", "farama.org", "opentelemetry.io",
              "www.promptfoo.dev", "promptfoo.dev", "docs.confident-ai.com", "www.braintrust.dev",
              "docs.smith.langchain.com", "langfuse.com", "arize.com", "docs.arize.com", "phoenix.arize.com",
              "pytorch.org", "numpy.org", "docs.scipy.org", "www.statsmodels.org", "scikit-learn.org"}
BENCH_RE = re.compile(r"bench|leaderboard|\barena\b|dataset|\bexam\b|\bsuite\b|\bMMLU|GPQA|HumanEval|GSM8K|"
                      r"\bMATH\b|TruthfulQA|HellaSwag|\bBBQ\b|WMDP|\bARC-AGI|BIG-bench|OSWorld|WebArena|"
                      r"tau-?bench|τ-bench|SWE-|Terminal-Bench|\bHELM\b|corpus|test set|gaia\b", re.I)
THEMES = [("papers", "Papers"), ("benchmarks", "Benchmarks, datasets and leaderboards"),
          ("tools", "Repositories, libraries and tools"), ("articles", "Articles, guides and reports")]


def norm_key(url: str) -> str:
    u = urlparse(url)
    host = u.netloc.lower().removeprefix("www.")
    path = u.path.rstrip("/")
    if host in ("arxiv.org", "export.arxiv.org"):
        m = re.search(r"(\d{4}\.\d{4,5}|[a-z\-]+(?:\.[A-Z]{2})?/\d{7})", path)
        if m:
            return "arxiv:" + m.group(1)
    if host == "github.com":
        parts = [p for p in path.split("/") if p]
        if len(parts) >= 2:
            return "gh:" + "/".join(parts[:2]).lower().removesuffix(".git")
    if host == "doi.org":
        return "doi:" + path.lstrip("/").lower()
    return host + path + (("?" + u.query) if u.query else "")


def classify(url: str, body_text: str) -> str:
    host = urlparse(url).netloc.lower()
    m = TITLE_RE.search(body_text)
    title = TAG_RE.sub("", m.group(1)) if m else ""
    hosts = {urlparse(u).netloc.lower() for u in HREF_RE.findall(body_text)}
    if title and hosts & PAPER_HOSTS:  # a titled paper, possibly with a companion repository
        return "benchmarks" if BENCH_RE.search(title) else "papers"
    if host in TOOL_HOSTS or host.endswith(".readthedocs.io"):
        parts = [p for p in urlparse(url).path.split("/") if p]
        if host == "github.com" and len(parts) >= 2 and BENCH_RE.search(parts[1]):
            return "benchmarks"  # benchmark repositories are filed with benchmarks
        return "tools"
    if title and BENCH_RE.search(title):
        return "benchmarks"
    if host in PAPER_HOSTS:
        return "papers"
    return "articles"


def sort_key(body: str) -> str:
    return TAG_RE.sub("", html.unescape(body)).strip().lower()


def main() -> None:
    entries: dict[str, dict] = {}
    order = []
    chapter_titles = {}
    for f in CHAPTERS:
        s = f.read_text(encoding="utf-8")
        num = int(f.name[:2])
        t = re.search(r"<h1>(.*?)</h1>", s, re.S)
        chapter_titles[num] = TAG_RE.sub("", t.group(1)).strip() if t else f.name
        m = re.search(r'<ol class="sources">(.*?)</ol>', s, re.S)
        if not m:
            continue
        for sid, body in LI_RE.findall(m.group(1)):
            body = body.strip()
            urls = HREF_RE.findall(body)
            if not urls:
                continue
            key = norm_key(urls[0])
            e = entries.get(key)
            if e is None:
                e = entries[key] = {"bodies": [], "cites": [], "url": urls[0]}
                order.append(key)
            e["bodies"].append(body)
            e["cites"].append((num, f.name, sid))
    groups = {k: [] for k, _ in THEMES}
    for key in order:
        e = entries[key]
        body = max(e["bodies"], key=len)  # the most detailed description wins
        e["body"] = body
        groups[classify(e["url"], body)].append(e)

    total_cites = sum(len(e["cites"]) for e in entries.values())
    out = []
    w = out.append
    w("""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>References · Evaluations for AI</title>
<meta name="description" content="Every source cited in the book, de-duplicated and grouped by theme, with links back to each chapter that cites it.">
<link rel="stylesheet" href="assets/book.css">
<style>
  /* references page only */
  .ref-filter { width: 100%; font: inherit; font-family: var(--font-ui); padding: .55rem .8rem; border: 1px solid var(--border);
    border-radius: var(--radius); background: var(--bg-elev); color: var(--text); margin: .4rem 0 1rem; box-sizing: border-box; }
  ol.sources li .cited-in { display: block; font-family: var(--font-ui); font-size: .78rem; color: var(--text-dim); margin-top: .15rem; }
  ol.sources li .cited-in a { margin-right: .35rem; white-space: nowrap; }
  ol.sources li[hidden] { display: none; }
  .ref-stats { font-family: var(--font-ui); font-size: .9rem; color: var(--text-dim); }
  table.ref-ch td:last-child, table.ref-ch th:last-child { text-align: right; }
</style>
<script defer src="assets/book.js"></script>
</head>
<body>
<main>
  <p class="kicker">Back matter</p>
  <h1>References</h1>
""")
    w(f"""  <p class="lede">Every source cited in the ten chapters, merged into one list: {len(entries)} distinct sources behind
  {total_cites} chapter citations. Entries are grouped by kind, sorted alphabetically within each group, and each one links back to
  the numbered citation in every chapter that uses it, so you can see where an idea is applied. Star counts and dates are as the
  chapters recorded them in November 2026.</p>
  <p class="ref-stats">Generated by <code>tools/build_references.py</code> from the chapters' Sources sections; rerun it after editing a chapter.</p>
  <label for="ref-filter" class="ref-stats">Filter (author, title, venue, year):</label>
  <input id="ref-filter" class="ref-filter" type="search" placeholder="e.g. SWE-bench, Bradley-Terry, 2025, Anthropic" autocomplete="off">
""")
    w('  <h2 id="by-chapter">Sources per chapter</h2>\n  <table class="ref-ch">\n    <thead><tr><th>Chapter</th><th>Sources cited</th></tr></thead>\n    <tbody>\n')
    per_ch = {}
    for e in entries.values():
        for num, _, _ in e["cites"]:
            per_ch[num] = per_ch.get(num, 0) + 1
    for f in CHAPTERS:
        num = int(f.name[:2])
        w(f'      <tr><td><a href="{f.name}#sources">{num}. {html.escape(chapter_titles[num])}</a></td><td>{per_ch.get(num, 0)}</td></tr>\n')
    w("    </tbody>\n  </table>\n")
    w('  <p>Jump to: ' + " &middot; ".join(f'<a href="#{k}">{lab} ({len(groups[k])})</a>' for k, lab in THEMES) + "</p>\n")
    for k, lab in THEMES:
        items = sorted(groups[k], key=lambda e: sort_key(e["body"]))
        w(f'\n  <h2 id="{k}">{lab}</h2>\n  <ol class="sources">\n')
        for i, e in enumerate(items, 1):
            seen, links = set(), []
            for num, fname, sid in e["cites"]:
                if (num, sid) in seen:
                    continue
                seen.add((num, sid))
                links.append(f'<a href="{fname}#{sid}">Ch.&nbsp;{num}&nbsp;[{sid[4:]}]</a>')
            w(f'    <li id="{k}-{i}">{e["body"]}<span class="cited-in">Cited in: {"".join(links)}</span></li>\n')
        w("  </ol>\n")
    w("""</main>
<script>
  (function () {
    var box = document.getElementById("ref-filter");
    if (!box) return;
    var items = Array.prototype.slice.call(document.querySelectorAll("ol.sources li"));
    box.addEventListener("input", function () {
      var q = box.value.trim().toLowerCase();
      items.forEach(function (li) { li.hidden = q !== "" && li.textContent.toLowerCase().indexOf(q) === -1; });
    });
  })();
</script>
</body>
</html>
""")
    (ROOT / "references.html").write_text("".join(out), encoding="utf-8")
    print(f"references.html: {len(entries)} sources, {total_cites} citations; " +
          ", ".join(f"{k}={len(groups[k])}" for k, _ in THEMES))


if __name__ == "__main__":
    main()
