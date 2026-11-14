"""Tests for the HTML timeline (tsp/viz), against a hand-built but self-consistent trace.

The helper below plays the simulator's cycle rules (plan 2.3) for a small
program: two tiles, z = a + b and then relu(z), with every plane read from
MEM, plus one stray Read that is not in the schedule.  It produces the
Program (queues, schedule) and the Trace (dispatches, emissions, cells,
values) exactly in the formats of plan 3.3, 3.4 and 4.6.
"""

import json
import os
import re
from pathlib import Path

import pytest

from tsp import isa
from tsp.params import ChipConfig
from tsp.program import Program
from tsp.trace import Trace
from tsp.viz import render_timeline

SCRATCH = Path("/tmp/claude-0/-home-user-ai-lab/c8af10d4-242d-50e2-9b7d-29e982e88ffc/scratchpad/viz")
PLANES = 4  # not-a-parameter: test fixture, an int32 value
SR = isa.StreamRef


def _text(instr):
    try:
        from tsp.asm import format_instr
        return format_instr(instr)
    except ImportError:  # pragma: no cover - asm is another agent's module
        return f"{type(instr).__name__} " + ", ".join(f"{k}={v}" for k, v in vars(instr).items() if v not in ((), ""))


def synthetic():
    """Return (program, trace) for a tiny two-tile program on the toy chip."""
    cfg = ChipConfig.toy()
    lat = cfg.latency
    B = cfg.barrier_cycles
    vx = cfg.vxm_pos
    # Each planned op: (cycle, unit, instr, reads [(dir, s)], emits [(dir, s, tag)], tile)
    ops = []
    t_add = B + 8  # not-a-parameter: test fixture
    for j in range(PLANES):
        wa, eb = f"MEM_W{j}", f"MEM_E{j}"
        for unit, d, s, name in ((wa, "E", j, "a"), (eb, "W", j, "b")):
            t = t_add - lat["read"] - abs(vx - cfg.pos(unit))
            ops.append((t, unit, isa.Read(j, SR(d, s), f"{name}@0#{j}"), [], [(d, s, f"{name}@0#{j}")], 0))
    add = isa.Vxm("add", "int32", SR("E", 0), SR("W", 0), SR("E", 4), 16, tag="z@0", expect=("a@0", "b@0"))  # not-a-parameter: fixture
    reads = [("E", j) for j in range(PLANES)] + [("W", j) for j in range(PLANES)]
    ops.append((t_add, "VXM_A0", add, reads, [("E", 4 + j, f"z@0#{j}") for j in range(PLANES)], 0))  # not-a-parameter: fixture
    t_z = t_add + lat["add"]
    for j in range(PLANES):
        unit = f"MEM_E{4 + j}"  # not-a-parameter: fixture
        t = t_z + cfg.pos(unit) - vx
        ops.append((t, unit, isa.Write(j, SR("E", 4 + j), (f"z@0#{j}",)), [("E", 4 + j)], [], None))  # not-a-parameter: fixture
    # tile 1: read z back (westward), relu, write west
    t_relu = t_z + 19  # not-a-parameter: fixture, after the writes commit
    for j in range(PLANES):
        unit = f"MEM_E{4 + j}"  # not-a-parameter: fixture
        t = t_relu - lat["read"] - (cfg.pos(unit) - vx)
        ops.append((t, unit, isa.Read(j, SR("W", 8 + j), f"z@1#{j}"), [], [("W", 8 + j, f"z@1#{j}")], 1))  # not-a-parameter: fixture
    relu = isa.Vxm("relu", "int32", SR("W", 8), None, SR("W", 12), 16, tag="y@1", expect=("z@1",))  # not-a-parameter: fixture
    ops.append((t_relu, "VXM_A0", relu, [("W", 8 + j) for j in range(PLANES)],  # not-a-parameter: fixture
                [("W", 12 + j, f"y@1#{j}") for j in range(PLANES)], 1))  # not-a-parameter: fixture
    t_y = t_relu + lat["relu"]
    for j in range(PLANES):
        unit = f"MEM_W{4 + j}"  # not-a-parameter: fixture
        t = t_y + vx - cfg.pos(unit)
        ops.append((t, unit, isa.Write(j, SR("W", 12 + j), (f"y@1#{j}",)), [("W", 12 + j)], [], None))  # not-a-parameter: fixture
    # a stray value that the schedule does not know about (neutral colour)
    ops.append((t_add, "MEM_E7", isa.Read(9, SR("W", 20), "stray#0"), [], [("W", 20, "stray#0")], None))  # not-a-parameter: fixture

    order = {u: i for i, u in enumerate(cfg.units())}
    ops.sort(key=lambda o: (o[0], order[o[1]]))
    n_cycles = max(o[0] + (lat[isa.kind_of(o[2])] if o[4] else 0) for o in ops) + 1

    # --- play the cycle rules: shift, emit, dispatch -----------------------
    regs = {}          # (dir, s, x) -> vid
    pending = []       # (cycle, did, unit, dir, s, tag)
    dispatches, emissions, cells, values, mem_writes = [], [], [], {}, []
    next_vid = 0
    by_cycle = {}
    for o in ops:
        by_cycle.setdefault(o[0], []).append(o)
    P = cfg.n_positions
    for c in range(n_cycles):
        regs = {(d, s, x + (1 if d == "E" else -1)): v for (d, s, x), v in regs.items()
                if 0 <= x + (1 if d == "E" else -1) < P}
        due = sorted([p for p in pending if p[0] == c], key=lambda p: (p[1], p[4]))
        for (_, did, unit, d, s, tag) in due:
            x = cfg.pos(unit)
            emissions.append({"cycle": c, "did": did, "unit": unit, "dir": d, "s": s, "pos": x,
                              "vid": next_vid, "tag": tag, "overwrote": regs.get((d, s, x))})
            values[str(next_vid)] = {"tag": tag, "unit": unit, "did": did, "cycle": c}
            regs[(d, s, x)] = next_vid
            next_vid += 1
        for (_, unit, instr, rd, em, _tile) in by_cycle.get(c, []):
            x = cfg.pos(unit)
            did = len(dispatches)
            rr = []
            for (d, s) in rd:
                vid = regs.get((d, s, x))
                rr.append({"dir": d, "s": s, "pos": x, "vid": vid, "tag": values[str(vid)]["tag"]})
            dispatches.append({"did": did, "cycle": c, "unit": unit, "pos": x, "kind": isa.kind_of(instr),
                               "text": _text(instr), "reads": rr})
            for (d, s, tag) in em:
                pending.append((c + lat[isa.kind_of(instr)], did, unit, d, s, tag))
            if isinstance(instr, isa.Write):
                mem_writes.append({"cycle": c, "did": did, "unit": unit, "addr": instr.addr, "tag": rr[0]["tag"]})
        for (d, s, x), v in sorted(regs.items(), key=lambda kv: (kv[0][0], kv[0][1], kv[0][2])):
            cells.append([c, d, s, x, v])

    # --- schedule, from what the play-through observed ----------------------
    tile_of = {}
    for o in ops:
        for (_, _, tag) in o[4]:
            tile_of[tag] = o[5]
    schedule = []
    for e in emissions:
        if tile_of.get(e["tag"]) is None:
            continue
        readers = [{"unit": d["unit"], "x": d["pos"], "t": d["cycle"]}
                   for d in dispatches for r in d["reads"] if r["vid"] == e["vid"]]
        schedule.append({"tag": e["tag"], "tile": tile_of[e["tag"]], "unit": e["unit"], "dir": e["dir"], "s": e["s"],
                         "x_from": e["pos"], "t_emit": e["cycle"], "readers": readers})

    queues = {}
    for u in cfg.units():
        mine = [o for o in ops if o[1] == u]
        if not mine and u != "VXM_A0":
            continue
        q = [isa.Notify() if u == "VXM_A0" else isa.Sync()]
        prev = B - 1
        for o in mine:
            if o[0] - prev > 1:
                q.append(isa.Nop(o[0] - prev - 1))
            q.append(o[2])
            prev = o[0]
        queues[u] = q
    program = Program(config=cfg, queues=queues, schedule=schedule)
    trace = Trace(config=cfg.to_dict(), n_cycles=n_cycles, dispatches=dispatches, emissions=emissions,
                  cells=cells, mem_writes=mem_writes, values=values, outputs={})
    return program, trace


