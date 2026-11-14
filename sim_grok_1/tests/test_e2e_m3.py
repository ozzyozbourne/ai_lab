"""End to end, M3: one transformer decode step.

Bit for bit against tsp.reference.evaluate, and within the loose tolerance of
plan.md section 5.3 against the independent NumPy reference in m3.reference.
"""

import numpy as np
import pytest

from tsp.models import compile_and_run, m3
from tsp.reference import evaluate
from tsp.validate import validate

RTOL = 2e-3  # plan.md section 5.3
ATOL = 2e-3  # plan.md section 5.3


def require_stack():
    """Skip unless the compiler, the simulator and the assembler are importable."""
    compiler = pytest.importorskip("tsp.compiler")
    if not hasattr(compiler, "compile_graph"):
        pytest.skip("tsp.compiler.compile_graph is not available yet")
    pytest.importorskip("tsp.hw")
    pytest.importorskip("tsp.asm")


def same_bits(a, b):
    return a.dtype == b.dtype and a.shape == b.shape and a.tobytes() == b.tobytes()


@pytest.mark.parametrize("seed", [0, 1])
def test_m3_end_to_end(seed):
    require_stack()
    graph, inputs = m3.build(seed)
    program, trace, outputs = compile_and_run(graph, inputs)
    assert validate(program, trace) == []
    spec = evaluate(graph, inputs)
    independent = m3.reference(seed)
    assert sorted(outputs) == ["k16", "logits", "v"]
    for name in outputs:
        assert same_bits(outputs[name], spec[name]), name
        assert np.allclose(outputs[name], independent[name], rtol=RTOL, atol=ATOL), name
    assert outputs["logits"].dtype == np.float32
    assert outputs["k16"].dtype == np.float16
    assert outputs["v"].dtype == np.float32


@pytest.mark.parametrize("seed", [0, 1, 2, 3])
def test_m3_interpreter_and_reference_agree(seed):
    graph, inputs = m3.build(seed)
    spec = evaluate(graph, inputs)
    independent = m3.reference(seed)
    for name in spec:
        assert np.all(np.isfinite(spec[name].astype(np.float64))), name
        assert np.allclose(spec[name], independent[name], rtol=RTOL, atol=ATOL), name


def test_m3_graph_types():
    graph, _ = m3.build(0)
    for t in graph.ops():
        if t.op == "matvec":
            assert graph.matrices[t.matrix].dtype == "fp16"
            assert graph.t(t.args[0]).dtype == "fp16"
        elif t.op not in ("cast",):
            assert t.dtype == "fp32", t.name
    # The scores matrix holds three cached keys plus the key computed in this step.
    keys = [m for m in graph.matrices if m.name == "Kmat"][0]
    assert [graph.t(r).kind for r in keys.rows] == ["input"] * (m3.T - 1) + ["op"]


def test_m3_softmax_is_far_from_overflow():
    graph, inputs = m3.build(0)
    # Re-evaluate with the scaled scores as an extra output.
    scaled = [t for t in graph.tensors if t.name == "scaled"][0]
    graph.output("scaled_scores", scaled.id)
    s = evaluate(graph, inputs)["scaled_scores"]
    assert np.abs(s).max() < 20  # not-a-parameter: exp(20) is far below the float32 limit
