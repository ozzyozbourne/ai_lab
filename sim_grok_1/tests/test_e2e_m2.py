"""End to end, M2: the two-layer integer MLP, checked exactly."""

import numpy as np
import pytest

from tsp.models import compile_and_run, m2
from tsp.reference import evaluate
from tsp.validate import validate


def require_stack():
    """Skip unless the compiler, the simulator and the assembler are importable."""
    compiler = pytest.importorskip("tsp.compiler")
    if not hasattr(compiler, "compile_graph"):
        pytest.skip("tsp.compiler.compile_graph is not available yet")
    pytest.importorskip("tsp.hw")
    pytest.importorskip("tsp.asm")


@pytest.mark.parametrize("seed", [0, 1, 2])
def test_m2_end_to_end(seed):
    require_stack()
    graph, inputs = m2.build(seed)
    program, trace, outputs = compile_and_run(graph, inputs)
    assert validate(program, trace) == []
    assert outputs["y"].dtype == np.int32
    assert np.array_equal(outputs["y"], m2.reference(seed)["y"])
    assert np.array_equal(outputs["y"], evaluate(graph, inputs)["y"])


@pytest.mark.parametrize("seed", [0, 1, 2])
def test_m2_hidden_layer_is_not_trivial(seed):
    h = m2.hidden(seed)
    assert (h > 0).sum() >= 3
    assert (h == 127).sum() <= len(h) // 4


def test_m2_reference_matches_interpreter_without_hardware():
    graph, inputs = m2.build(0)
    assert np.array_equal(evaluate(graph, inputs)["y"], m2.reference(0)["y"])
