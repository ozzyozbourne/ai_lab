"""Helpers for the hardware-model tests: build queues and memory images by hand.

`Prog` collects instructions per unit at given cycles and memory words, then
turns them into `queues` (Issue / Nop entries) for `Chip.run`. The `*_to` /
`*_at` helpers place an instruction so that it samples (or its result arrives)
at a chosen cycle, using the timing rule of plan.md 2.3. The hand-written
relu(Wx+b) test does NOT use them: its cycles are written out by hand.
"""
from __future__ import annotations

import numpy as np

from tsp.config import ChipConfig
from tsp.hw import Chip
from tsp.isa import Issue, Nop, Read, SRef, Write, from_bytes, plane_tags, timing_key, to_bytes
from tsp.program import MemInit

TOY = ChipConfig.toy()


def sref(d, base, tags):
    if isinstance(tags, str):
        tags = (tags,)
    return SRef(d, base, tuple(tags))


def queues_from(schedule: dict[str, dict[int, list]]) -> dict[str, list]:
    """{unit: {issue cycle: [instr, ...]}} -> {unit: [Nop | Issue]}."""
    out = {}
    for unit, by_cycle in schedule.items():
        q, t = [], 0
        for c in sorted(by_cycle):
            assert c >= t, (unit, c)
            if c > t:
                q.append(Nop(c - t))
            q.append(Issue(tuple(by_cycle[c])))
            t = c + 1
        out[unit] = q
    return out


class Prog:
    def __init__(self, cfg: ChipConfig = TOY):
        self.cfg = cfg
        self.sched: dict[str, dict[int, list]] = {}
        self.image: list[MemInit] = []

    # ---- raw placement --------------------------------------------------------
    def issue(self, unit: str, cycle: int, instr) -> None:
        assert cycle >= 0, (unit, cycle, instr)
        self.sched.setdefault(unit, {}).setdefault(cycle, []).append(instr)

    def sample_at(self, unit: str, t_s: int, instr) -> None:
        """Issue `instr` so that it samples at t_s."""
        self.issue(unit, t_s - self.cfg.timing[timing_key(instr)].d_skew, instr)

    def word(self, slice_, bank, addr, plane: np.ndarray, tag: str) -> None:
        self.image.append(MemInit(slice_, bank, addr, np.asarray(plane, dtype=np.uint8), tag))

    def value(self, slices, bank, addr, values, dtype, name) -> tuple[str, ...]:
        """Store a vector as byte planes, plane j in slices[j]. Returns the plane tags."""
        planes = to_bytes(np.asarray(values), dtype, self.cfg.lanes)
        tags = plane_tags(name, dtype)
        for j in range(dtype.nbytes):
            self.word(slices[j], bank, addr, planes[j], tags[j])
        return tags

    # ---- timed helpers ----------------------------------------------------------
    def read_to(self, slice_, bank, addr, d, stream, tag, arrive_cycle, arrive_pos) -> None:
        """A Read whose result is at `arrive_pos` during `arrive_cycle`."""
        dist = abs(arrive_pos - self.cfg.pos(slice_))
        t = self.cfg.timing["READ"]
        t_s = arrive_cycle - dist - t.d_func
        self.issue(slice_, t_s - t.d_skew, Read(bank, addr, sref(d, stream, tag)))

    def write_from(self, slice_, bank, addr, d, stream, tag, sample_cycle) -> None:
        self.sample_at(slice_, sample_cycle, Write(bank, addr, sref(d, stream, tag)))

    def read_value_to(self, slices, bank, addr, d, base, tags, arrive_cycle, arrive_pos) -> None:
        for j, tag in enumerate(tags):
            self.read_to(slices[j], bank, addr, d, base + j, tag, arrive_cycle, arrive_pos)

    def write_value_from(self, slices, bank, addr, d, base, tags, visible_cycle, from_pos) -> None:
        """Park a value driven at `from_pos` in `visible_cycle` (one plane per slice)."""
        for j, tag in enumerate(tags):
            dist = abs(self.cfg.pos(slices[j]) - from_pos)
            self.write_from(slices[j], bank, addr, d, base + j, tag, visible_cycle + dist)

    # ---- run --------------------------------------------------------------------
    def queues(self) -> dict[str, list]:
        return queues_from(self.sched)

    def run(self, record=True):
        return Chip(self.cfg).run(self.queues(), self.image, record_occupancy=record)


def load_value(memory, slices, bank, addr, dtype) -> np.ndarray:
    planes = np.stack([memory.read(slices[j], bank, addr)[0] for j in range(dtype.nbytes)])
    return from_bytes(planes, dtype)


def mem_slices(cfg: ChipConfig, side: str, idx) -> list[str]:
    return [f"MEM_{side}{i}" for i in idx]


def tv(cfg: ChipConfig, key: str) -> int:
    """d_func of a timing key."""
    return cfg.timing[key].d_func
