#!/usr/bin/env python3
"""Regenerate the generated parts of index.html from planning/course-plan.json.

Usage:  python3 tools/build_index.py

Rewrites the text between these markers in index.html (everything else is hand-written):
  <!-- CHAPTERS:BEGIN --> ... <!-- CHAPTERS:END -->   chapter list grouped by level
  <!-- HERO:BEGIN --> ... <!-- HERO:END -->           the animated many-worlds hero SVG
Chapters whose page does not exist yet are still listed (marked "coming soon") so the course map is complete.
"""
from __future__ import annotations

import html
import json
import pathlib
import random
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
LEVELS = [
    ("beginner", "Beginner", "Physics, MuJoCo, Warp and your first thousands of worlds."),
    ("intermediate", "Intermediate", "The pipeline, resets and control, contacts, domain randomization."),
    ("advanced", "Advanced", "Inside the dynamics and the first half of collision detection."),
    ("expert", "Expert", "Convex collision, the solver, soft bodies, performance, interop and RL at scale."),
]
PARTS = [(1, 7, "I"), (8, 10, "II"), (11, 14, "III"), (15, 18, "IV"), (19, 23, "V"), (24, 30, "VI")]


def part_of(num: int) -> str:
    for a, b, name in PARTS:
        if a <= num <= b:
            return name
    return ""


def chapters_html(chapters: list[dict]) -> str:
    out = []
    for key, label, blurb in LEVELS:
        group = [c for c in chapters if c["level"] == key]
        if not group:
            continue
        out.append(f'<section class="level-group" id="level-{key}">')
        out.append(f'  <h2><span class="badge level-{key}">{label}</span> {len(group)} chapters</h2>')
        out.append(f'  <p class="muted">{html.escape(blurb)}</p>')
        out.append('  <ol class="chapter-list">')
        for c in group:
            slug = c["slug"]
            exists = (ROOT / "chapters" / f"{slug}.html").exists()
            soon = "" if exists else ' <span class="badge illustrative">coming soon</span>'
            out.append(
                f'    <li><a class="chapter-item" data-slug="{slug}" href="chapters/{slug}.html">'
                f'<span class="n">{c["num"]:02d}</span>'
                f'<div><h3>{html.escape(c["title"])}{soon}</h3>'
                f'<p>Part {part_of(c["num"])} · {html.escape(c["summary"])}</p></div>'
                f'<span class="done-mark" aria-hidden="true"></span></a></li>')
        out.append("  </ol>")
        out.append("</section>")
    return "\n".join(out)


def hero_svg() -> str:
    """A 8x5 grid of pendulums (one per world) all advancing on the same tick, with different phases."""
    rnd = random.Random(7)
    cols, rows, cw, ch = 8, 5, 60, 64
    W, H = cols * cw + 20, rows * ch + 70
    g = [f'<svg viewBox="0 0 {W} {H}" role="img" aria-labelledby="hero-t hero-d" class="hero-worlds">',
         '<title id="hero-t">Forty worlds simulated by one kernel launch</title>',
         '<desc id="hero-d">A grid of forty pendulums, one per world, each colored by its world index and swinging '
         'with a slightly different initial angle, while a pulse sweeps across them to show a single launch.</desc>',
         f'<rect x="1" y="1" width="{W - 2}" height="{H - 2}" rx="18" class="s-box-2"/>',
         f'<text x="20" y="32" class="s-label">mjw.step(m, d)</text>',
         f'<text x="{W - 20}" y="32" text-anchor="end" class="s-small s-mono">nworld = {cols * rows}</text>',
         f'<rect x="10" y="44" width="70" height="{H - 54}" rx="10" class="s-accent anim-sweep-x" opacity=".12"/>']
    for r in range(rows):
        for c in range(cols):
            k = r * cols + c
            px, py = 10 + c * cw + cw / 2, 52 + r * ch
            amp = 18 + 22 * rnd.random()
            delay = -2.2 * rnd.random()
            L = ch * 0.62
            g.append(
                f'<g class="anim-swing" style="transform-origin:{px:.1f}px {py:.1f}px;--a0:{-amp:.0f}deg;'
                f'--a1:{amp:.0f}deg;animation-delay:{delay:.2f}s">'
                f'<line x1="{px:.1f}" y1="{py:.1f}" x2="{px:.1f}" y2="{py + L:.1f}" class="s-line"/>'
                f'<circle cx="{px:.1f}" cy="{py + L:.1f}" r="7" class="s-w{k % 8}"/></g>')
            g.append(f'<circle cx="{px:.1f}" cy="{py:.1f}" r="2" class="s-muted"/>')
    g.append("</svg>")
    return "\n".join(g)


def replace(text: str, name: str, body: str) -> str:
    pat = re.compile(rf"(<!-- {name}:BEGIN -->)(.*?)(<!-- {name}:END -->)", re.S)
    if not pat.search(text):
        raise SystemExit(f"marker {name} not found in index.html")
    return pat.sub(lambda m: m.group(1) + "\n" + body + "\n" + m.group(3), text)


def main() -> None:
    plan = json.loads((ROOT / "planning" / "course-plan.json").read_text(encoding="utf-8"))
    idx = ROOT / "index.html"
    text = idx.read_text(encoding="utf-8")
    text = replace(text, "CHAPTERS", chapters_html(plan["chapters"]))
    text = replace(text, "HERO", hero_svg())
    idx.write_text(text, encoding="utf-8")
    print(f"index.html: {len(plan['chapters'])} chapters")


if __name__ == "__main__":
    main()
