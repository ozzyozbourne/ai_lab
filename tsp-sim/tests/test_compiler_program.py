"""Compiler stage 6 (plan 4.6) and whole-compiler properties: emitted queues,
static schedule checks, determinism across runs and hash seeds."""

import os
import subprocess
import sys

import numpy as np
import pytest

from tsp import isa
from tsp.compiler import compile_graph
from tsp.graph import Graph
from tsp.models import m1, m2, m3
from tsp.params import ChipConfig
from tsp.program import Program

CFG = ChipConfig.toy()
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = (isa.Read, isa.Write, isa.Vxm, isa.Iw, isa.Abc, isa.Distribute, isa.Permute, isa.Shift)


def dispatch_cycles(queue, config):
    """Static expansion of a queue without Repeat (plan 2.6 table)."""
    out = []
    c = config.barrier_cycles
    for el in queue[1:]:
        if isinstance(el, isa.Nop):
            c += el.n
        else:
            out.append((c, el))
            c += 1
    return out


def graphs():
    out = {}
    for key, mod in (("m1", m1), ("m2", m2), ("m3", m3)):
        out[key] = mod.build()[0]
    return out


def static_check(program):
    """No unit dispatches twice on a cycle; schedule readers obey t = t_emit + |x - x_from|;
    every schedule producer and reader is a real dispatch with that tag."""
    config = program.config
    at = {}
    for unit in config.units():
        if unit not in program.queues:
            continue
        cycles = dispatch_cycles(program.queues[unit], config)
        seen = [c for c, _ in cycles]
        assert len(seen) == len(set(seen)), unit
        for c, instr in cycles:
            at[(unit, c)] = instr
    tags = [e["tag"] for e in program.schedule]
    assert len(tags) == len(set(tags)), "tags are unique per emission"
    for e in program.schedule:
        assert e["x_from"] == config.pos(e["unit"])
        assert e["readers"], e["tag"]
        for r in e["readers"]:
            dist = r["x"] - e["x_from"] if e["dir"] == "E" else e["x_from"] - r["x"]
            assert dist >= 0
            assert r["t"] == e["t_emit"] + dist
            assert r["x"] == config.pos(r["unit"])
            assert (r["unit"], r["t"]) in at
    # the producer of every entry dispatched latency cycles before t_emit
    for e in program.schedule:
        found = [instr for (u, c), instr in at.items()
                 if u == e["unit"] and c + config.latency[isa.kind_of(instr)] == e["t_emit"]
                 and _tag_of(instr, e["tag"])]
        assert len(found) == 1, e


def _tag_of(instr, plane_tag):
    name, _, _ = plane_tag.partition("#")
    if isinstance(instr, isa.Read):
        return instr.tag == plane_tag
    return getattr(instr, "tag", None) == name


@pytest.mark.parametrize("key", ["m1", "m2", "m3"])
def test_static_checks(key):
    static_check(compile_graph(graphs()[key], CFG))


def test_static_check_isca2020_m1():
    cfg = ChipConfig.isca2020()
    g, _ = m1.build(n_in=320, n_out=320, lanes=cfg.lanes)
    static_check(compile_graph(g, cfg))


@pytest.mark.parametrize("key", ["m1", "m2", "m3"])
def test_queue_structure_and_fields(key):
    g = graphs()[key]
    p = compile_graph(g, CFG)
    units = list(p.queues)
    order = [u for u in CFG.units() if u in p.queues]
    assert units == order
    assert "VXM_A0" in p.queues
    for u, q in p.queues.items():
        assert q[0] == (isa.Notify() if u == "VXM_A0" else isa.Sync())
        assert not any(isinstance(i, (isa.Sync, isa.Notify, isa.Repeat)) for i in q[1:])
        for i in q[1:]:
            if isinstance(i, isa.Nop):
                assert 1 <= i.n <= CFG.nop_max
        assert u == "VXM_A0" or any(isinstance(i, DATA) for i in q)
        for i in q:
            if isinstance(i, isa.Read):
                assert i.tag and "#" in i.tag
            if isinstance(i, isa.Write):
                assert len(i.expect) == 1 and "#" in i.expect[0]
            if isinstance(i, (isa.Vxm, isa.Abc, isa.Distribute)):
                assert i.tag and "#" not in i.tag and i.expect
            if isinstance(i, isa.Iw):
                assert len(i.expect) == len(i.entries)
    # n set to the result length
    by_name = {t.name: t for t in g.tensors}
    for q in p.queues.values():
        for i in q:
            if isinstance(i, (isa.Vxm, isa.Distribute)):
                assert i.n == by_name[i.tag.split("@")[0]].n
            if isinstance(i, isa.Abc):
                assert i.n_rows == by_name[i.tag.split("@")[0]].n


def test_mem_image_inputs_outputs():
    g, _ = m2.build()
    p = compile_graph(g, CFG)
    consts = [t for t in g.tensors if t.kind == "const"]
    assert len(p.mem_image) == sum(isa.width(t.dtype) for t in consts)
    for data in p.mem_image.values():
        assert len(data) == CFG.lanes
    assert sorted(p.inputs) == sorted(t.name for t in g.tensors if t.kind == "input")
    assert sorted(p.outputs) == sorted(g.outputs)
    for name, loc in p.outputs.items():
        t = g.t(g.outputs[name])
        assert loc.name == name and loc.dtype == t.dtype and loc.n == t.n
        assert len(loc.planes) == isa.width(t.dtype)
    assert Program.from_json(p.to_json()).to_json() == p.to_json()


def test_constant_planes_are_zero_padded():
    g = Graph("c")
    a = g.input("a", "int32", 3)
    c = g.const("c", np.array([1, -2, 70000]), "int32")
    g.output("s", g.add(a, c, name="s"))
    p = compile_graph(g, CFG)
    from tsp.compiler.timetable import plan_graph
    planes = plan_graph(g, CFG).placement[c]
    got = isa.from_planes([np.frombuffer(p.mem_image[k], dtype=np.uint8) for k in planes], "int32")
    assert list(got) == [1, -2, 70000] + [0] * (CFG.lanes - 3)


def test_long_gaps_are_split_into_nops():
    cfg = ChipConfig(nop_max=3)
    g, _ = m1.build()
    p = compile_graph(g, cfg)
    for q in p.queues.values():
        for i in q:
            if isinstance(i, isa.Nop):
                assert 1 <= i.n <= 3
    ref = compile_graph(g, CFG)
    for u in ref.queues:
        a = [(c, i) for c, i in dispatch_cycles(ref.queues[u], CFG)]
        b = [(c, i) for c, i in dispatch_cycles(p.queues[u], cfg)]
        assert a == b


def test_byte_identical_twice():
    for g in graphs().values():
        assert compile_graph(g, CFG).to_json() == compile_graph(g, CFG).to_json()


SCRIPT = """
import hashlib, sys
sys.path.insert(0, {root!r})
from tsp.compiler import compile_graph
from tsp.models import m1, m2, m3
from tsp.params import ChipConfig
h = hashlib.sha256()
for mod in (m1, m2, m3):
    h.update(compile_graph(mod.build()[0], ChipConfig.toy()).to_json().encode())
print(h.hexdigest())
"""


def test_byte_identical_across_hash_seeds():
    digests = []
    for seed in ("0", "1", "2"):
        env = dict(os.environ, PYTHONHASHSEED=seed)
        out = subprocess.run([sys.executable, "-c", SCRIPT.format(root=ROOT)], env=env,
                             capture_output=True, text=True, check=True, cwd=ROOT)
        digests.append(out.stdout.strip())
    assert len(set(digests)) == 1 and len(digests[0]) == 64
