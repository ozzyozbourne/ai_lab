"""The validator on a hand-made program and trace, and on broken copies of it.

The program copies two one-byte planes from the west MEM hemisphere to the
east one on the toy chip (positions: MEM_W1 = 8, MEM_W0 = 9, VXM = 10,
MEM_E0 = 11; barrier T15 = 35, read latency T6 = 2):

    MEM_W1  Read  at cycle 35 -> "b@0#0" on E/1 at position 8, cycle 37
    MEM_W0  Read  at cycle 35 -> "a@0#0" on E/0 at position 9, cycle 37
    MEM_E0  Write at cycle 39 reads "a@0#0" (37 + |11 - 9|)
    MEM_E0  Write at cycle 40 reads "b@0#0" (37 + |11 - 8|)

The trace is written out by hand from the rules of plan.md section 2.3.
"""

import copy

import numpy as np
import pytest

from tsp import isa
from tsp.params import ChipConfig
from tsp.program import Program, TensorLoc
from tsp.trace import Trace
from tsp import validate as V

E0 = isa.StreamRef("E", 0)
E1 = isa.StreamRef("E", 1)
READ_A = isa.Read(0, E0, "a@0#0")
READ_B = isa.Read(0, E1, "b@0#0")
WRITE_A = isa.Write(0, E0, ("a@0#0",))
WRITE_B = isa.Write(1, E1, ("b@0#0",))


def _text(instr):
    try:
        from tsp import asm
    except ImportError:
        return type(instr).__name__
    return asm.format_instr(instr)


def make_program():
    config = ChipConfig.toy()
    lanes = config.lanes
    queues = {
        "MEM_W1": [isa.Sync(), READ_B],
        "MEM_W0": [isa.Sync(), READ_A],
        "VXM_A0": [isa.Notify()],
        "MEM_E0": [isa.Sync(), isa.Nop(4), WRITE_A, WRITE_B],
    }
    mem_image = {
        ("MEM_W0", 0): bytes(range(lanes)),
        ("MEM_W1", 0): bytes(range(lanes, 2 * lanes)),
    }
    schedule = [
        {"tag": "b@0#0", "tile": 0, "unit": "MEM_W1", "dir": "E", "s": 1, "x_from": 8, "t_emit": 37,
         "readers": [{"unit": "MEM_E0", "x": 11, "t": 40}]},
        {"tag": "a@0#0", "tile": 0, "unit": "MEM_W0", "dir": "E", "s": 0, "x_from": 9, "t_emit": 37,
         "readers": [{"unit": "MEM_E0", "x": 11, "t": 39}]},
    ]
    outputs = {"y": TensorLoc("y", "int8", lanes, (("MEM_E0", 0),))}
    return Program(config, queues, mem_image, {}, outputs, schedule)


