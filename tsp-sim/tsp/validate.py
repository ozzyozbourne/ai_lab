"""Independent schedule validator (plan.md section 7).

`validate(program, trace, config)` re-checks a run using only the program's
queues, the trace and the chip configuration (timing, geometry, issue widths).
It does not import the simulator, the compiler or the reference, and it has its
own stream replay, so a bug in the simulator's stream code shows up as a
disagreement here.

Checks:
  A exact arrival     every sample / mem_read / matvec_row saw a non-empty tag equal to the one expected
  B stream replay     replays flights from `drive` events alone: one drive per cell per cycle; each sample's
                      expected tag is the tag of the nearest upstream drive on its diagonal
  C units             queue entry rules, unit kinds, MEM ports, stream-group rules, MXM rules (rows
                      installed in time with the right tag and dtype, fp16 two-plane rule L-X9, L-X6)
  D program/trace     issue events equal the queues with recomputed cycles; every other event belongs to an
                      instruction and sits at the cycle the timing rule gives (plan 2.3); n_cycles
  E occupancy replay  per-cycle occupancy rebuilt from drives and the shift rule equals trace.occupancy
"""
from __future__ import annotations

from collections import Counter, defaultdict
from dataclasses import dataclass, field

from .config import EAST, WEST, ChipConfig
from .isa import (CASTS, IW, VOPS, VOPS_BINARY, DType, Distribute, Instr, Issue, MatVec, Nop,
                  Permute, Read, Shift, SRef, VOp, Write, issue_cycles, opcode, text, timing_key,
                  unit_kind)
from .program import Program
from .trace import Event, Trace

MAX_FAILURES = 10  # not a machine parameter: failure strings kept per check

CHECK_NAMES = ("A exact arrival", "B stream replay", "C units",
               "D program/trace agreement", "E occupancy replay")


# ---- report -----------------------------------------------------------------------
@dataclass
class Check:
    name: str
    passed: bool
    checked: int
    failures: list[str] = field(default_factory=list)


@dataclass
class Report:
    checks: list[Check]

    @property
    def ok(self) -> bool:
        return all(c.passed for c in self.checks)

    def check(self, letter: str) -> Check:
        """The check whose name starts with `letter` ('A' .. 'E')."""
        for c in self.checks:
            if c.name.startswith(letter):
                return c
        raise KeyError(letter)

    def failed(self) -> list[str]:
        """Letters of the failing checks, in order."""
        return [c.name[0] for c in self.checks if not c.passed]

    def summary(self) -> str:
        lines = []
        for c in self.checks:
            lines.append(f"{c.name}: {'PASS' if c.passed else 'FAIL'} ({c.checked} checked)")
            lines.extend(f"    {f}" for f in c.failures)
        lines.append("ALL CHECKS PASSED" if self.ok else f"FAILED: {', '.join(self.failed())}")
        return "\n".join(lines)


class _Collector:
    def __init__(self, name: str):
        self.name, self.checked, self.n_fail, self.kept = name, 0, 0, []

    def fail(self, msg: str) -> None:
        self.n_fail += 1
        if len(self.kept) < MAX_FAILURES:
            self.kept.append(msg)

    def done(self) -> Check:
        kept = list(self.kept)
        if self.n_fail > len(kept):
            kept[-1] += f"  [... {self.n_fail - len(kept)} more; {self.n_fail} failures in total]"
        return Check(self.name, self.n_fail == 0, self.checked, kept)


# ---- the program as a list of timed instructions -----------------------------------
@dataclass(frozen=True)
class _Ins:
    unit: str
    pos: int
    t_issue: int
    t_sample: int
    t_visible: int
    instr: Instr


def _timed(program: Program, config: ChipConfig) -> tuple[list[_Ins], list[str]]:
    """Every instruction with its recomputed cycles; unknown units are returned separately."""
    known = config.unit_names()
    out, unknown = [], []
    for unit, queue in program.queues.items():
        if unit not in known:
            unknown.append(unit)
            continue
        pos = config.pos(unit)
        for t_i, ins in issue_cycles(queue):
            tm = config.timing[timing_key(ins)]
            t_s = t_i + tm.d_skew
            out.append(_Ins(unit, pos, t_i, t_s, t_s + tm.d_func, ins))
    return out, unknown


