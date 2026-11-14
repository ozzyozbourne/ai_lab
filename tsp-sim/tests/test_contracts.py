"""Tests of the lead-owned contract files (plan.md section 3)."""
import numpy as np
import pytest

from tsp import numerics
from tsp.config import ChipConfig, OpTiming
from tsp.graph import Graph, GraphError
from tsp.isa import DType, Issue, Nop, Read, SRef, from_bytes, issue_cycles, plane_tags, to_bytes
from tsp.program import MATRIX_COLS, VECTOR, PlaneLoc, Program, TensorLayout, TileLayout
from tsp.trace import Event, Trace


@pytest.mark.parametrize("cfg", [ChipConfig.toy(), ChipConfig.paper()])
def test_geometry(cfg):
    names = cfg.slice_names()
    assert len(names) == cfg.n_positions
    assert [cfg.pos(s) for s in names] == list(range(cfg.n_positions))
    assert cfg.pos("VXM.3") == cfg.vxm_pos
    assert cfg.pos("MEM_W0") == cfg.vxm_pos - 1 and cfg.pos("MEM_E0") == cfg.vxm_pos + 1
    assert cfg.hemi("MXM_W.1") == "W" and cfg.hemi("SXM_E.shift") == "E" and cfg.hemi("VXM.0") is None
    assert len(cfg.unit_names()) == len(set(cfg.unit_names()))
    assert cfg.issue_width("MEM_W3") == 2 and cfg.issue_width("VXM.0") == 1


def test_fingerprint_tracks_timing():
    c = ChipConfig.toy()
    assert c.fingerprint() == ChipConfig.toy().fingerprint()
    assert c.fingerprint() != c.with_timing(READ=OpTiming(1, 3)).fingerprint()
    assert c.fingerprint() != ChipConfig.paper().fingerprint()


@pytest.mark.parametrize("dt,vals", [
    (DType.I8, [-128, -1, 0, 127]), (DType.I32, [-2**31, -5, 7, 2**31 - 1]),
    (DType.F16, [1.5, -2.25, 0.0]), (DType.F32, [3.14159, -1e-20, 1e20])])
def test_byte_planes_roundtrip(dt, vals):
    planes = to_bytes(np.array(vals), dt, 32)
    assert planes.shape == (dt.nbytes, 32) and planes.dtype == np.uint8
    back = from_bytes(planes, dt)
    assert np.array_equal(back[:len(vals)], np.array(vals).astype(dt.np))
    assert not back[len(vals):].any()
    assert plane_tags("v", dt) == tuple(f"v#{j}" for j in range(dt.nbytes))


def test_issue_cycles():
    r = Read(0, 1, SRef("E", 0, ("a#0",)))
    assert issue_cycles([Nop(3), Issue((r,)), Nop(2), Issue((r, r))]) == [(3, r), (6, r), (6, r)]


def test_numerics():
    assert numerics.vop("ADD", DType.I32, np.array([2**31 - 1]), np.array([1]))[0] == -2**31
    assert list(numerics.vop("REQUANT", DType.I32, np.array([1000, -70000, 37]), imm=2)) == [127, -128, 9]
    r = numerics.vop("RSQRT", DType.F32, np.array([4.0, 0.0, -1.0]))
    assert r[0] == 0.5 and np.isinf(r[1]) and np.isnan(r[2])
    assert numerics.vop("CAST", DType.F32, np.array([1.0 + 2**-12]), to=DType.F16)[0] == np.float16(1.0)
    x = np.array([1.5, 2.0], dtype=np.float16)
    rows = np.array([[1, 2, 3], [0.5, 0.25, -1]], dtype=np.float16)
    assert list(numerics.matvec(DType.F16, x, rows)) == [2.5, 3.5, 2.5]
    assert list(numerics.matvec(DType.I8, np.array([3, -2]), np.array([[1, 2], [3, 4]]))) == [-3, -2]
    # fsum: the lane sum does not depend on the order of the rows
    rng = np.random.default_rng(0)
    xv = rng.standard_normal(16).astype(np.float16)
    w = (rng.standard_normal((16, 8)) * 1000).astype(np.float16)
    perm = rng.permutation(16)
    assert np.array_equal(numerics.matvec(DType.F16, xv, w), numerics.matvec(DType.F16, xv[perm], w[perm]))
    assert list(numerics.shift_lanes(np.arange(5), 2)) == [0, 0, 0, 1, 2]


def test_graph_checks():
    g = Graph("t")
    x = g.vector("x", DType.I8, 4)
    W = g.matrix("W", DType.I8, 3, 4, data=np.ones((3, 4)))
    y = g.matvec(W, x)
    assert y.node.dtype == DType.I32 and y.node.n == 3
    with pytest.raises(GraphError):
        g.add(y, x)                      # dtype mismatch
    with pytest.raises(GraphError):
        g.vector("x", DType.I8, 4)       # duplicate name
    with pytest.raises(GraphError):
        g.shift(y, -1)
    with pytest.raises(GraphError):
        g.vector("big", DType.I8, 2, data=[300, 0])
    g.output("y", g.relu(y))
    assert g.input_names() == ["x"] and g.consumers(x.id) == [y.id]


def test_program_layout_roundtrip():
    cfg = ChipConfig.toy()
    vec = TensorLayout("v", DType.I32, (40,), VECTOR, tuple(
        TileLayout((i,), f"v.t{i}", tuple(PlaneLoc(f"MEM_W{j}", 0, i) for j in range(4))) for i in range(2)))
    mat = TensorLayout("M", DType.I8, (3, 2), MATRIX_COLS, tuple(
        TileLayout((0, 0, r), f"M.o0.c{r}", (PlaneLoc(f"MEM_E{r}", 0, 0),)) for r in range(2)))
    p = Program("t", cfg.name, cfg.fingerprint(), 32, {u: [] for u in cfg.unit_names()},
                constants={"M": np.arange(6).reshape(3, 2)}, inputs={"v": vec, "M": mat}, outputs={"v": vec})
    data = np.arange(40) - 20
    image = p.memory_image({"v": data}, cfg)
    assert len(image) == 2 * 4 + 2
    store = {(m.slice, m.bank, m.addr): (m.data, m.tag) for m in image}

    class Mem:
        def read(self, s, b, a):
            return store[(s, b, a)]
    assert np.array_equal(p.read_outputs(Mem(), cfg)["v"], data)
    col1 = store[("MEM_E1", 0, 0)]
    assert list(col1[0][:3]) == [1, 3, 5] and col1[1] == "M.o0.c1#0"
    with pytest.raises(ValueError):
        p.memory_image({}, cfg)


def test_trace_json_roundtrip():
    t = Trace("toy", 2, [Event(0, "issue", "VXM.0", 18, "ADD", text="x", issue_cycle=0, sample_cycle=0, visible_cycle=1)],
              [[("E", 0, 3, "a#0")], []], ["d0", "d1"])
    assert Trace.from_json(t.to_json()).to_json() == t.to_json()
    assert Trace.from_json(t.to_json()).events == t.events