def make_trace(program):
    config = program.config
    last = config.n_positions - 1
    dispatches = [
        {"did": 0, "cycle": 35, "unit": "MEM_W1", "pos": 8, "kind": "read", "text": _text(READ_B), "reads": []},
        {"did": 1, "cycle": 35, "unit": "MEM_W0", "pos": 9, "kind": "read", "text": _text(READ_A), "reads": []},
        {"did": 2, "cycle": 39, "unit": "MEM_E0", "pos": 11, "kind": "write", "text": _text(WRITE_A),
         "reads": [{"dir": "E", "s": 0, "pos": 11, "vid": 1, "tag": "a@0#0"}]},
        {"did": 3, "cycle": 40, "unit": "MEM_E0", "pos": 11, "kind": "write", "text": _text(WRITE_B),
         "reads": [{"dir": "E", "s": 1, "pos": 11, "vid": 0, "tag": "b@0#0"}]},
    ]
    emissions = [
        {"cycle": 37, "did": 0, "unit": "MEM_W1", "dir": "E", "s": 1, "pos": 8, "vid": 0, "tag": "b@0#0",
         "overwrote": None},
        {"cycle": 37, "did": 1, "unit": "MEM_W0", "dir": "E", "s": 0, "pos": 9, "vid": 1, "tag": "a@0#0",
         "overwrote": None},
    ]
    n_cycles = 41  # the last write commits at the end of cycle 40
    cells = []
    for cycle in range(37, n_cycles):
        for s, x0, vid in ((0, 9, 1), (1, 8, 0)):
            x = x0 + cycle - 37
            if x <= last:
                cells.append([cycle, "E", s, x, vid])
    values = {
        "0": {"tag": "b@0#0", "unit": "MEM_W1", "did": 0, "cycle": 37},
        "1": {"tag": "a@0#0", "unit": "MEM_W0", "did": 1, "cycle": 37},
    }
    mem_writes = [
        {"cycle": 39, "did": 2, "unit": "MEM_E0", "addr": 0, "tag": "a@0#0"},
        {"cycle": 40, "did": 3, "unit": "MEM_E0", "addr": 1, "tag": "b@0#0"},
    ]
    outputs = {"y": bytes(range(config.lanes)).hex()}
    return Trace(config.to_dict(), n_cycles, dispatches, emissions, cells, mem_writes, values, outputs)


@pytest.fixture
def pt():
    program = make_program()
    return program, make_trace(program)


def _has(errors, check, words=""):
    return any(e.startswith(check) and words in e for e in errors)


# --- the valid case ---------------------------------------------------------
def test_hand_made_trace_passes_checks_1_3_4(pt):
    program, trace = pt
    assert V.check_stream_exclusivity(program, trace) == []
    assert V.check_exact_arrival(program, trace) == []
    assert V.check_latency(program, trace) == []


def test_hand_made_trace_passes_full_validate(pt):
    pytest.importorskip("tsp.asm")
    program, trace = pt
    assert V.validate(program, trace) == []
    s = V.summary(program, trace)
    assert s["dispatches"] == 4 and s["emissions"] == 2
    assert s["reads_checked"] == 2 and s["schedule_entries_checked"] == 2


def test_simulator_agrees_with_hand_made_trace(pt):
    pytest.importorskip("tsp.asm")
    hw = pytest.importorskip("tsp.hw")
    program, mine = pt
    sim = hw.Simulator(program)
    trace = sim.run()
    assert V.validate(program, trace) == []
    assert trace.dispatches == mine.dispatches
    assert trace.emissions == mine.emissions
    assert sorted(trace.cells) == sorted(mine.cells)
    assert trace.mem_writes == mine.mem_writes
    assert trace.n_cycles == mine.n_cycles
    assert np.array_equal(sim.peek("y"), np.arange(program.config.lanes, dtype=np.int8))


# --- check 1 ----------------------------------------------------------------
def test_check1_two_values_in_one_register(pt):
    program, trace = pt
    trace.cells.append([38, "E", 0, 10, 0])
    assert _has(V.check_stream_exclusivity(program, trace), V.CHECK1, "holds two values")


def test_check1_read_after_overwrite(pt):
    program, trace = pt
    # A third value overwrites "a@0#0" at position 10 on cycle 38, before MEM_E0 reads it at 39.
    trace.emissions.append({"cycle": 38, "did": 0, "unit": "VXM_A0", "dir": "E", "s": 0, "pos": 10,
                            "vid": 2, "tag": "z@9#0", "overwrote": 1})
    errors = V.check_stream_exclusivity(program, trace)
    assert _has(errors, V.CHECK1, "after it was overwritten")


def test_check1_planned_value_displaced(pt):
    program, trace = pt
    for cell in trace.cells:
        if cell[:4] == [38, "E", 0, 10]:
            cell[4] = 0
    assert _has(V.check_stream_exclusivity(program, trace), V.CHECK1, "the schedule expects 'a@0#0'")


def test_check1_planned_value_missing(pt):
    program, trace = pt
    trace.cells = [c for c in trace.cells if c[:4] != [39, "E", 1, 10]]
    assert _has(V.check_stream_exclusivity(program, trace), V.CHECK1, "is empty")


