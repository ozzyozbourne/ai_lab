"""End to end, M1: y = relu(W.x + b) compiled, simulated, validated and checked exactly.

Also the negative tests of plan.md section 5.3: one extra Nop(1) in front of a
chosen data instruction of the compiled program must make the simulator
raise or the validator report an error.
"""

import numpy as np
import pytest

from tsp import isa
from tsp.errors import SimulationError
from tsp.models import compile_and_run, m1
from tsp.params import ChipConfig
from tsp.program import Program
from tsp.reference import evaluate
from tsp.validate import summary, validate


def require_stack():
    """Skip unless the compiler, the simulator and the assembler are importable."""
    compiler = pytest.importorskip("tsp.compiler")
    if not hasattr(compiler, "compile_graph"):
        pytest.skip("tsp.compiler.compile_graph is not available yet")
    pytest.importorskip("tsp.hw")
    pytest.importorskip("tsp.asm")


@pytest.mark.parametrize("seed", [0, 1, 2])
def test_m1_end_to_end(seed):
    require_stack()
    graph, inputs = m1.build(seed)
    program, trace, outputs = compile_and_run(graph, inputs)
    assert validate(program, trace) == []
    expected = m1.reference(seed)
    assert outputs["y"].dtype == np.int32
    assert np.array_equal(outputs["y"], expected["y"])
    assert np.array_equal(outputs["y"], evaluate(graph, inputs)["y"])
    counts = summary(program, trace)
    assert counts["reads_checked"] > 0 and counts["schedule_entries_checked"] > 0


def test_m1_reference_is_not_trivial():
    y = m1.reference(0)["y"]
    assert (y > 0).any() and (y == 0).any()


# --- negative tests -----------------------------------------------------------
def _with_extra_nop(program, unit, index):
    """Copy of `program` with one more idle cycle before queue element `index` of `unit`."""
    queues = {}
    for u, q in program.queues.items():
        q = list(q)
        if u == unit:
            if index > 0 and isinstance(q[index - 1], isa.Nop) and q[index - 1].n < program.config.nop_max:
                q[index - 1] = isa.Nop(q[index - 1].n + 1)
            else:
                q.insert(index, isa.Nop(1))
        queues[u] = q
    return Program(program.config, queues, dict(program.mem_image), dict(program.inputs),
                   dict(program.outputs), list(program.schedule))


def _targets(program, cls):
    """(unit, index) of the first and the last instruction of type `cls`, in canonical unit order."""
    found = []
    for unit in program.config.units():
        for i, instr in enumerate(program.queues.get(unit, [])):
            if isinstance(instr, cls):
                found.append((unit, i))
    assert found, f"compiled M1 has no {cls.__name__}"
    return [found[0]] if len(found) == 1 else [found[0], found[-1]]


@pytest.mark.parametrize("cls", [isa.Read, isa.Abc, isa.Vxm, isa.Write, isa.Iw],
                         ids=lambda c: c.__name__)
def test_extra_nop_is_detected(cls):
    require_stack()
    from tsp.compiler import compile_graph
    from tsp.hw import Simulator

    graph, inputs = m1.build(0)
    program = compile_graph(graph, ChipConfig.toy())
    for unit, index in _targets(program, cls):
        broken = _with_extra_nop(program, unit, index)
        sim = Simulator(broken)
        for name, array in inputs.items():
            sim.poke(name, array)
        try:
            trace = sim.run()
        except SimulationError:
            continue
        errors = validate(broken, trace)
        assert errors, f"an extra Nop before {unit}[{index}] went unnoticed"
