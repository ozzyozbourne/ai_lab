"""M1 with a 320x320 layer on the sourced 320-lane geometry (ChipConfig.isca2020()).

Cells are not recorded at this size (record_cells=False), so the validator
runs without its cell-based checks; everything else is checked.
"""

import numpy as np
import pytest

from tsp.models import compile_and_run, m1
from tsp.params import ChipConfig
from tsp.reference import evaluate
from tsp.validate import validate

SIZE = 320  # sourced lane count of the ISCA 2020 chip (ledger G1, G2)


def require_stack():
    """Skip unless the compiler, the simulator and the assembler are importable."""
    compiler = pytest.importorskip("tsp.compiler")
    if not hasattr(compiler, "compile_graph"):
        pytest.skip("tsp.compiler.compile_graph is not available yet")
    pytest.importorskip("tsp.hw")
    pytest.importorskip("tsp.asm")


def test_config_has_320_lanes():
    assert ChipConfig.isca2020().lanes == SIZE


def test_m1_320x320():
    require_stack()
    config = ChipConfig.isca2020()
    graph, inputs = m1.build(0, n_in=SIZE, n_out=SIZE, lanes=config.lanes)
    program, trace, outputs = compile_and_run(graph, inputs, config=config, record_cells=False)
    assert validate(program, trace, check_cells=False) == []
    expected = m1.reference(0, n_in=SIZE, n_out=SIZE, lanes=config.lanes)["y"]
    assert np.array_equal(outputs["y"], expected)
    assert np.array_equal(outputs["y"], evaluate(graph, inputs)["y"])
    assert (expected > 0).any() and (expected == 0).any()
