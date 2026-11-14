"""Instruction queues -> issue cycles (plan.md 2.10, L-I1..L-I3).

All queues start at cycle 0. `Nop(n)` takes n cycles, `Issue(...)` one. A Nop
whose count is outside 1..nop_max is reported as a fault at the cycle where it
would start; the rest of that queue is never reached.
"""
from __future__ import annotations

from dataclasses import dataclass

from ..config import ChipConfig
from ..isa import Issue, Nop


@dataclass(frozen=True)
class BadNop:
    """Placeholder for a Nop entry that faults when reached."""
    n: int


def schedule(config: ChipConfig, queues: dict) -> dict[int, list[tuple[str, Issue | BadNop]]]:
    """cycle -> [(unit, entry)], units in canonical order within a cycle."""
    order = config.unit_names()
    known = {u: True for u in order}
    for u in queues:
        if u not in known:
            raise ValueError(f"unknown queue {u!r}")
    at: dict[int, list] = {}
    for unit in order:
        t = 0
        for entry in queues.get(unit, ()):
            if isinstance(entry, Nop):
                if not (isinstance(entry.n, int) and 1 <= entry.n <= config.nop_max):
                    at.setdefault(t, []).append((unit, BadNop(entry.n)))
                    break
                t += entry.n
            elif isinstance(entry, Issue):
                at.setdefault(t, []).append((unit, entry))
                t += 1
            else:
                raise ValueError(f"{unit}: queue entries are Nop or Issue, got {type(entry).__name__}")
    return at
