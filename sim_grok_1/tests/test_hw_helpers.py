"""Helpers for the hardware tests: build small hand-written programs.

Times are given in simulator cycles.  The barrier opens at
config.barrier_cycles, so the earliest data dispatch is at that cycle.
"""

import numpy as np

from tsp import isa
from tsp.hw import Simulator
from tsp.params import ChipConfig
from tsp.program import Program, TensorLoc

E = "E"
W = "W"


def ref(d, s):
    return isa.StreamRef(d, s)


def timed(pairs, config):
    """Queue body from [(cycle, instr or ('repeat', n, d))]: Nops fill the gaps.

    Cycles must be >= barrier_cycles and strictly increasing.  A Repeat entry
    occupies n*d cycles after its data instruction.
    """
    body = []
    nxt = config.barrier_cycles
    for cycle, instr in pairs:
        assert cycle >= nxt, (cycle, nxt)
        if cycle > nxt:
            body.append(isa.Nop(cycle - nxt))
        if isinstance(instr, tuple) and instr[0] == "repeat":
            body.append(isa.Repeat(instr[1], instr[2]))
            nxt = cycle + instr[1] * instr[2]
        else:
            body.append(instr)
            nxt = cycle + 1
    return body


def program(config, timeline, mem_image=None, inputs=None, outputs=None):
    """Program from {unit: [(cycle, instr), ...]}.  VXM_A0 always gets the Notify."""
    queues = {}
    for unit in config.units():
        if unit == "VXM_A0":
            queues[unit] = [isa.Notify()] + timed(timeline.get(unit, []), config)
        elif unit in timeline:
            queues[unit] = [isa.Sync()] + timed(timeline[unit], config)
    return Program(
        config=config,
        queues=queues,
        mem_image=dict(mem_image or {}),
        inputs=dict(inputs or {}),
        outputs=dict(outputs or {}),
    )


def padded(values, dtype, config):
    a = np.zeros(config.lanes, dtype=isa.np_dtype(dtype))
    v = np.asarray(values, dtype=isa.np_dtype(dtype))
    a[: len(v)] = v
    return a


def image(units_addrs, values, dtype, config):
    """mem_image entries for one tensor: plane j at units_addrs[j]."""
    planes = isa.to_planes(padded(values, dtype, config), dtype)
    return {ua: p.tobytes() for ua, p in zip(units_addrs, planes)}


def run(prog, pokes=None, record_cells=True):
    sim = Simulator(prog, record_cells=record_cells)
    for name, arr in (pokes or {}).items():
        sim.poke(name, arr)
    trace = sim.run()
    return sim, trace


def emissions_of(trace, did):
    return [e for e in trace.emissions if e["did"] == did]


def dispatch_of(trace, unit, cycle):
    for d in trace.dispatches:
        if d["unit"] == unit and d["cycle"] == cycle:
            return d
    raise AssertionError(f"no dispatch of {unit} at {cycle}")


def cells_of_vid(trace, vid):
    return [(c, d, s, x) for c, d, s, x, v in trace.cells if v == vid]


def toy():
    return ChipConfig.toy()


__all__ = ["E", "W", "ref", "timed", "program", "padded", "image", "run", "emissions_of",
           "dispatch_of", "cells_of_vid", "toy", "TensorLoc", "ChipConfig"]