def _embedded(page):
    m = re.search(r'<script type="application/json" id="timeline-data">(.*?)</script>', page, re.S)
    assert m, "no embedded JSON block"
    return json.loads(m.group(1))


def _canon(obj):
    return json.loads(json.dumps(obj))


def test_synthetic_trace_is_consistent():
    program, trace = synthetic()
    for d in trace.dispatches:
        for r in d["reads"]:
            assert r["vid"] is not None
    assert all(e["overwrote"] is None for e in trace.emissions)
    keys = [(c[0], c[1], c[2], c[3]) for c in trace.cells]
    assert len(keys) == len(set(keys))


def test_synthetic_trace_matches_real_simulator(tmp_path):
    """If the hardware simulator is available, it must reproduce the hand-built trace."""
    try:
        from tsp.hw import Simulator
    except ImportError as e:  # pragma: no cover - depends on another agent's module
        pytest.skip(f"simulator not importable: {e}")
    program, trace = synthetic()
    for unit, q in program.queues.items():
        for instr in q:
            if isinstance(instr, isa.Read):
                program.mem_image[(unit, instr.addr)] = bytes(program.config.lanes)
    real = Simulator(program).run()
    assert real.n_cycles == trace.n_cycles
    for key in ("dispatches", "emissions", "cells", "values", "mem_writes"):
        assert getattr(real, key) == getattr(trace, key), key
    render_timeline(program, real, "real simulator", str(tmp_path / "r.html"))