def _sampled(ins: Instr) -> list[SRef]:
    """Stream groups an instruction samples (in operand order; duplicates kept)."""
    if isinstance(ins, Write):
        return [ins.src]
    if isinstance(ins, VOp):
        return [ins.a] + ([ins.b] if ins.b is not None else [])
    if isinstance(ins, IW):
        return [s for _, s in ins.rows]
    if isinstance(ins, (MatVec, Shift, Permute, Distribute)):
        return [ins.a]
    return []


def _driven(ins: Instr) -> SRef | None:
    if isinstance(ins, Read):
        return ins.out
    if isinstance(ins, (VOp, MatVec, Shift, Permute, Distribute)):
        return ins.out
    return None


def _diag(direction: str, cycle: int, pos: int) -> int:
    return cycle - pos if direction == EAST else cycle + pos


def _ev(e: Event) -> str:
    s = f"cycle {e.cycle} {e.kind} {e.unit} {e.opcode}"
    if e.dir is not None:
        s += f" {e.dir}{e.stream}@{e.pos}"
    if e.row is not None:
        s += f" row {e.row}"
    if e.bank is not None:
        s += f" b{e.bank}@{e.addr}"
    return s


# ---- A: exact arrival -------------------------------------------------------------
def _check_a(trace: Trace) -> Check:
    c = _Collector(CHECK_NAMES[0])
    for e in trace.events:
        if e.kind not in ("sample", "mem_read", "matvec_row"):
            continue
        c.checked += 1
        if not e.tag:
            c.fail(f"{_ev(e)}: saw nothing, expected {e.expect!r}")
        elif e.tag != e.expect:
            c.fail(f"{_ev(e)}: saw {e.tag!r}, expected {e.expect!r}")
    return c.done()


# ---- B: stream replay -------------------------------------------------------------
def _check_b(trace: Trace) -> Check:
    c = _Collector(CHECK_NAMES[1])
    groups: dict[tuple, list[Event]] = defaultdict(list)
    cells: dict[tuple, list[Event]] = defaultdict(list)
    for e in trace.events:
        if e.kind != "drive":
            continue
        c.checked += 1
        groups[(e.dir, e.stream, _diag(e.dir, e.cycle, e.pos))].append(e)
        cells[(e.dir, e.stream, e.pos, e.cycle)].append(e)
    for (d, s, p, t), evs in cells.items():
        if len(evs) > 1:
            who = ", ".join(f"{e.unit}<{e.tag}>" for e in evs)
            c.fail(f"cycle {t}: {len(evs)} drives on cell {d}{s}@{p}: {who}")
    for e in trace.events:
        if e.kind != "sample":
            continue
        c.checked += 1
        group = groups.get((e.dir, e.stream, _diag(e.dir, e.cycle, e.pos)), [])
        if e.dir == EAST:
            up = [g for g in group if g.pos <= e.pos]
            src = max(up, key=lambda g: g.pos) if up else None
        else:
            up = [g for g in group if g.pos >= e.pos]
            src = min(up, key=lambda g: g.pos) if up else None
        if src is None:
            c.fail(f"{_ev(e)}: replay finds no value (expected {e.expect!r})")
        elif src.tag != e.expect:
            c.fail(f"{_ev(e)}: replay finds {src.tag!r} driven by {src.unit} at cycle {src.cycle} "
                   f"pos {src.pos}, expected {e.expect!r}")
    return c.done()


# ---- C: units ---------------------------------------------------------------------
def _sref_rules(c: _Collector, where: str, s: SRef, width: int | None, config: ChipConfig) -> None:
    """Range, width and alignment of one stream group (L-G5, L-G8)."""
    n = s.n
    if width is not None and n != width:
        c.fail(f"{where}: stream group {s.dir}{s.base} has {n} streams, needs {width}")
    if n not in (1, 2, 4):
        c.fail(f"{where}: stream group width {n} is not 1, 2 or 4")
    elif s.base % n != 0:
        c.fail(f"{where}: stream group {s.dir}{s.base}+{n} is not aligned (L-G8)")
    if s.base < 0 or s.base + n > config.streams_per_dir:
        c.fail(f"{where}: streams {s.base}..{s.base + n - 1} out of range")


def _vop_legal(v: VOp) -> bool:
    if v.op not in VOPS:
        return False
    if (v.b is not None) != (v.op in VOPS_BINARY):
        return False
    if v.op in VOPS_BINARY or v.op == "RELU":
        return v.dtype in (DType.I32, DType.F32)
    if v.op == "REQUANT":
        return v.dtype == DType.I32
    if v.op == "CAST":
        return (v.dtype, v.to) in CASTS
    return v.dtype == DType.F32       # EXP, RSQRT, TANH


