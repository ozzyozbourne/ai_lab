"""End to end on small random graphs: simulator output equals evaluate() bit for bit.

The generator (fixed list of seeds) mixes integer and floating-point paths and
includes op(a, a) nodes, chains of matvecs, computed tensors used as matrix
rows, broadcasts and casts.  exp is only applied to tanh outputs (bounded) and
rsqrt only to x*x + c with c > 0, so no value becomes infinite or NaN.
"""

import numpy as np
import pytest

from tsp.graph import Graph
from tsp.models import compile_and_run
from tsp.reference import evaluate
from tsp.validate import validate

LANES = 16
SEEDS = list(range(16))


def require_stack():
    """Skip unless the compiler, the simulator and the assembler are importable."""
    compiler = pytest.importorskip("tsp.compiler")
    if not hasattr(compiler, "compile_graph"):
        pytest.skip("tsp.compiler.compile_graph is not available yet")
    pytest.importorskip("tsp.hw")
    pytest.importorskip("tsp.asm")


def random_graph(seed):
    """A random graph with vectors of one length n, plus its inputs."""
    rng = np.random.default_rng(seed)
    g = Graph(f"rand{seed}", lanes=LANES)
    n = int(rng.integers(2, LANES + 1))
    inputs = {}
    pool = {"int8": [], "fp16": [], "int32": [], "fp32": []}
    counter = [0]

    def name(prefix):
        counter[0] += 1
        return f"{prefix}{counter[0]}"

    xi = g.input("xi", "int8", n)
    inputs["xi"] = rng.integers(-128, 128, n).astype(np.int8)
    pool["int8"].append(xi)
    xf = g.input("xf", "fp16", n)
    inputs["xf"] = rng.standard_normal(n).astype(np.float16)
    pool["fp16"].append(xf)

    def pick(dtype):
        return pool[dtype][int(rng.integers(len(pool[dtype])))]

    def const(dtype):
        if dtype == "int32":
            return g.const(name("ci"), rng.integers(-1000, 1001, n), "int32")
        return g.const(name("cf"), rng.standard_normal(n).astype(np.float32), "fp32")

    def matvec(dtype, rows):
        """matvec of a random vector; sometimes a computed vector is one of the rows."""
        x = pick(dtype)
        if dtype == "int8":
            w = rng.integers(-128, 128, (rows, n))
        else:
            w = rng.standard_normal((rows, n)) / np.sqrt(n)
        row_ids = [g.const(name("w"), w[r], dtype) for r in range(rows)]
        if rng.random() < 0.5:
            row_ids[int(rng.integers(rows))] = pick(dtype)
        m = g.matrix(name("M"), row_ids)
        return g.matvec(m, x, name=name("mv"))

    n_steps = int(rng.integers(6, 13))
    for _ in range(n_steps):
        kind = rng.choice(["matvec", "short_matvec", "binary", "same", "unary", "requant",
                           "cast16", "exp", "rsqrt", "i2f"])
        if kind in ("matvec", "short_matvec"):
            dtype = "int8" if rng.random() < 0.5 else "fp16"
            out = "int32" if dtype == "int8" else "fp32"
            if kind == "matvec":
                pool[out].append(matvec(dtype, n))
            else:
                rows = int(rng.integers(1, n + 1))
                short = matvec(dtype, rows)
                lane = int(rng.integers(rows))
                pool[out].append(g.broadcast(short, lane, n, name=name("bc")))
            continue
        dtype = "int32" if rng.random() < 0.5 else "fp32"
        if not pool[dtype]:
            dtype = "fp32" if dtype == "int32" else "int32"
        if not pool[dtype] and kind not in ("i2f",):
            continue
        if kind == "binary":
            op = rng.choice(["add", "sub", "mul"])
            a = pick(dtype)
            b = pick(dtype) if rng.random() < 0.5 else const(dtype)
            pool[dtype].append(getattr(g, op)(a, b, name=name(op)))
        elif kind == "same":
            op = rng.choice(["add", "sub", "mul"])
            a = pick(dtype)
            pool[dtype].append(getattr(g, op)(a, a, name=name(op)))
        elif kind == "unary":
            ops = ["neg", "relu"] + (["tanh"] if dtype == "fp32" else [])
            op = rng.choice(ops)
            pool[dtype].append(getattr(g, op)(pick(dtype), name=name(op)))
        elif kind == "requant" and pool["int32"]:
            pool["int8"].append(g.requant(pick("int32"), int(rng.integers(0, 13)), name=name("rq")))
        elif kind == "cast16" and pool["fp32"]:
            t = g.tanh(pick("fp32"), name=name("tanh"))
            pool["fp32"].append(t)
            pool["fp16"].append(g.cast(t, "fp16", name=name("c16")))
        elif kind == "exp" and pool["fp32"]:
            t = g.tanh(pick("fp32"), name=name("tanh"))
            pool["fp32"].append(g.exp(t, name=name("exp")))
        elif kind == "rsqrt" and pool["fp32"]:
            a = pick("fp32")
            sq = g.mul(a, a, name=name("sq"))
            pos = g.add(sq, g.const(name("cp"), rng.uniform(0.5, 2.0, n).astype(np.float32), "fp32"),
                        name=name("pos"))
            pool["fp32"].append(g.rsqrt(pos, name=name("rs")))
        elif kind == "i2f" and pool["int32"]:
            f = g.cast(pick("int32"), "fp32", name=name("i2f"))
            pool["fp32"].append(g.tanh(f, name=name("tanh")))
    # Make sure both paths are exercised.
    if not pool["int32"]:
        pool["int32"].append(matvec("int8", n))
    if not pool["fp32"]:
        pool["fp32"].append(matvec("fp16", n))

    # Every computed tensor that nothing uses becomes an output.
    used = set()
    for t in g.tensors:
        used.update(t.args)
    for m in g.matrices:
        used.update(m.rows)
    for t in g.ops():
        if t.id not in used:
            g.output(f"out_{t.name}", t.id)
    return g, inputs