def test_html_embeds_digest_and_trace(tmp_path):
    program, trace = synthetic()
    out = tmp_path / "t.html"
    render_timeline(program, trace, "Synthetic <a+b> then relu", str(out))
    page = out.read_text(encoding="utf-8")
    assert f'<code id="trace-digest">{trace.digest()}</code>' in page
    data = _embedded(page)
    assert data["trace"] == _canon(trace.to_obj())
    assert data["schedule"] == _canon(program.schedule)
    assert data["digest"] == trace.digest()
    assert "Synthetic &lt;a+b&gt; then relu" in page
    assert "http://" not in page and "https://" not in page
    assert "T6" in page and "T13" in page and "assumption" in page


def test_byte_identical(tmp_path):
    program, trace = synthetic()
    a, b = tmp_path / "a.html", tmp_path / "b.html"
    render_timeline(program, trace, "x", str(a))
    program2, trace2 = synthetic()
    render_timeline(program2, trace2, "x", str(b))
    assert a.read_bytes() == b.read_bytes()


def _sync_playwright():
    mod = pytest.importorskip("playwright.sync_api")
    return mod.sync_playwright


def _check_page(page, trace, band_end):
    n_disp = page.locator('[data-kind="dispatch"]').count()
    assert n_disp == len(trace.dispatches)
    lane_keys = {(c[0], c[1], c[2]) for c in trace.cells if c[0] >= band_end}
    assert page.locator('[data-kind="lane"]').count() == len(lane_keys)
    assert page.inner_text("#trace-digest").strip() == trace.digest()
    # click a few cycles, check the space-time view lists exactly that cycle's register contents
    tag_of = {int(k): v["tag"] for k, v in trace.values.items()}
    cycles = sorted({c[0] for c in trace.cells if c[0] >= band_end})
    picks = [cycles[0], cycles[len(cycles) // 2], cycles[-1]]  # not-a-parameter: test sample
    for cyc in picks:
        page.locator(f'[data-kind="ruler"][data-cycle="{cyc}"]').click()
        got = sorted(page.eval_on_selector_all(
            "#spacetime .st-val",
            "els => els.map(e => [e.dataset.dir, +e.dataset.s, +e.dataset.pos, e.dataset.tag])"))
        want = sorted([c[1], c[2], c[3], tag_of[c[4]]] for c in trace.cells if c[0] == cyc)
        assert got == want, cyc
    # arrow keys step the selection
    page.locator(f'[data-kind="ruler"][data-cycle="{picks[1]}"]').click()
    page.keyboard.press("ArrowRight")
    want = sorted(tag_of[c[4]] for c in trace.cells if c[0] == picks[1] + 1)
    got = sorted(page.eval_on_selector_all("#spacetime .st-val", "els => els.map(e => e.dataset.tag)"))
    assert got == want
    assert f"cycle {picks[1] + 1}" in page.inner_text("#st-title")


def _open(p, path, width=1280, scheme="light"):  # not-a-parameter: viewport
    browser = p.chromium.launch()
    page = browser.new_page(viewport={"width": width, "height": 900}, color_scheme=scheme)  # not-a-parameter: viewport
    errors = []
    page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
    page.on("pageerror", lambda e: errors.append(str(e)))
    page.goto(Path(path).resolve().as_uri())
    page.wait_for_selector('[data-kind="dispatch"]', state="attached")
    return browser, page, errors


def test_browser_render(tmp_path):
    sync_playwright = _sync_playwright()
    program, trace = synthetic()
    out = tmp_path / "t.html"
    render_timeline(program, trace, "Synthetic: z = a + b, y = relu(z)", str(out))
    band_end = _embedded(out.read_text(encoding="utf-8"))["band_end"]
    assert band_end == trace.config["barrier_cycles"]
    with sync_playwright() as p:
        browser, page, errors = _open(p, out)
        _check_page(page, trace, band_end)
        assert errors == []
        SCRATCH.mkdir(parents=True, exist_ok=True)
        page.locator('[data-kind="ruler"][data-cycle="40"]').click()  # not-a-parameter: fixture cycle
        page.screenshot(path=str(SCRATCH / "synthetic_light.png"), full_page=True)
        browser.close()
        browser, page, errors = _open(p, out, scheme="dark")
        page.locator('[data-kind="ruler"][data-cycle="40"]').click()  # not-a-parameter: fixture cycle
        page.screenshot(path=str(SCRATCH / "synthetic_dark.png"), full_page=True)
        assert errors == []
        browser.close()
        # phone width: no page-level horizontal scroll
        browser, page, errors = _open(p, out, width=375)  # not-a-parameter: phone viewport
        sw = page.evaluate("document.documentElement.scrollWidth")
        cw = page.evaluate("document.documentElement.clientWidth")
        assert sw <= cw
        page.screenshot(path=str(SCRATCH / "synthetic_phone.png"), full_page=True)
        assert errors == []
        browser.close()


def _real_run():
    try:
        from tsp.compiler import compile_graph
        from tsp.hw import Simulator
        from tsp.graph import Graph
    except Exception as e:  # pragma: no cover - depends on other agents' modules
        pytest.skip(f"compiler or simulator not importable: {e}")
    import numpy as np
    rng = np.random.default_rng(0)
    g = Graph("m1")
    x = g.input("x", "int8", 12)  # not-a-parameter: M1 shape (plan 6)
    W = g.const_matrix("W", rng.integers(-3, 4, size=(8, 12)).astype(np.int8), "int8")  # not-a-parameter: M1 shape
    b = g.const("b", rng.integers(-20, 21, size=8).astype(np.int32), "int32")  # not-a-parameter: M1 shape
    g.output("y", g.relu(g.add(g.matvec(W, x), b)))
    cfg = ChipConfig.toy()
    program = compile_graph(g, cfg)
    sim = Simulator(program)
    sim.poke("x", rng.integers(-5, 6, size=12).astype(np.int8))  # not-a-parameter: M1 shape
    return program, sim.run()


def test_real_m1_run(tmp_path):
    program, trace = _real_run()
    out = tmp_path / "m1.html"
    render_timeline(program, trace, "M1: y = relu(W.x + b)", str(out))
    page_text = out.read_text(encoding="utf-8")
    data = _embedded(page_text)
    assert data["trace"] == _canon(trace.to_obj())
    sync_playwright = _sync_playwright()
    with sync_playwright() as p:
        browser, page, errors = _open(p, out)
        _check_page(page, trace, data["band_end"])
        SCRATCH.mkdir(parents=True, exist_ok=True)
        page.screenshot(path=str(SCRATCH / "m1_real.png"), full_page=True)
        assert errors == []
        browser.close()