def _instr_rules(c: _Collector, x: _Ins, config: ChipConfig) -> None:
    ins, where = x.instr, f"cycle {x.t_issue} {x.unit} {text(x.instr)}"
    if unit_kind(ins) != config.kind(x.unit):
        c.fail(f"{where}: {opcode(ins)} issued on a {config.kind(x.unit)} unit")
        return
    if isinstance(ins, (Read, Write)):
        s = ins.out if isinstance(ins, Read) else ins.src
        _sref_rules(c, where, s, 1, config)
        if not 0 <= ins.bank < config.banks_per_slice or not 0 <= ins.addr < config.words_per_bank:
            c.fail(f"{where}: address b{ins.bank}@{ins.addr} out of range")
    elif isinstance(ins, VOp):
        if not _vop_legal(ins):
            c.fail(f"{where}: illegal VXM operation")
            return
        _sref_rules(c, where, ins.a, ins.dtype.nbytes, config)
        if ins.b is not None:
            _sref_rules(c, where, ins.b, ins.dtype.nbytes, config)
        _sref_rules(c, where, ins.out, ins.out_dtype.nbytes, config)
    elif isinstance(ins, (IW, MatVec)):
        hemi = config.hemi(x.unit)
        outward, inward = (WEST, EAST) if hemi == WEST else (EAST, WEST)   # L-X6
        if ins.dtype not in (DType.I8, DType.F16):
            c.fail(f"{where}: MXM dtype {ins.dtype.value}")
            return
        if ins.dtype == DType.F16 and not x.unit.endswith(".0"):
            c.fail(f"{where}: F16 instruction on plane {x.unit} (only plane .0, L-X9)")
        ins_streams = _sampled(ins)
        for s in ins_streams:
            _sref_rules(c, where, s, ins.dtype.nbytes, config)
            if s.dir != outward:
                c.fail(f"{where}: operand on {s.dir} streams, {x.unit} reads outward flow {outward} (L-X6)")
        if isinstance(ins, IW):
            if sum(s.n for s in ins_streams) > config.iw_max_streams:
                c.fail(f"{where}: {sum(s.n for s in ins_streams)} streams > {config.iw_max_streams} (L-X3)")
            rows = [r for r, _ in ins.rows]
            if any(not 0 <= r < config.lanes for r in rows) or len(set(rows)) != len(rows):
                c.fail(f"{where}: bad row indices {rows}")
        else:
            _sref_rules(c, where, ins.out, ins.out_dtype.nbytes, config)
            if ins.out.dir != inward:
                c.fail(f"{where}: result on {ins.out.dir} streams, {x.unit} writes inward flow {inward} (L-X6)")
            k_max = config.lanes if ins.dtype == DType.I8 else config.lanes // 2   # L-X2
            if not 1 <= ins.k <= k_max:
                c.fail(f"{where}: k={ins.k} outside 1..{k_max} (L-X2)")
            if len(ins.expect_rows) != ins.k:
                c.fail(f"{where}: {len(ins.expect_rows)} expected rows for k={ins.k}")
    else:   # SXM
        _sref_rules(c, where, ins.a, None, config)
        _sref_rules(c, where, ins.out, ins.a.n, config)
        sub = x.unit.split(".", 1)[1]
        want = {Shift: "shift", Permute: "permute", Distribute: "distribute"}[type(ins)]
        if sub != want:
            c.fail(f"{where}: {want} instruction on the {sub} unit")
        if isinstance(ins, Shift) and not abs(ins.n) < config.lanes:
            c.fail(f"{where}: shift {ins.n} out of range")
        if isinstance(ins, Permute) and sorted(ins.map) != list(range(config.lanes)):
            c.fail(f"{where}: permute map is not a bijection on {config.lanes} lanes")
        if isinstance(ins, Distribute):
            m = config.lanes_per_superlane
            if len(ins.map) != m or any(not -1 <= i < m for i in ins.map):
                c.fail(f"{where}: distribute map needs {m} entries in -1..{m - 1}")


