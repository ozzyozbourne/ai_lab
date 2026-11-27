#!/usr/bin/env python3
"""Copy example files and JSON data into a chapter page so page and scripts never drift.

Usage (from anywhere):
    python3 tools/sync_examples.py chapters/05-first-simulation.html [more.html ...]
    python3 tools/sync_examples.py --all

What it rewrites, in place:
  1. <figure class="code-example" data-file="exNN_name.py"> ... <pre><code class="language-python">...</code></pre>
     The first <pre><code> inside the figure gets the HTML-escaped content of
     examples/<slug>/exNN_name.py. Figures with data-excerpt="true" are left alone (the checker then
     verifies that every line of the excerpt occurs in the file instead).
  2. <script type="application/json" id="..." data-json-file="examples/<slug>/data/x.json"></script>
     The script body becomes the JSON file's content (path relative to the course root). "</" is escaped.

Only the standard library is used. The slug is the HTML file name without ".html".
"""
from __future__ import annotations

import argparse
import html
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

FIG_RE = re.compile(
    r'(<figure\b[^>]*\bclass="[^"]*\bcode-example\b[^"]*"[^>]*>)(.*?)(</figure>)', re.S)
CODE_RE = re.compile(r'(<pre>\s*<code\b[^>]*>)(.*?)(</code>\s*</pre>)', re.S)
ATTR_RE = re.compile(r'\b([\w-]+)="([^"]*)"')
JSON_RE = re.compile(
    r'(<script\b[^>]*\btype="application/json"[^>]*\bdata-json-file="([^"]+)"[^>]*>)(.*?)(</script>)', re.S)


def attrs(tag: str) -> dict[str, str]:
    return {k: v for k, v in ATTR_RE.findall(tag)}


def sync(page: pathlib.Path) -> list[str]:
    slug = page.stem
    text = page.read_text(encoding="utf-8")
    notes: list[str] = []

    def fig_sub(m: re.Match) -> str:
        open_tag, body, close = m.groups()
        a = attrs(open_tag)
        name = a.get("data-file")
        if not name or a.get("data-excerpt") == "true":
            return m.group(0)
        src = ROOT / "examples" / slug / name
        if not src.exists():
            notes.append(f"MISSING example file: {src.relative_to(ROOT)}")
            return m.group(0)
        code = html.escape(src.read_text(encoding="utf-8").rstrip("\n"), quote=False)
        new_body, n = CODE_RE.subn(lambda c: c.group(1) + code + c.group(3), body, count=1)
        if n == 0:
            notes.append(f"no <pre><code> in figure for {name}")
            return m.group(0)
        notes.append(f"synced {name}")
        return open_tag + new_body + close

    def json_sub(m: re.Match) -> str:
        open_tag, rel, _body, close = m.groups()
        src = ROOT / rel
        if not src.exists():
            notes.append(f"MISSING json file: {rel}")
            return m.group(0)
        data = json.loads(src.read_text(encoding="utf-8"))
        payload = json.dumps(data, separators=(",", ":")).replace("</", "<\\/")
        kb = len(payload) / 1024
        notes.append(f"embedded {rel} ({kb:.1f} KB)" + ("  WARNING: > 300 KB" if kb > 300 else ""))
        return open_tag + payload + close

    text = FIG_RE.sub(fig_sub, text)
    text = JSON_RE.sub(json_sub, text)
    page.write_text(text, encoding="utf-8")
    return notes


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("pages", nargs="*", help="chapter html files")
    ap.add_argument("--all", action="store_true", help="every chapters/*.html")
    args = ap.parse_args()
    pages = [pathlib.Path(p).resolve() for p in args.pages]
    if args.all:
        pages = sorted((ROOT / "chapters").glob("*.html"))
    if not pages:
        ap.error("give chapter files or --all")
    bad = False
    for p in pages:
        print(f"== {p.relative_to(ROOT)}")
        for n in sync(p):
            bad |= n.startswith("MISSING")
            print("  " + n)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
