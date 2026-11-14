"""Test-only mini recorder: turns queues into a consistent Trace, tags only.

This is NOT a simulator: it moves tags, never data, and does no fault checking.
It exists so the validator can be tested without tsp.hw. It follows plan.md
2.2 / 2.3 / 2.6 / 2.8 literally for the instruction kinds the validator tests
use (Read, Write, VOp, IW, MatVec, Shift).

`iw_delay` overrides d_func(IW) for row visibility only, to fake a simulator
that ignores the install latency (used by a negative test of check C).
"""
from __future__ import annotations

import hashlib
from collections import defaultdict

from tsp.config import EAST, ChipConfig
from tsp.isa import IW, Issue, MatVec, Nop, Read, VOp, Write, issue_cycles, opcode, text, timing_key
from tsp.trace import Event, Trace


def build_queues(config: ChipConfig, items):
    """items: (unit, issue_cycle, instr). Returns queues for every unit, with Nops in the gaps."""
    per_unit = defaultdict(lambda: defaultdict(list))
    for unit, t, ins in items:
        per_unit[unit][t].append(ins)
    queues = {}
    for unit in config.unit_names():
        q, t = [], 0
        for ti in sorted(per_unit.get(unit, {})):
            if ti > t:
                q.append(Nop(ti - t))
            q.append(Issue(tuple(per_unit[unit][ti])))
            t = ti + 1
        queues[unit] = q
    return queues


def issue_at(config: ChipConfig, ins, t_sample: int) -> int:
    """Issue cycle that makes `ins` sample at t_sample."""
    return t_sample - config.timing[timing_key(ins)].d_skew


def visible(config: ChipConfig, ins, t_sample: int) -> int:
    return t_sample + config.timing[timing_key(ins)].d_func


def record(queues, config: ChipConfig, image: dict, iw_delay: int | None = None) -> Trace:
    """image: (slice, bank, addr) -> tag of the word before cycle 0."""
    units = config.unit_names()
    order = {u: i for i, u in enumerate(units)}
    timed = []
    for unit in units:
        for t_i, ins in issue_cycles(queues.get(unit, [])):
            tm = config.timing[timing_key(ins)]
            timed.append((unit, t_i, t_i + tm.d_skew, t_i + tm.d_skew + tm.d_func, ins))
    events = []                                    # (cycle, unit order, seq, Event)

    def emit(e: Event):
        events.append((e.cycle, order[e.unit], len(events), e))

    writes = defaultdict(list)                     # (slice, bank, addr) -> [(ready cycle, tag)]
    rows = defaultdict(dict)                       # unit -> row -> [(ready cycle, tag)]
    drives = defaultdict(list)                     # cycle -> (dir, stream, pos, tag)
    iw_d = config.timing["IW"].d_func if iw_delay is None else iw_delay
    last_t = max([t for _, _, ts, tv, _ in timed for t in (ts, tv)], default=-1)
    occupancy, cells = [], {}
    for t in range(last_t + 1):
        new = {}
        for (d, s, p), tag in cells.items():
            q = p + 1 if d == EAST else p - 1
            if 0 <= q < config.n_positions:
                new[(d, s, q)] = tag
        for d, s, p, tag in drives.get(t, []):
            new[(d, s, p)] = tag
        cells = new
        occupancy.append(sorted((d, s, p, tag) for (d, s, p), tag in cells.items()))

        for unit, t_i, t_s, t_v, ins in timed:
            pos, op = config.pos(unit), opcode(ins)
            if t_i == t:
                emit(Event(t, "issue", unit, pos, op, text=text(ins), issue_cycle=t_i,
                           sample_cycle=t_s, visible_cycle=t_v))
            if t_s != t:
                continue

            def sample(sref):
                seen = []
                for st, exp in zip(sref.streams, sref.tags):
                    tag = cells.get((sref.dir, st, pos))
                    emit(Event(t, "sample", unit, pos, op, dir=sref.dir, stream=st, tag=tag,
                               expect=exp, issue_cycle=t_i))
                    seen.append(tag)
                return seen

            def drive(sref, tags):
                for st, tag in zip(sref.streams, tags):
                    drives[t_v].append((sref.dir, st, pos, tag))
                    emit(Event(t_v, "drive", unit, pos, op, dir=sref.dir, stream=st, tag=tag,
                               issue_cycle=t_i))

            if isinstance(ins, Read):
                key = (unit, ins.bank, ins.addr)
                ready = [w for w in writes[key] if w[0] <= t]
                tag = ready[-1][1] if ready else image.get(key)
                emit(Event(t, "mem_read", unit, pos, op, tag=tag, expect=ins.out.tags[0],
                           bank=ins.bank, addr=ins.addr, issue_cycle=t_i))
                drive(ins.out, [tag])
            elif isinstance(ins, Write):
                (tag,) = sample(ins.src)
                emit(Event(t, "mem_write", unit, pos, op, tag=tag, bank=ins.bank, addr=ins.addr,
                           issue_cycle=t_i))
                writes[(unit, ins.bank, ins.addr)].append((t + config.timing["WRITE"].d_func, tag))
            elif isinstance(ins, VOp):
                sample(ins.a)
                if ins.b is not None and ins.b != ins.a:
                    sample(ins.b)
                drive(ins.out, ins.out.tags)
            elif isinstance(ins, IW):
                for r, sref in ins.rows:
                    seen = sample(sref)
                    emit(Event(t, "iw_row", unit, pos, op, tag=seen[0], row=r, issue_cycle=t_i))
                    rows[unit].setdefault(r, []).append((t + iw_d, seen[0]))
            elif isinstance(ins, MatVec):
                sample(ins.a)
                for r in range(ins.k):
                    ready = [h for h in rows[unit].get(r, []) if h[0] <= t]
                    emit(Event(t, "matvec_row", unit, pos, op, tag=ready[-1][1] if ready else None,
                               expect=ins.expect_rows[r], row=r, issue_cycle=t_i))
                drive(ins.out, ins.out.tags)
            else:   # SXM: tags pass through as the instruction names them
                sample(ins.a)
                drive(ins.out, ins.out.tags)

    events.sort(key=lambda x: x[:3])
    evs = [e for *_, e in events]
    active = [e.cycle for e in evs if e.kind != "issue"]
    n = max(active) + 1 if active else 0
    occupancy = occupancy[:n]
    digests = [hashlib.sha256(repr(o).encode()).hexdigest() for o in occupancy]
    return Trace(config.name, n, evs, occupancy, digests)