def _check_c(program: Program, trace: Trace, config: ChipConfig) -> Check:
    c = _Collector(CHECK_NAMES[2])
    timed, unknown = _timed(program, config)
    for u in unknown:
        c.fail(f"queue for unknown unit {u!r}")

    # queue entries: Nop range, issue width, MEM entry composition
    for unit, queue in program.queues.items():
        if unit in unknown:
            continue
        t = 0
        for entry in queue:
            c.checked += 1
            if isinstance(entry, Nop):
                if not 1 <= entry.n <= config.nop_max:
                    c.fail(f"cycle {t} {unit}: Nop({entry.n}) outside 1..{config.nop_max} (L-T10)")
                t += entry.n
                continue
            if not isinstance(entry, Issue):
                c.fail(f"cycle {t} {unit}: queue entry {entry!r} is neither Nop nor Issue")
                t += 1
                continue
            width = config.issue_width(unit)
            if len(entry.instrs) > width:
                c.fail(f"cycle {t} {unit}: {len(entry.instrs)} instructions in one entry, width {width} (L-I2)")
            if config.kind(unit) == "MEM":
                n_r = sum(isinstance(i, Read) for i in entry.instrs)
                n_w = sum(isinstance(i, Write) for i in entry.instrs)
                if n_r > 1 or n_w > 1:
                    c.fail(f"cycle {t} {unit}: entry holds {n_r} Reads and {n_w} Writes (max one each, L-I2)")
            t += 1

    # per-instruction rules
    for x in timed:
        c.checked += 1
        _instr_rules(c, x, config)

    # MEM ports per slice per sample cycle (L-M4, L-M5)
    ports: dict[tuple[str, int], list[_Ins]] = defaultdict(list)
    for x in timed:
        if isinstance(x.instr, (Read, Write)):
            ports[(x.unit, x.t_sample)].append(x)
    for (unit, t_s), xs in ports.items():
        reads = [x for x in xs if isinstance(x.instr, Read)]
        writes = [x for x in xs if isinstance(x.instr, Write)]
        if len(reads) > 1:
            c.fail(f"{unit} sample cycle {t_s}: {len(reads)} Reads (L-M5)")
        if len(writes) > 1:
            c.fail(f"{unit} sample cycle {t_s}: {len(writes)} Writes (L-M5)")
        for r in reads:
            for w in writes:
                if r.instr.bank == w.instr.bank:
                    c.fail(f"{unit} sample cycle {t_s}: Read and Write on bank {r.instr.bank} (L-M4)")

    _mxm_rules(c, timed, trace, config)
    return c.done()


def _mxm_rules(c: _Collector, timed: list[_Ins], trace: Trace, config: ChipConfig) -> None:
    iw_delay = config.timing["IW"].d_func
    iws = [x for x in timed if isinstance(x.instr, IW)]
    # installs as seen by the trace: (unit, row) -> [(cycle, tag)]
    installed: dict[tuple[str, int], list[tuple[int, str | None]]] = defaultdict(list)
    for e in trace.events:
        if e.kind == "iw_row":
            installed[(e.unit, e.row)].append((e.cycle, e.tag))

    def iw_dtype(unit: str, t_s: int, row: int) -> DType | None:
        for x in iws:
            if x.unit == unit and x.t_sample == t_s and any(r == row for r, _ in x.instr.rows):
                return x.instr.dtype
        return None

    def plane0(unit: str) -> str:
        return unit.rsplit(".", 1)[0] + ".0"

    def cleared(unit: str, row_dtype: DType, after: int, until: int) -> bool:
        """L-X9 clears: F16 IW on .0 clears plane .1; I8 IW on .0 clears the F16 rows of .0."""
        p0 = plane0(unit)
        for x in iws:
            if x.unit != p0 or not after < x.t_sample <= until:
                continue
            if unit != p0 and x.instr.dtype == DType.F16:
                return True
            if unit == p0 and row_dtype == DType.F16 and x.instr.dtype == DType.I8:
                return True
        return False

    for x in timed:
        m = x.instr
        if not isinstance(m, MatVec):
            continue
        limit = x.t_sample - iw_delay
        for r in range(m.k):
            c.checked += 1
            where = f"cycle {x.t_issue} {x.unit} MATVEC row {r}"
            hist = [h for h in installed.get((x.unit, r), []) if h[0] <= limit]
            if not hist:
                c.fail(f"{where}: no iw_row installed by cycle {limit} (L-T7)")
                continue
            t_inst, tag = hist[0]
            for h in hist:           # latest; on a tie the later event
                if h[0] >= t_inst:
                    t_inst, tag = h
            dt = iw_dtype(x.unit, t_inst, r)
            if dt is not None and dt != m.dtype:
                c.fail(f"{where}: row installed as {dt.value}, MATVEC is {m.dtype.value}")
            if dt is not None and cleared(x.unit, dt, t_inst, limit):
                c.fail(f"{where}: row installed at {t_inst} was cleared by an IW on {plane0(x.unit)} (L-X9)")
                continue
            expect = m.expect_rows[r] if r < len(m.expect_rows) else None
            if tag != expect:
                c.fail(f"{where}: last installed at cycle {t_inst} with {tag!r}, expected {expect!r}")

    # L-X9: no instruction on plane .1 while plane .0 holds F16 rows
    for hemi_slice in ("MXM_W", "MXM_E"):
        p0 = f"{hemi_slice}.0"
        events = sorted((x.t_sample, x.instr.dtype) for x in iws if x.unit == p0)
        intervals, start = [], None
        for t_s, dt in events:
            if dt == DType.F16 and start is None:
                start = t_s
            elif dt == DType.I8 and start is not None:
                intervals.append((start, t_s))
                start = None
        if start is not None:
            intervals.append((start, None))
        for x in timed:
            if x.unit.startswith(hemi_slice + ".") and x.unit != p0:
                for lo, hi in intervals:
                    if x.t_sample >= lo and (hi is None or x.t_sample < hi):
                        c.fail(f"cycle {x.t_issue} {x.unit} {text(x.instr)}: plane .0 holds F16 rows "
                               f"since cycle {lo} (L-X9)")