def test_check1_needs_cells_unless_disabled(pt):
    program, trace = pt
    trace.cells = []
    assert _has(V.check_stream_exclusivity(program, trace), V.CHECK1, "no cells")
    assert V.check_stream_exclusivity(program, trace, check_cells=False) == []


# --- check 2 ----------------------------------------------------------------
def test_check2_two_dispatches_on_one_unit_and_cycle(pt):
    pytest.importorskip("tsp.asm")
    program, trace = pt
    extra = copy.deepcopy(trace.dispatches[3])
    extra["cycle"] = 39
    extra["did"] = 4
    trace.dispatches.insert(3, extra)
    assert _has(V.check_unit_exclusivity(program, trace), V.CHECK2, "dispatched twice")


def test_check2_dispatch_not_at_queue_time(pt):
    pytest.importorskip("tsp.asm")
    program, trace = pt
    program.queues["MEM_E0"] = [isa.Sync(), isa.Nop(5), WRITE_A, WRITE_B]
    errors = V.check_unit_exclusivity(program, trace)
    assert _has(errors, V.CHECK2, "MEM_E0: dispatch 0")


def test_check2_missing_and_unexpected_dispatch(pt):
    pytest.importorskip("tsp.asm")
    program, trace = pt
    program.queues["MEM_E0"] = program.queues["MEM_E0"] + [WRITE_A]
    assert _has(V.check_unit_exclusivity(program, trace), V.CHECK2, "missing from the trace")
    program.queues["MEM_E0"] = [isa.Sync(), isa.Nop(4), WRITE_A]
    assert _has(V.check_unit_exclusivity(program, trace), V.CHECK2, "unexpected dispatch")


def test_check2_unit_without_queue(pt):
    pytest.importorskip("tsp.asm")
    program, trace = pt
    del program.queues["MEM_W1"]
    assert _has(V.check_unit_exclusivity(program, trace), V.CHECK2, "has no queue")


# --- check 3 ----------------------------------------------------------------
def test_check3_empty_read(pt):
    program, trace = pt
    trace.dispatches[2]["reads"][0]["vid"] = None
    assert _has(V.check_exact_arrival(program, trace), V.CHECK3, "empty")


def test_check3_value_read_at_wrong_time(pt):
    program, trace = pt
    # Claim MEM_E0 read "a@0#0" at cycle 40: it passed position 11 on cycle 39.
    trace.dispatches[2]["cycle"] = 40
    errors = V.check_exact_arrival(program, trace)
    assert _has(errors, V.CHECK3, "can only be read at cycle 39")
    assert _has(errors, V.CHECK3, "not in the trace")


def test_check3_value_read_upstream(pt):
    program, trace = pt
    trace.dispatches[2]["reads"][0]["pos"] = 8
    assert _has(V.check_exact_arrival(program, trace), V.CHECK3, "never passes this position")


def test_check3_schedule_and_trace_disagree(pt):
    program, trace = pt
    program.schedule[0]["readers"].append({"unit": "SXM_E", "x": 19, "t": 48})
    assert _has(V.check_exact_arrival(program, trace), V.CHECK3, "not in the trace")
    program, trace = make_program(), make_trace(make_program())
    program.schedule[1]["readers"] = []
    assert _has(V.check_exact_arrival(program, trace), V.CHECK3, "does not plan")


# --- check 4 ----------------------------------------------------------------
def test_check4_wrong_latency(pt):
    program, trace = pt
    trace.emissions[0]["cycle"] = 38
    trace.values["0"]["cycle"] = 38
    assert _has(V.check_latency(program, trace), V.CHECK4, "latency of 'read' is 2")


def test_check4_unknown_dispatch(pt):
    program, trace = pt
    trace.emissions[0]["did"] = 99
    assert _has(V.check_latency(program, trace), V.CHECK4, "unknown dispatch")
