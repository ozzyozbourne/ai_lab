#!/usr/bin/env python3
"""Check the book's HTML: parse every file, and verify that every local href/src resolves.

Usage: python3 tools/check_links.py      exit code 1 if anything is broken

Checks, for every *.html file under the book root (excluding research/ and code/):
  * the file parses with html.parser without unbalanced block tags (a light check: html, head, body, main,
    section, div, ol, ul, table, pre, figure, svg must open and close in order);
  * duplicate id attributes;
  * every local href/src (not http(s):, mailto:, data:, javascript:) points to an existing file, and its
    #fragment, if any, to an id in that file;
  * the navigation manifest in assets/book.js lists files that exist, and index.html links every chapter.
"""
import pathlib
import re
import sys
from html.parser import HTMLParser
from urllib.parse import unquote, urlparse

ROOT = pathlib.Path(__file__).resolve().parent.parent
CHECKED_BLOCKS = {"html", "head", "body", "main", "section", "div", "ol", "ul", "table", "pre", "figure",
                  "svg", "details", "nav", "aside", "thead", "tbody", "blockquote", "header", "footer"}
VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"}


class Page(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.ids, self.dup_ids, self.links, self.stack, self.errors = set(), set(), [], [], []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if a.get("id"):
            (self.dup_ids if a["id"] in self.ids else self.ids).add(a["id"])
        if a.get("name") and tag == "a":
            self.ids.add(a["name"])
        for k in ("href", "src"):
            if a.get(k) is not None and tag not in ("base",):
                self.links.append((a[k], self.getpos()[0]))
        if tag in CHECKED_BLOCKS:
            self.stack.append((tag, self.getpos()[0]))

    def handle_startendtag(self, tag, attrs):
        # self-closing (<path/>) never affects the stack
        a = dict(attrs)
        if a.get("id"):
            (self.dup_ids if a["id"] in self.ids else self.ids).add(a["id"])
        for k in ("href", "src"):
            if a.get(k) is not None:
                self.links.append((a[k], self.getpos()[0]))

    def handle_endtag(self, tag):
        if tag not in CHECKED_BLOCKS:
            return
        if self.stack and self.stack[-1][0] == tag:
            self.stack.pop()
            return
        self.errors.append(f"line {self.getpos()[0]}: </{tag}> does not match open "
                           f"<{self.stack[-1][0]}> from line {self.stack[-1][1]}" if self.stack else
                           f"line {self.getpos()[0]}: stray </{tag}>")
        for i in range(len(self.stack) - 1, -1, -1):  # recover
            if self.stack[i][0] == tag:
                del self.stack[i:]
                break


def parse(path):
    p = Page()
    p.feed(path.read_text(encoding="utf-8"))
    p.close()
    for tag, line in p.stack:
        p.errors.append(f"<{tag}> opened on line {line} is never closed")
    return p


def main() -> int:
    files = sorted(f for f in ROOT.rglob("*.html") if not ({"research", "code", "tools"} & set(f.relative_to(ROOT).parts)))
    pages = {f: parse(f) for f in files}
    problems = []
    nlinks = 0
    for f, p in pages.items():
        rel = f.relative_to(ROOT)
        for e in p.errors:
            problems.append(f"{rel}: parse: {e}")
        for d in sorted(p.dup_ids):
            problems.append(f"{rel}: duplicate id '{d}'")
        if rel.as_posix() == "assets/chapter-template.html":
            continue  # a template meant to be copied to the book root; its links resolve from there
        for link, line in p.links:
            u = urlparse(link)
            if u.scheme in ("http", "https", "mailto", "data", "javascript") or link.startswith("//"):
                continue
            nlinks += 1
            target = f if not u.path else (f.parent / unquote(u.path)).resolve()
            if not target.exists():
                problems.append(f"{rel}:{line}: missing file '{link}'")
                continue
            if u.fragment and target.suffix == ".html":
                tp = pages.get(target) or parse(target)
                if unquote(u.fragment) not in tp.ids:
                    problems.append(f"{rel}:{line}: missing anchor '{link}'")
    # manifest and index
    js = (ROOT / "assets" / "book.js").read_text(encoding="utf-8")
    manifest = re.findall(r'file:\s*"([^"]+)"', js)
    for m in manifest:
        if not (ROOT / m).exists():
            problems.append(f"assets/book.js: manifest lists missing file '{m}'")
    index = (ROOT / "index.html").read_text(encoding="utf-8")
    for m in manifest:
        if f'href="{m}"' not in index:
            problems.append(f"index.html: does not link '{m}'")
    # chapter <h1> titles should match the manifest titles
    titles = dict(re.findall(r'file:\s*"([^"]+)",\s*title:\s*"([^"]+)"', js))
    for m, t in titles.items():
        if (ROOT / m).exists():
            h1 = re.search(r"<h1>(.*?)</h1>", (ROOT / m).read_text(encoding="utf-8"), re.S)
            if h1 and re.sub(r"<[^>]+>", "", h1.group(1)).strip() != t:
                problems.append(f"{m}: <h1> differs from manifest title '{t}'")
            if f">{t}<" not in index.replace("&amp;", "&") and m != "references.html":
                problems.append(f"index.html: card title for '{m}' differs from manifest")
    for pr in problems:
        print(pr)
    print(f"checked {len(files)} HTML files, {nlinks} local links, manifest {len(manifest)} entries: "
          f"{len(problems)} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
