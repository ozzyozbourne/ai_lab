#!/usr/bin/env python3
"""Check a chapter page for broken links, missing files, example/page drift and the visual budget.

Usage:
    python3 tools/check_chapter.py chapters/05-first-simulation.html [more.html ...]
    python3 tools/check_chapter.py --all            # every chapters/*.html (skips _template unless named)
    python3 tools/check_chapter.py --strict ...     # planned-but-missing pages become errors too

Exit code 0 when there are no ERRORs (WARNs are allowed). Standard library only.

Checks
  links     every local href/src resolves to a file (relative to the page); #anchors exist on the target page
            when the target is an existing local HTML file; links to planned pages (chapters in
            planning/course-plan.json, reference/*.html, notebooks/*.ipynb) that do not exist yet are WARN.
  ids       no duplicate id attributes.
  examples  every examples/<slug>/*.py has a <figure class="code-example" data-file="NAME"> whose code equals the
            file (whitespace-trimmed), or, with data-excerpt="true", whose every non-empty line occurs in the file.
            Every data-file names an existing file. Every example file is mentioned in notebooks/<slug>.ipynb.
  data      every <script type="application/json" data-json-file> exists and is embedded (non-empty, valid JSON).
  head      <title> is "Ch NN · ...", course.css and course.js are linked, CDN scripts pin an exact version.
  colab     the Open-in-Colab and Download links follow the course pattern for this slug.
  budget    >= 4 inline SVG diagrams (svg[role=img]), >= 2 animations, >= 2 interactive widgets,
            quiz with >= 6 questions, >= 2 auto-checked exercises + 1 stretch, source map, Stuck? link (WARN only).
"""
from __future__ import annotations

import argparse
import html
import html.parser
import json
import pathlib
import re
import sys
import urllib.parse

ROOT = pathlib.Path(__file__).resolve().parent.parent
COLAB = ("https://colab.research.google.com/github/ozzyozbourne/ai_lab/blob/main/"
         "dpdk-research/mujoco-warp-course/notebooks/{slug}.ipynb")
FIG_RE = re.compile(r'(<figure\b[^>]*\bclass="[^"]*\bcode-example\b[^"]*"[^>]*>)(.*?)</figure>', re.S)
CODE_RE = re.compile(r'<pre>\s*<code\b[^>]*>(.*?)</code>\s*</pre>', re.S)
ATTR_RE = re.compile(r'\b([\w-]+)="([^"]*)"')
EXAMPLE_NAME = re.compile(r"^ex\d+[a-z]?_[A-Za-z0-9_]+\.py$")


