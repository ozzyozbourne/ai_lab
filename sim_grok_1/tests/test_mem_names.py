"""A Read or Write of the wrong memory address is detected (verification finding V1)."""

import dataclasses

import pytest

from tsp import isa
from tsp.compiler import compile_graph
from tsp.errors import OperandTagError
from tsp.hw import Simulator
from tsp.models import m2
from tsp.params import ChipConfig
from tsp.program import Program


def _compiled():
    graph, inputs = m2.build()
    return compile_graph(graph, ChipConfig.toy()), inputs


def _run(program, inputs):
    sim = Simulator(program)
    for name, array in inputs.items():
        sim.poke(name, array)
    return sim.run()


def test_every_stored_plane_has_a_name():
    program, _ = _compiled()
    for key in program.mem_image:
        assert key in program.mem_names
    for loc in list(program.inputs.values()) + list(program.outputs.values()):
        for key in loc.planes:
            assert key in program.mem_names
    assert Program.from_json(program.to_json()).mem_names == program.mem_names


def test_swapped_read_addresses_are_detected():
    program, inputs = _compiled()
    swapped = 0
    for unit in program.config.units():
        queue = program.queues.get(unit, [])
        reads = [i for i, instr in enumerate(queue) if isinstance(instr, isa.Read)]
        if len(reads) < 2:
            continue
        a, b = reads[0], reads[1]
        mutant = Program.from_json(program.to_json())
        q = mutant.queues[unit]
        q[a], q[b] = (dataclasses.replace(q[a], addr=q[b].addr), dataclasses.replace(q[b], addr=q[a].addr))
        with pytest.raises(OperandTagError):
            _run(mutant, inputs)
        swapped += 1
    assert swapped > 0


def test_write_to_wrong_address_is_detected():
    program, inputs = _compiled()
    for unit in program.config.units():
        queue = program.queues.get(unit, [])
        writes = [i for i, instr in enumerate(queue) if isinstance(instr, isa.Write)]
        if not writes:
            continue
        mutant = Program.from_json(program.to_json())
        q = mutant.queues[unit]
        other = next(addr for (u, addr) in sorted(program.mem_names) if u == unit and addr != q[writes[0]].addr)
        q[writes[0]] = dataclasses.replace(q[writes[0]], addr=other)
        with pytest.raises(OperandTagError):
            _run(mutant, inputs)
        return
    pytest.fail("no Write found")