def _bits(a):
    return a.dtype.str, a.shape, a.tobytes()


@pytest.mark.parametrize("seed", SEEDS)
def test_generator_is_well_formed(seed):
    g, inputs = random_graph(seed)
    assert g.outputs
    again, inputs2 = random_graph(seed)
    assert [t.name for t in g.tensors] == [t.name for t in again.tensors]
    out = evaluate(g, inputs)
    for name, v in out.items():
        if v.dtype.kind == "f":
            assert np.all(np.isfinite(v.astype(np.float64))), name


def test_generator_covers_the_features():
    seen = {"same": False, "matvec_chain": False, "computed_row": False, "broadcast": False,
            "int": False, "float": False}
    for seed in SEEDS:
        g, _ = random_graph(seed)
        for t in g.ops():
            if len(t.args) == 2 and t.args[0] == t.args[1]:
                seen["same"] = True
            if t.op == "broadcast":
                seen["broadcast"] = True
            if t.op == "matvec":
                x = g.t(t.args[0])
                if x.kind == "op":
                    seen["matvec_chain"] = True
                if any(g.t(r).kind == "op" for r in g.matrices[t.matrix].rows):
                    seen["computed_row"] = True
            seen["int" if t.dtype in ("int32", "int8") else "float"] = True
    assert all(seen.values()), seen


@pytest.mark.parametrize("seed", SEEDS)
def test_random_graph_end_to_end(seed):
    require_stack()
    g, inputs = random_graph(seed)
    program, trace, outputs = compile_and_run(g, inputs)
    assert validate(program, trace) == []
    expected = evaluate(g, inputs)
    for name in g.outputs:
        assert _bits(outputs[name]) == _bits(expected[name]), name
