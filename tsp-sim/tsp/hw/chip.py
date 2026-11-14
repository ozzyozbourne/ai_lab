"""The cycle loop and trace recording (plan.md 2.2, 2.3, 2.10, 3.5).

Per cycle t, in this order:
  1. drives with visible cycle t are written into the cells (this completes C_t);
  2. stored words and weight rows whose usability cycle is t are committed
     (Write and IW: usable by a Read / MATVEC whose sample cycle is >= t_s + d_func);
  3. occupancy and digest of C_t are recorded;
  4. queue entries with issue cycle t are checked and issued;
  5. instructions with sample cycle t read C_t at their position, compute, and
     schedule their drives (t_v = t_s + d_func >= t + 1) or commits;
  6. every cell shifts one position in its direction of flow.
Since d_func >= 1, nothing driven or committed in a cycle can be seen in that
same cycle, so the order of instructions within step 5 never matters.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from ..config import TIMING_KEYS, ChipConfig
from ..isa import (IW, Distribute, MatVec, Permute, Read, Shift, VOp, Write,
                   opcode, text, timing_key, unit_kind)
from ..trace import Event, Trace
from . import mem as mem_unit
from . import sxm, vxm
from .errors import (BAD_NOP, DOUBLE_DRIVE, EMPTY_SAMPLE, QUEUE_ENTRY, UNWRITTEN_READ,
                     SimFault, Violation)
from .icu import BadNop, schedule
from .mem import Memory
from .mxm import MXM, Row, matvec
from .streams import Streams

_INSTR_TYPES = (Read, Write, VOp, IW, MatVec, Shift, Permute, Distribute)


@dataclass
class _Op:
    """One issued instruction."""
    seq: int
    unit: str
    uidx: int          # index in config.unit_names(): canonical unit order
    pos: int
    instr: object
    opcode: str
    t_i: int
    t_s: int
    t_v: int


class Chip:
    def __init__(self, config: ChipConfig):
        for k in TIMING_KEYS:
            t = config.timing[k]
            if t.d_skew < 0 or t.d_func < 1:
                raise ValueError(f"timing {k}: need d_skew >= 0 and d_func >= 1, got {t}")
        self.config = config

    def run(self, queues: dict, mem_image: list, record_occupancy: bool = True) -> tuple[Trace, Memory]:
        """Run queues to completion. Raises SimFault on a broken rule (plan.md 2.5).

        With record_occupancy=False, `occupancy` and `digests` are left empty.
        """
        return _Run(self.config, queues, mem_image, record_occupancy).execute()


@dataclass
class RunResult:
    trace: Trace
    outputs: dict
    memory: Memory


def run_program(program, feeds: dict, config: ChipConfig, record_occupancy: bool = True) -> RunResult:
    if program.config_fingerprint != config.fingerprint():
        raise ValueError(f"program {program.name!r} was compiled for config {program.config_name!r} "
                         f"(fingerprint {program.config_fingerprint}), not {config.name!r} ({config.fingerprint()})")
    image = program.memory_image(feeds, config)
    trace, memory = Chip(config).run(program.queues, image, record_occupancy)
    return RunResult(trace, program.read_outputs(memory, config), memory)


class _Run:
    def __init__(self, config: ChipConfig, queues: dict, mem_image: list, record: bool):
        self.cfg = config
        self.record = record
        self.uidx = {u: i for i, u in enumerate(config.unit_names())}
        self.memory = Memory(config)
        self.memory.load(mem_image)
        self.streams = Streams(config)
        self.mxm = MXM(config)
        self.issues_at = schedule(config, queues)
        self.samples_at: dict[int, list[_Op]] = {}
        self.drives_at: dict[int, list[tuple]] = {}
        self.commits_at: dict[int, list[tuple]] = {}
        self.horizon = max(self.issues_at, default=-1)
        self.events: list[tuple[int, int, int, Event]] = []
        self.occupancy: list = []
        self.digests: list[str] = []
        self.cycles_done = 0
        self.seq = 0

    # ---- bookkeeping --------------------------------------------------------
    def _next_seq(self) -> int:
        self.seq += 1
        return self.seq

    def _emit(self, cycle: int, op: _Op, kind: str, **fields) -> None:
        ev = Event(cycle=cycle, kind=kind, unit=op.unit, pos=op.pos, opcode=op.opcode,
                   issue_cycle=op.t_i, **fields)
        self.events.append((cycle, op.uidx, self._next_seq(), ev))

    def _trace(self, n_cycles: int) -> Trace:
        events = [e for *_, e in sorted(self.events, key=lambda x: (x[0], x[1], x[2]))]
        return Trace(self.cfg.name, n_cycles, events,
                     self.occupancy[:n_cycles] if self.record else [],
                     self.digests[:n_cycles] if self.record else [])

    def _fault(self, cycle: int, unit: str, v: Violation):
        raise SimFault(cycle, unit, f"[fault {v.code}] {v.message}",
                       self._trace(self.cycles_done), v.code) from None

    def _at(self, table: dict, cycle: int, item) -> None:
        table.setdefault(cycle, []).append(item)
        self.horizon = max(self.horizon, cycle)

    # ---- main loop ----------------------------------------------------------
    def execute(self) -> tuple[Trace, Memory]:
        t = 0
        while t <= self.horizon:
            self._apply_drives(t)
            self._apply_commits(t)
            if self.record:
                self.occupancy.append(self.streams.occupancy())
                self.digests.append(self.streams.digest())
            self.cycles_done = t + 1
            self._issue(t)
            self._sample(t)
            self.streams.shift()
            t += 1
        for c in sorted(self.commits_at):          # words / rows that become usable after the last activity
            self._apply_commits(c)
        n_cycles = 1 + max((e[0] for e in self.events), default=-1)
        return self._trace(n_cycles), self.memory

    # ---- step 1: drives -----------------------------------------------------
    def _apply_drives(self, t: int) -> None:
        drives = self.drives_at.pop(t, [])
        owner: dict[tuple, _Op] = {}
        for op, d, s, _, _ in drives:
            key = (d, s, op.pos)
            if key in owner:
                self._fault(t, op.unit, Violation(
                    DOUBLE_DRIVE, f"cell ({d}, {s}, x={op.pos}) is also driven by {owner[key].unit} in cycle {t}"))
            owner[key] = op
        for op, d, s, data, tag in drives:
            self.streams.put(d, s, op.pos, data, tag)
            self._emit(t, op, "drive", dir=d, stream=s, tag=tag)

    # ---- step 2: commits ----------------------------------------------------
    def _apply_commits(self, t: int) -> None:
        for c in self.commits_at.pop(t, []):
            if c[0] == "mem":
                _, sl, bank, addr, data, tag = c
                self.memory.write(sl, bank, addr, data, tag)
            else:
                _, unit, dtype, rows = c
                self.mxm.install(unit, dtype, rows)

    # ---- step 4: issue ------------------------------------------------------
    def _check(self, unit: str, entry) -> None:
        if isinstance(entry, BadNop):
            raise Violation(BAD_NOP, f"Nop({entry.n}) outside 1..{self.cfg.nop_max}")
        instrs = entry.instrs
        width = self.cfg.issue_width(unit)
        if len(instrs) > width:
            raise Violation(QUEUE_ENTRY, f"entry holds {len(instrs)} instructions, the unit issues at most {width}")
        kind = self.cfg.kind(unit)
        for instr in instrs:
            if not isinstance(instr, _INSTR_TYPES):
                raise Violation(QUEUE_ENTRY, f"{type(instr).__name__} is not an instruction")
            if unit_kind(instr) != kind:
                raise Violation(QUEUE_ENTRY, f"{opcode(instr)} cannot be issued on a {kind} unit")
        if kind == "MEM":
            mem_unit.check_entry(instrs)
        for instr in instrs:
            if kind == "MEM":
                mem_unit.check_instr(self.cfg, instr)
            elif kind == "VXM":
                vxm.check_instr(self.cfg, instr)
            elif kind == "MXM":
                self.mxm.check_instr(unit, instr)
            else:
                sxm.check_instr(self.cfg, unit, instr)

    def _issue(self, t: int) -> None:
        for unit, entry in self.issues_at.pop(t, []):
            try:
                self._check(unit, entry)
            except Violation as v:
                self._fault(t, unit, v)
            for instr in entry.instrs:
                timing = self.cfg.timing[timing_key(instr)]
                t_s = t + timing.d_skew
                op = _Op(self._next_seq(), unit, self.uidx[unit], self.cfg.pos(unit), instr, opcode(instr),
                         t, t_s, t_s + timing.d_func)
                self._emit(t, op, "issue", text=text(instr), sample_cycle=op.t_s, visible_cycle=op.t_v)
                self._at(self.samples_at, t_s, op)

    # ---- step 5: sample and compute -----------------------------------------
    def _sample(self, t: int) -> None:
        ops = sorted(self.samples_at.pop(t, []), key=lambda o: (o.uidx, o.seq))
        by_slice: dict[str, list] = {}
        for op in ops:
            if isinstance(op.instr, (Read, Write)):
                by_slice.setdefault(op.unit, []).append(op.instr)
        for unit, instrs in by_slice.items():
            try:
                mem_unit.check_ports(instrs)
            except Violation as v:
                self._fault(t, unit, v)
        for op in ops:
            try:
                self._execute(t, op)
            except Violation as v:
                self._fault(t, op.unit, v)

    def _read_group(self, t: int, op: _Op, ref) -> tuple[np.ndarray, list[str]]:
        planes, tags = [], []
        for j, s in enumerate(ref.streams):
            cell = self.streams.get(ref.dir, s, op.pos)
            if cell is None:
                raise Violation(EMPTY_SAMPLE, f"samples empty cell ({ref.dir}, {s}, x={op.pos}); "
                                              f"expected {ref.tags[j]!r}")
            data, tag = cell
            self._emit(t, op, "sample", dir=ref.dir, stream=s, tag=tag, expect=ref.tags[j])
            planes.append(data)
            tags.append(tag)
        return np.stack(planes), tags

    def _drive(self, op: _Op, ref, planes: np.ndarray, tags) -> None:
        for j, s in enumerate(ref.streams):
            self._at(self.drives_at, op.t_v, (op, ref.dir, s, planes[j], tags[j]))

    def _execute(self, t: int, op: _Op) -> None:
        i = op.instr
        if isinstance(i, Read):
            if not self.memory.has(op.unit, i.bank, i.addr):
                raise Violation(UNWRITTEN_READ, f"reads b{i.bank}@{i.addr}, which was never written")
            data, tag = self.memory.read(op.unit, i.bank, i.addr)
            self._emit(t, op, "mem_read", tag=tag, expect=i.out.tags[0], bank=i.bank, addr=i.addr)
            self._drive(op, i.out, data[None, :], [tag])
        elif isinstance(i, Write):
            planes, tags = self._read_group(t, op, i.src)
            self._emit(t, op, "mem_write", tag=tags[0], bank=i.bank, addr=i.addr)
            self.commits_at.setdefault(op.t_v, []).append(("mem", op.unit, i.bank, i.addr, planes[0], tags[0]))
        elif isinstance(i, VOp):
            a, _ = self._read_group(t, op, i.a)
            b = self._read_group(t, op, i.b)[0] if i.b is not None else None
            self._drive(op, i.out, vxm.execute(self.cfg, i, a, b), i.out.tags)
        elif isinstance(i, IW):
            rows = []
            for r, ref in i.rows:
                planes, tags = self._read_group(t, op, ref)
                rows.append((r, Row(planes, i.dtype, tags[0])))
                self._emit(t, op, "iw_row", row=r, tag=tags[0])
            self.commits_at.setdefault(op.t_v, []).append(("iw", op.unit, i.dtype, rows))
        elif isinstance(i, MatVec):
            a, _ = self._read_group(t, op, i.a)
            rows = self.mxm.used_rows(op.unit, i)
            for r, row in enumerate(rows):
                self._emit(t, op, "matvec_row", row=r, tag=row.tag, expect=i.expect_rows[r])
            self._drive(op, i.out, matvec(self.cfg, i, a, rows), i.out.tags)
        else:
            a, _ = self._read_group(t, op, i.a)
            self._drive(op, i.out, sxm.execute(self.cfg, i, a), i.out.tags)