# ---- D: program / trace agreement ---------------------------------------------------
def _expected_events(timed: list[_Ins]) -> tuple[Counter, set, list[str]]:
    """Expected event keys: a multiset for every kind but `sample`, a set for samples.

    Samples are compared as a set because an instruction naming one stream group in both
    operand slots (r * r) may be reported with one or two sample events per stream.
    """
    other, samples = Counter(), set()
    for x in timed:
        ins, op = x.instr, opcode(x.instr)
        base = (x.unit, x.pos, op, x.t_issue)
        other[("issue", x.t_issue) + base + (text(ins), x.t_sample, x.t_visible)] += 1
        for s in _sampled(ins):
            for st, tag in zip(s.streams, s.tags):
                samples.add(("sample", x.t_sample) + base + (s.dir, st, tag))
        out = _driven(ins)
        if out is not None:
            if isinstance(ins, Read):
                other[("drive", x.t_visible) + base + (out.dir, out.base, None)] += 1
            else:
                for st, tag in zip(out.streams, out.tags):
                    other[("drive", x.t_visible) + base + (out.dir, st, tag)] += 1
        if isinstance(ins, Read):
            other[("mem_read", x.t_sample) + base + (ins.bank, ins.addr, ins.out.tags[0])] += 1
        if isinstance(ins, Write):
            other[("mem_write", x.t_sample) + base + (ins.bank, ins.addr)] += 1
        if isinstance(ins, IW):
            for r, _ in ins.rows:
                other[("iw_row", x.t_sample) + base + (r,)] += 1
        if isinstance(ins, MatVec):
            for r in range(ins.k):
                exp = ins.expect_rows[r] if r < len(ins.expect_rows) else None
                other[("matvec_row", x.t_sample) + base + (r, exp)] += 1
    return other, samples


def _event_key(e: Event) -> tuple:
    base = (e.kind, e.cycle, e.unit, e.pos, e.opcode, e.issue_cycle)
    if e.kind == "issue":
        return base + (e.text, e.sample_cycle, e.visible_cycle)
    if e.kind == "sample":
        return base + (e.dir, e.stream, e.expect)
    if e.kind == "drive":
        return base + (e.dir, e.stream, None if e.opcode == "READ" else e.tag)
    if e.kind == "mem_read":
        return base + (e.bank, e.addr, e.expect)
    if e.kind == "mem_write":
        return base + (e.bank, e.addr)
    if e.kind == "iw_row":
        return base + (e.row,)
    if e.kind == "matvec_row":
        return base + (e.row, e.expect)
    return base


def _key_text(k: tuple) -> str:
    kind, cycle, unit, pos, op, t_i = k[:6]
    return f"{kind} at cycle {cycle} on {unit}@{pos} {op} (issued {t_i}) {list(k[6:])}"