class Page(html.parser.HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.links: list[tuple[str, str, int]] = []   # (attr, value, line)
        self.ids: dict[str, int] = {}
        self.dup_ids: list[str] = []
        self.tags: list[tuple[str, dict, int]] = []
        self.title = ""
        self._in_title = False
        # code-example capture
        self.figs: list[dict] = []
        self._fig_depth = 0
        self._fig: dict | None = None
        self._depth = 0
        self._code_depth = 0
        self._json: dict | None = None
        self.jsons: list[dict] = []

    def handle_starttag(self, tag, attrs):
        a = {k: (v or "") for k, v in attrs}
        line = self.getpos()[0]
        self.tags.append((tag, a, line))
        if tag not in ("br", "img", "input", "meta", "link", "hr", "source", "col", "area", "wbr", "path",
                       "circle", "rect", "line", "polyline", "polygon", "ellipse", "stop", "use"):
            self._depth += 1
        if "id" in a:
            if a["id"] in self.ids:
                self.dup_ids.append(a["id"])
            self.ids[a["id"]] = line
        for k in ("href", "src"):
            if k in a and tag != "use":
                self.links.append((k, a[k], line))
        if tag == "title" and not self.title:
            self._in_title = True
        cls = a.get("class", "").split()
        if tag == "figure" and "code-example" in cls:
            self._fig = {"file": a.get("data-file"), "excerpt": a.get("data-excerpt") == "true", "code": None,
                         "line": line}
            self._fig_depth = self._depth
        if tag == "code" and self._fig is not None and self._fig["code"] is None:
            self._fig["code"] = ""
            self._code_depth = self._depth
        if tag == "script" and a.get("type") == "application/json" and "data-json-file" in a:
            self._json = {"file": a["data-json-file"], "body": "", "line": line, "id": a.get("id", "")}

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag not in ("br", "img", "input", "meta", "link", "hr", "source", "col", "area", "wbr", "path",
                       "circle", "rect", "line", "polyline", "polygon", "ellipse", "stop", "use"):
            self._depth -= 1

    def handle_endtag(self, tag):
        if tag == "title":
            self._in_title = False
        if tag == "code" and self._fig is not None and self._code_depth == self._depth:
            self._code_depth = -1
        if tag == "figure" and self._fig is not None and self._depth == self._fig_depth:
            self.figs.append(self._fig)
            self._fig = None
        if tag == "script" and self._json is not None:
            self.jsons.append(self._json)
            self._json = None
        if tag not in ("br", "img", "input", "meta", "link", "hr", "source", "col", "area", "wbr", "path",
                       "circle", "rect", "line", "polyline", "polygon", "ellipse", "stop", "use"):
            self._depth -= 1

    def handle_data(self, data):
        if self._in_title:
            self.title += data
        if self._fig is not None and self._fig["code"] is not None and self._code_depth == self._depth:
            self._fig["code"] += data
        if self._json is not None:
            self._json["body"] += data


def planned_slugs() -> set[str]:
    try:
        plan = json.loads((ROOT / "planning" / "course-plan.json").read_text(encoding="utf-8"))
        return {c["slug"] for c in plan["chapters"]}
    except Exception:
        return set()


def norm(s: str) -> str:
    return "\n".join(l.rstrip() for l in s.strip("\n").splitlines()).strip()


def check(page: pathlib.Path, strict: bool) -> tuple[list[str], list[str], list[str]]:
    errors: list[str] = []
    warns: list[str] = []
    info: list[str] = []
    slug = page.stem
    text = page.read_text(encoding="utf-8")
    p = Page()
    p.feed(text)
    planned = planned_slugs()
    p.figs = []
    for m in FIG_RE.finditer(text):
        a = dict(ATTR_RE.findall(m.group(1)))
        c = CODE_RE.search(m.group(2))
        p.figs.append({"file": a.get("data-file"), "excerpt": a.get("data-excerpt") == "true",
                       "code": html.unescape(re.sub(r"<[^>]+>", "", c.group(1))) if c else None,
                       "line": text.count("\n", 0, m.start()) + 1})
    rel = lambda path: str(path.resolve().relative_to(ROOT)) if str(path.resolve()).startswith(str(ROOT)) else str(path)

    # ---- links
    anchor_cache: dict[pathlib.Path, set[str]] = {}
    for attr, val, line in p.links:
        v = val.strip()
        if not v or v.startswith(("http://", "https://", "mailto:", "data:", "javascript:", "//", "tel:")):
            continue
        url = urllib.parse.urlsplit(v)
        if not url.path:
            frag = urllib.parse.unquote(url.fragment)
            if frag and frag not in p.ids:
                errors.append(f"line {line}: in-page anchor #{frag} has no matching id")
            continue
        target = (page.parent / urllib.parse.unquote(url.path)).resolve()
        if not target.exists():
            tr = rel(target)
            is_planned = (
                (tr.startswith("chapters/") and pathlib.Path(tr).stem in planned)
                or tr.startswith("reference/") or tr.startswith("notebooks/")
            )
            msg = f"line {line}: {attr}={v!r} -> {tr} does not exist"
            if is_planned and not strict:
                warns.append(msg + " (planned page)")
            else:
                errors.append(msg)
            continue
        if url.fragment and target.suffix == ".html":
            if target not in anchor_cache:
                q = Page()
                q.feed(target.read_text(encoding="utf-8"))
                anchor_cache[target] = set(q.ids)
            if urllib.parse.unquote(url.fragment) not in anchor_cache[target]:
                warns.append(f"line {line}: {v!r}: anchor not found in {rel(target)}")

    # ---- ids
    for d in sorted(set(p.dup_ids)):
        errors.append(f"duplicate id: {d}")

    # ---- examples
    ex_dir = ROOT / "examples" / slug
    files = sorted(ex_dir.glob("*.py")) if ex_dir.exists() else []
    by_file = {f["file"]: f for f in p.figs if f["file"]}
    for f in p.figs:
        if not f["file"]:
            warns.append(f"line {f['line']}: code-example without data-file")
        elif not (ex_dir / f["file"]).exists():
            errors.append(f"line {f['line']}: data-file {f['file']} not found in examples/{slug}/")
    nb_path = ROOT / "notebooks" / f"{slug}.ipynb"
    nb_text = ""
    if nb_path.exists():
        try:
            nb = json.loads(nb_path.read_text(encoding="utf-8"))
            nb_text = "\n".join("".join(c.get("source", [])) for c in nb.get("cells", []))
        except Exception as e:  # noqa: BLE001
            errors.append(f"notebook {rel(nb_path)} is not valid JSON: {e}")
    else:
        warns.append(f"notebook notebooks/{slug}.ipynb does not exist yet")
    for fp in files:
        name = fp.name
        if name.startswith("_") or name.startswith("my_env") or name in ("ppo_reference.py",):
            continue
        if not EXAMPLE_NAME.match(name):
            warns.append(f"example file name {name} does not match exNN_name.py")
        fig = by_file.get(name)
        if fig is None:
            errors.append(f"examples/{slug}/{name} has no <figure class=\"code-example\" data-file=\"{name}\">")
        else:
            code = norm(fig["code"] or "")
            src = norm(fp.read_text(encoding="utf-8"))
            if fig["excerpt"]:
                srclines = {l.strip() for l in src.splitlines()}
                missing = [l for l in code.splitlines() if l.strip() and l.strip() not in srclines
                           and l.strip() not in ("...", "# ...")]
                if missing:
                    errors.append(f"{name}: excerpt line not in file: {missing[0]!r}")
            elif code != src:
                errors.append(f"{name}: code block differs from the file (run tools/sync_examples.py)")
        if nb_text and name not in nb_text:
            warns.append(f"{name} is not mentioned in notebooks/{slug}.ipynb")

    # ---- json data
    for j in p.jsons:
        if not (ROOT / j["file"]).exists():
            errors.append(f"line {j['line']}: data-json-file {j['file']} does not exist")
        body = j["body"].strip()
        if not body:
            errors.append(f"line {j['line']}: JSON script #{j['id']} is empty (run tools/sync_examples.py)")
        else:
            try:
                json.loads(body)
            except Exception as e:  # noqa: BLE001
                errors.append(f"line {j['line']}: JSON script #{j['id']} invalid: {e}")
            if len(body) > 300 * 1024:
                warns.append(f"JSON script #{j['id']} is {len(body) // 1024} KB (> 300 KB)")

    # ---- head
    title = html.unescape(p.title.strip())
    if slug != "_template" and not re.match(r"^Ch \d{2} · .+", title):
        warns.append(f"<title> should be 'Ch NN · Title', got {title!r}")
    hrefs = [v for _, v, _ in p.links]
    if not any(v.endswith("assets/course.css") for v in hrefs):
        errors.append("assets/course.css is not linked")
    if not any(v.endswith("assets/course.js") for v in hrefs):
        errors.append("assets/course.js is not loaded")
    for v in hrefs:
        if "cdnjs.cloudflare.com" in v or "cdn.jsdelivr.net" in v or "unpkg.com" in v:
            if not re.search(r"/\d+\.\d+\.\d+/|@\d+\.\d+\.\d+", v):
                errors.append(f"CDN URL without an exact version: {v}")
        if v.startswith("http") and not re.match(
                r"https://(cdnjs\.cloudflare\.com|cdn\.jsdelivr\.net/npm/|unpkg\.com|fonts\.googleapis\.com|"
                r"fonts\.gstatic\.com|colab\.research\.google\.com|github\.com|mujoco\.readthedocs\.io|"
                r"nvidia\.github\.io|docs\.)", v):
            info.append(f"external link: {v}")

    # ---- colab
    if COLAB.format(slug=slug) not in hrefs:
        errors.append(f"Open-in-Colab link missing or wrong; expected {COLAB.format(slug=slug)}")
    if f"../notebooks/{slug}.ipynb" not in hrefs:
        errors.append(f"Download link ../notebooks/{slug}.ipynb missing")

    # ---- budget (warnings)
    classes = lambda t: t[1].get("class", "").split()
    n_svg = sum(1 for t in p.tags if t[0] == "svg" and t[1].get("role") == "img")
    n_anim = len(re.findall(r'class="[^"]*\banim-(?:flow|pulse|float|spin|blink|slide|swing|glow|grow-x)\b', text))
    n_anim_js = len(re.findall(r"MW\.(?:canvasAnim|replay|mini3d)\(|class=\"[^\"]*\breplay\b", text))
    n_anim_figs = sum(1 for t in p.tags if "data-anim" in t[1]) + n_anim_js + (1 if "@keyframes" in text else 0)
    n_widgets = (sum(1 for t in p.tags if "stepper" in classes(t) or "widget" in classes(t) or "tabs" in classes(t))
                 + sum(1 for t in p.tags if t[0] == "input" and t[1].get("type") == "range")
                 + len(re.findall(r'\bclass="[^"]*\bhot\b', text)))
    n_q = sum(1 for t in p.tags if "quiz-q" in classes(t))
    n_auto = sum(1 for t in p.tags if "ex-level" in classes(t) and "auto" in classes(t))
    n_stretch = sum(1 for t in p.tags if "ex-level" in classes(t) and "stretch" in classes(t))
    info.append(f"svg diagrams={n_svg} animated figures={n_anim_figs} (anim classes={n_anim}) "
                f"interactive={n_widgets} quiz questions={n_q} auto exercises={n_auto} stretch={n_stretch} "
                f"code examples={len(p.figs)}")
    if slug != "_template":
        if n_svg < 4:
            warns.append(f"only {n_svg} inline SVG diagrams with role=img (need >= 4)")
        if n_anim_figs < 2:
            warns.append(f"only {n_anim_figs} animated figures (need >= 2)")
        if n_widgets < 2:
            warns.append("fewer than 2 interactive widgets")
        if n_q < 6:
            warns.append(f"quiz has {n_q} questions (need >= 6)")
        if n_auto < 2 or n_stretch < 1:
            warns.append(f"exercises: {n_auto} auto-checked, {n_stretch} stretch (need >= 2 and >= 1)")
    if 'class="source-map"' not in text:
        warns.append("no Source map table (table.source-map)")
    if "reference/troubleshooting.html" not in text:
        warns.append("no 'Stuck?' link to reference/troubleshooting.html")
    if "recap" not in text:
        warns.append("no recap block")
    return errors, warns, info


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("pages", nargs="*")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--strict", action="store_true", help="planned-but-missing pages are errors")
    ap.add_argument("-q", "--quiet", action="store_true", help="print only errors and warnings")
    args = ap.parse_args()
    pages = [pathlib.Path(x).resolve() for x in args.pages]
    if args.all:
        pages = sorted(p for p in (ROOT / "chapters").glob("*.html") if not p.name.startswith("_"))
    if not pages:
        ap.error("give chapter files or --all")
    total_err = 0
    for page in pages:
        errors, warns, info = check(page, args.strict)
        total_err += len(errors)
        status = "FAIL" if errors else "ok"
        print(f"== {page.name}: {status} ({len(errors)} errors, {len(warns)} warnings)")
        for e in errors:
            print("  ERROR " + e)
        for w in warns:
            print("  WARN  " + w)
        if not args.quiet:
            for i in info:
                print("  info  " + i)
    return 1 if total_err else 0


if __name__ == "__main__":
    sys.exit(main())
