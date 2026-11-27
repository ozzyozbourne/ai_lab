#!/usr/bin/env python3
"""Build a Colab notebook (.ipynb, nbformat 4) from a simple cell spec, so nobody hand-writes notebook JSON.

Usage:
    python3 tools/make_notebook.py SPEC [-o notebooks/<slug>.ipynb]

SPEC is either
  * a JSON file:  {"slug": "05-first-simulation", "title": "Ch 5 · ...", "cells": [CELL, ...]}
  * a Python file that defines SLUG, TITLE and CELLS (a list of CELL), e.g. notebooks/specs/05-first-simulation.py

A CELL is one of
  ["md", "markdown text"]                     markdown cell
  ["code", "python source"]                   code cell
  ["example", "ex03_ball_c.py"]               code cell holding examples/<slug>/ex03_ball_c.py, with a
                                              "# Example N.K - <file>" header line (docstring kept)
  ["example", "ex03_ball_c.py", "N.K"]        same, with the example number shown in the header
  ["writefile", "my_env.py", "examples/06-batched-data-layout/my_env_step06.py"]
                                              %%writefile cell embedding a helper module (path from course root)
  ["setup"]                                   the standard setup cell (course plan 0.4 rule S)
  ["setup", {"render": true}]                 setup cell for rendering notebooks (MUJOCO_GL=egl first)
  ["solution", "python source", "Exercise 5.1"]
                                              a code cell collapsed by default in Colab (cellView: form)

Every notebook automatically starts with: a title/Colab-badge markdown cell, a "check the GPU" cell
(`!nvidia-smi`) and the setup cell, unless the spec sets "auto_header": false (then add ["setup"] yourself).
Example files are read as text; nothing from examples/ is executed by this tool.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import runpy
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
REPO_PATH = "ozzyozbourne/ai_lab/blob/main/dpdk-research/mujoco-warp-course"

SETUP_CELL = '''# Standard setup cell (identical in every notebook). Run it first.
# 1. Rendering backend must be chosen BEFORE mujoco is imported (rendering notebooks only).
import os
{render_line}
# 2. Driver check: pip warp-lang 1.19.0 is built with CUDA 13 and needs an R580+ driver.
import shutil, subprocess
smi = ""
if shutil.which("nvidia-smi"):
    try:
        smi = subprocess.run(["nvidia-smi", "--query-gpu=driver_version,name", "--format=csv,noheader"],
                             capture_output=True, text=True).stdout.strip()
    except OSError:
        smi = ""
print(smi or "No NVIDIA GPU visible")
try:
    major = int(smi.split(".")[0]) if smi else 0
except ValueError:
    major = 0
# 3. Pick the Warp build: PyPI (CUDA 13) for R580+, else the +cu12 release wheel.
WARP = ("warp-lang==1.19.0" if major >= 580 else
        "https://github.com/NVIDIA/warp/releases/download/v1.19.0/"
        "warp_lang-1.19.0+cu12-py3-none-manylinux_2_28_x86_64.whl")
# 4. Install pinned versions ([viewer] pulls glfw + pyopengl + pillow via mujoco-core[rendering]).
!pip install -q "mujoco-warp[viewer]==4.0.1" "mujoco-core[rendering]==4.0.1" {{WARP}} mediapy matplotlib
# 5. Import, quiet the JIT log, verify that Warp itself sees the GPU (otherwise it silently uses CPU).
import importlib.metadata as md
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco
import mujoco_warp as mjw
wp.init()
ON_GPU = wp.get_cuda_device_count() > 0
if not ON_GPU:
    print("WARNING: Warp sees no GPU. Runtime > Change runtime type > GPU. Using small CPU budgets.")
print("device:", wp.get_device(), "| warp", wp.__version__, "| mujoco-core", md.version("mujoco-core"),
      "| mujoco-warp", md.version("mujoco-warp"))
GRAPH_COND = ON_GPU and wp.is_conditional_graph_supported()
print("conditional graphs supported:", GRAPH_COND)'''


def lines(src: str) -> list[str]:
    src = src.strip("\n")
    parts = src.split("\n")
    return [p + "\n" for p in parts[:-1]] + [parts[-1]] if parts else []


def md_cell(text: str) -> dict:
    return {"cell_type": "markdown", "metadata": {}, "source": lines(text)}


def code_cell(src: str, collapsed: bool = False) -> dict:
    meta: dict = {}
    if collapsed:
        meta = {"cellView": "form", "jupyter": {"source_hidden": True}}
    return {"cell_type": "code", "execution_count": None, "metadata": meta, "outputs": [], "source": lines(src)}


def setup_cell(opts: dict | None = None) -> dict:
    opts = opts or {}
    render = 'os.environ.setdefault("MUJOCO_GL", "egl")' if opts.get("render") else \
        '# (not a rendering notebook: MUJOCO_GL left unset)'
    return code_cell(SETUP_CELL.format(render_line=render))


def build(spec: dict) -> dict:
    slug = spec["slug"]
    title = spec.get("title", slug)
    cells: list[dict] = []
    if spec.get("auto_header", True):
        colab = f"https://colab.research.google.com/github/{REPO_PATH}/notebooks/{slug}.ipynb"
        page = f"../chapters/{slug}.html"
        cells.append(md_cell(
            f"# {title}\n\n"
            f"[![Open In Colab](https://colab.research.google.com/assets/colab-badge.svg)]({colab})\n\n"
            f"Companion notebook for the chapter page `chapters/{slug}.html` ([page]({page})). "
            "Pinned versions: mujoco-warp 4.0.1, warp-lang 1.19.0, mujoco-core 4.0.1.\n\n"
            "**Before you start:** Runtime > Change runtime type > select a GPU. Then run the cells top to bottom."))
        cells.append(code_cell("# Check the GPU Colab gave you (this fails harmlessly on a CPU runtime).\n!nvidia-smi"))
        cells.append(setup_cell(spec.get("setup", {})))
    for c in spec["cells"]:
        kind = c[0]
        if kind == "md":
            cells.append(md_cell(c[1]))
        elif kind == "code":
            cells.append(code_cell(c[1]))
        elif kind == "setup":
            cells.append(setup_cell(c[1] if len(c) > 1 else None))
        elif kind == "example":
            path = ROOT / "examples" / slug / c[1]
            if not path.exists():
                raise SystemExit(f"example file not found: {path}")
            num = f"Example {c[2]} - " if len(c) > 2 else ""
            cells.append(code_cell(f"# {num}{c[1]}\n" + path.read_text(encoding="utf-8")))
        elif kind == "writefile":
            path = ROOT / c[2]
            if not path.exists():
                raise SystemExit(f"helper file not found: {path}")
            cells.append(code_cell(f"%%writefile {c[1]}\n" + path.read_text(encoding="utf-8")))
        elif kind == "solution":
            label = c[2] if len(c) > 2 else "Solution"
            cells.append(code_cell(f"#@title {label}: solution (double-click to show the code)\n" + c[1],
                                   collapsed=True))
        else:
            raise SystemExit(f"unknown cell kind: {kind!r}")
    return {
        "cells": cells,
        "metadata": {
            "accelerator": "GPU",
            "colab": {"provenance": [], "gpuType": "T4", "toc_visible": True, "name": f"{slug}.ipynb"},
            "kernelspec": {"display_name": "Python 3", "language": "python", "name": "python3"},
            "language_info": {"name": "python"},
        },
        "nbformat": 4,
        "nbformat_minor": 5,
    }


def load_spec(path: pathlib.Path) -> dict:
    if path.suffix == ".json":
        return json.loads(path.read_text(encoding="utf-8"))
    ns = runpy.run_path(str(path))
    spec = {"slug": ns["SLUG"], "title": ns.get("TITLE", ns["SLUG"]), "cells": ns["CELLS"]}
    for k in ("SETUP", "AUTO_HEADER"):
        if k in ns:
            spec[k.lower()] = ns[k]
    return spec


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("spec", help="JSON or Python spec file")
    ap.add_argument("-o", "--out", help="output .ipynb (default notebooks/<slug>.ipynb)")
    args = ap.parse_args()
    spec = load_spec(pathlib.Path(args.spec))
    nb = build(spec)
    for i, c in enumerate(nb["cells"]):
        c["id"] = f"c{i:03d}"
    out = pathlib.Path(args.out) if args.out else ROOT / "notebooks" / f"{spec['slug']}.ipynb"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(nb, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"wrote {out} ({len(nb['cells'])} cells)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