def _check_d(program: Program, trace: Trace, config: ChipConfig) -> Check:
    c = _Collector(CHECK_NAMES[3])
    timed, _ = _timed(program, config)
    exp_other, exp_samples = _expected_events(timed)
    act_other, act_samples = Counter(), set()
    for e in trace.events:
        if e.kind == "sample":
            act_samples.add(_event_key(e))
        elif e.kind in ("issue", "drive", "mem_read", "mem_write", "iw_row", "matvec_row"):
            act_other[_event_key(e)] += 1
        else:
            c.fail(f"{_ev(e)}: unknown event kind")
    c.checked = sum(exp_other.values()) + len(exp_samples)

    for k in sorted(exp_other - act_other, key=repr):
        c.fail(f"missing {_key_text(k)} x{(exp_other - act_other)[k]}")
    for k in sorted(act_other - exp_other, key=repr):
        c.fail(f"unexpected {_key_text(k)} x{(act_other - exp_other)[k]}")
    for k in sorted(exp_samples - act_samples, key=repr):
        c.fail(f"missing {_key_text(k)}")
    for k in sorted(act_samples - exp_samples, key=repr):
        c.fail(f"unexpected {_key_text(k)}")

    # a Read drives the tag it read
    read_tags: dict[tuple, list] = defaultdict(list)
    for e in trace.events:
        if e.kind == "mem_read":
            read_tags[(e.unit, e.issue_cycle)].append(e.tag)
    for e in trace.events:
        if e.kind == "drive" and e.opcode == "READ":
            seen = read_tags.get((e.unit, e.issue_cycle), [])
            if e.tag not in seen:
                c.fail(f"{_ev(e)}: drives {e.tag!r} but its mem_read read {seen}")

    # n_cycles: one more than the last cycle in which anything was sampled, driven or written
    active = [e.cycle for e in trace.events if e.kind != "issue"] + [x.t_issue for x in timed]
    want = max(active) + 1 if active else 0
    if trace.n_cycles != want:
        c.fail(f"n_cycles is {trace.n_cycles}, the last activity is at cycle {want - 1}")
    return c.done()


# ---- E: occupancy replay ------------------------------------------------------------
def _check_e(trace: Trace, config: ChipConfig) -> Check:
    c = _Collector(CHECK_NAMES[4])
    n = trace.n_cycles
    if len(trace.occupancy) != n:
        c.fail(f"occupancy has {len(trace.occupancy)} cycles, n_cycles is {n}")
    if len(trace.digests) != n:
        c.fail(f"digests has {len(trace.digests)} cycles, n_cycles is {n}")
    drives: dict[int, list[Event]] = defaultdict(list)
    for e in trace.events:
        if e.kind == "drive":
            drives[e.cycle].append(e)
    last = config.n_positions - 1
    cells: dict[tuple[str, int, int], str] = {}
    for t in range(min(n, len(trace.occupancy))):
        c.checked += 1
        shifted = {}
        for (d, s, p), tag in cells.items():   # shift rule of plan 2.2
            q = p + 1 if d == EAST else p - 1
            if 0 <= q <= last:
                shifted[(d, s, q)] = tag
        for e in drives.get(t, []):
            shifted[(e.dir, e.stream, e.pos)] = e.tag
        cells = shifted
        mine = sorted((d, s, p, tag) for (d, s, p), tag in cells.items())
        theirs = sorted(tuple(x) for x in trace.occupancy[t])
        if mine != theirs:
            only_mine = [x for x in mine if x not in theirs][:3]
            only_theirs = [x for x in theirs if x not in mine][:3]
            c.fail(f"cycle {t}: replay has {only_mine} not in trace, trace has {only_theirs} not in replay")
    return c.done()


# ---- entry point --------------------------------------------------------------------
def _guarded(name: str, fn, *args) -> Check:
    try:
        return fn(*args)
    except Exception as exc:    # a malformed trace must give a failed check, not a crash
        return Check(name, False, 0, [f"internal error while checking: {type(exc).__name__}: {exc}"])


def validate(program: Program, trace: Trace, config: ChipConfig) -> Report:
    """Run checks A-E (plan section 7) on one run of `program`."""
    return Report([
        _guarded(CHECK_NAMES[0], _check_a, trace),
        _guarded(CHECK_NAMES[1], _check_b, trace),
        _guarded(CHECK_NAMES[2], _check_c, program, trace, config),
        _guarded(CHECK_NAMES[3], _check_d, program, trace, config),
        _guarded(CHECK_NAMES[4], _check_e, trace, config),
    ])
