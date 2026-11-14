"""Cycle-level hardware model of one TSP (plan.md section 2).

Public interface (plan.md section 4):
    Chip(config).run(queues, mem_image, record_occupancy=True) -> (Trace, Memory)
    run_program(program, feeds, config, record_occupancy=True) -> RunResult(trace, outputs, memory)
    SimFault(cycle, unit, message, trace, code)
    Memory.read(slice, bank, addr) -> (uint8[lanes], tag)
"""
from .chip import Chip, RunResult, run_program
from .errors import SimFault
from .mem import Memory

__all__ = ["Chip", "Memory", "RunResult", "SimFault", "run_program"]
