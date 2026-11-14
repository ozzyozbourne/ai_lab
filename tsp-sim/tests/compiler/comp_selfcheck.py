"""Structural self-check of a compiled Program, from its queues and layouts alone.

Independent of the compiler's internals and of the simulator: it recomputes
issue / sample / visible cycles with isa.issue_cycles and config.timing, then
checks the machine rules of plan section 2 that a schedule must obey:

- issue widths and MEM entries (one Read + one Write at most), Nop range;
- MEM ports: per slice per sample cycle one Read, one Write, different banks;
- one driver per cell and cycle;
- stream replay: every sampled stream sees, at its sample cycle and position,
  the nearest drive upstream on its diagonal, carrying the expected tag
  (so no live flight was overwritten and every operand arrives exactly then);
- memory replay: every Read sees the expected tag (initial image or last Write
  visible per the WRITE usability rule); reads of never-written words fail;
- MXM: every MATVEC row was installed with the expected tag at least
  d_func(IW) before; direction rules (L-X6); F16 unit rule (L-X9);
- alignment and width of every stream group (L-G8).

Returns a list of failure strings (empty means OK).
"""
from __future__ import annotations

from tsp.config import EAST, WEST, ChipConfig
from tsp.isa import IW, Distribute, DType, Issue, MatVec, Nop, Permute, Read, Shift, SRef, VOp, Write, issue_cycles, timing_key


def _srefs(instr):
    """(operand srefs, result sref or None)."""
    if isinstance(instr, Read):
        return [], instr.out
    if isinstance(instr, Write):
        return [instr.src], None
    if isinstance(instr, VOp):
        return [instr.a] + ([instr.b] if instr.b is not None else []), instr.out
    if isinstance(instr, IW):
        return [s for _, s in instr.rows], None
    if isinstance(instr, MatVec):
        return [instr.a], instr.out
    if isinstance(instr, (Shift, Permute, Distribute)):
        return [instr.a], instr.out
    raise TypeError(instr)


def _width(dtype: DType) -> int:
    return dtype.nbytes


def check_program(program, config: ChipConfig) -> list[str]:
    fails: list[str] = []
    events = []          # (unit, issue, sample, visible, instr)
    for unit in config.unit_names():
        q = program.queues[unit]
        for e in q:
            if isinstance(e, Nop) and not 1 <= e.n <= config.nop_max:
                fails.append(f"{unit}: Nop({e.n}) out of range")
            if isinstance(e, Issue):
                if len(e.instrs) > config.issue_width(unit):
                    fails.append(f"{unit}: entry with {len(e.instrs)} instructions")
                if config.kind(unit) == "MEM":
                    if sum(isinstance(i, Read) for i in e.instrs) > 1 or sum(isinstance(i, Write) for i in e.instrs) > 1:
                        fails.append(f"{unit}: entry with two Reads or two Writes")
        for t, instr in issue_cycles(q):
            tm = config.timing[timing_key(instr)]
            ts = t + tm.d_skew
            events.append((unit, t, ts, ts + tm.d_func, instr))
    if list(program.queues) != config.unit_names():
        fails.append("queues are not in config.unit_names() order")

    # unit kinds, widths, alignment, directions
    for unit, t, ts, tv, instr in events:
        kind = config.kind(unit)
        want = {Read: "MEM", Write: "MEM", VOp: "VXM", IW: "MXM", MatVec: "MXM"}.get(type(instr), "SXM")
        if kind != want:
            fails.append(f"{unit}: {type(instr).__name__} on a {kind} unit")
        ops, res = _srefs(instr)
        for s in ops + ([res] if res is not None else []):
            if s.base % s.n or s.base + s.n > config.streams_per_dir or s.n not in (1, 2, 4):  # not a machine parameter: the three stream-group widths of plan 2.4
                fails.append(f"{unit}@{t}: misaligned stream group {s}")
        if kind == "MXM":
            outward = WEST if config.hemi(unit) == WEST else EAST
            for s in ops:
                if s.dir != outward:
                    fails.append(f"{unit}@{t}: operand on an inward stream")
            if res is not None and res.dir == outward:
                fails.append(f"{unit}@{t}: result on an outward stream")

    # MEM ports
    ports: dict[tuple[str, int], list] = {}
    for unit, t, ts, tv, instr in events:
        if isinstance(instr, (Read, Write)):
            p = ports.setdefault((unit, ts), [[], []])
            p[0 if isinstance(instr, Read) else 1].append(instr.bank)
    for (s, c), (rb, wb) in ports.items():
        if len(rb) > 1 or len(wb) > 1 or (rb and wb and rb[0] == wb[0]):
            fails.append(f"{s}@{c}: MEM port conflict reads={rb} writes={wb}")

    # drives
    drives: dict[tuple[str, int, int], list[tuple[int, str]]] = {}   # (dir, stream, diag) -> (pos, tag)
    cells: dict[tuple[str, int, int, int], int] = {}
    for unit, t, ts, tv, instr in events:
        ops, res = _srefs(instr)
        if res is None:
            continue
        x = config.pos(unit)
        for j, st in enumerate(res.streams):
            cell = (res.dir, st, x, tv)
            cells[cell] = cells.get(cell, 0) + 1
            if cells[cell] == 2:
                fails.append(f"two drivers on {cell}")
            diag = tv - x if res.dir == EAST else tv + x
            tag = res.tags[j]
            drives.setdefault((res.dir, st, diag), []).append((x, tag, unit, t))

    def seen(d, st, x, cycle):
        diag = cycle - x if d == EAST else cycle + x
        best = None
        for (xd, tag, u, ti) in drives.get((d, st, diag), []):
            if (d == EAST and xd <= x) or (d == WEST and xd >= x):
                if best is None or abs(x - xd) < abs(x - best[0]):
                    best = (xd, tag)
        return None if best is None else best[1]

    for unit, t, ts, tv, instr in events:
        ops, _ = _srefs(instr)
        x = config.pos(unit)
        for s in ops:
            for j, st in enumerate(s.streams):
                got = seen(s.dir, st, x, ts)
                if got != s.tags[j]:
                    fails.append(f"{unit}@{t} ({type(instr).__name__}): stream {s.dir}{st} at x={x} "
                                 f"cycle {ts} holds {got!r}, expected {s.tags[j]!r}")

    # memory replay
    words: dict[tuple[str, int, int], list[tuple[int, str]]] = {}   # -> [(usable-from sample cycle, tag)]
    for name, lay in program.inputs.items():
        for tile in lay.tiles:
            for j, p in enumerate(tile.planes):
                key = (p.slice, p.bank, p.addr)
                if key in words:
                    fails.append(f"two leaf planes share {key}")
                words[key] = [(-1, f"{tile.tag}#{j}")]
    d_w = config.timing["WRITE"].d_func
    for unit, t, ts, tv, instr in sorted((e for e in events if isinstance(e[4], Write)), key=lambda e: e[2]):
        words.setdefault((unit, instr.bank, instr.addr), []).append((ts + d_w, instr.src.tags[0]))
    for unit, t, ts, tv, instr in events:
        if isinstance(instr, Read):
            hist = [tag for (c, tag) in words.get((unit, instr.bank, instr.addr), []) if c <= ts]
            if not hist:
                fails.append(f"{unit}@{t}: Read of an unwritten word b{instr.bank}@{instr.addr}")
            elif hist[-1] != instr.out.tags[0]:
                fails.append(f"{unit}@{t}: Read finds {hist[-1]!r}, expected {instr.out.tags[0]!r}")
    for name, lay in program.outputs.items():
        for tile in lay.tiles:
            for j, p in enumerate(tile.planes):
                hist = words.get((p.slice, p.bank, p.addr), [])
                if not hist or hist[-1][1] != f"{tile.tag}#{j}":
                    fails.append(f"output {name} tile {tile.index} plane {j} is not written last")

    # MXM rows
    d_iw = config.timing["IW"].d_func
    rows: dict[tuple[str, int], list[tuple[int, str]]] = {}
    f16_planes: dict[str, bool] = {}
    for unit, t, ts, tv, instr in sorted(events, key=lambda e: e[2]):
        if isinstance(instr, IW):
            for r, s in instr.rows:
                if s.n != _width(instr.dtype):
                    fails.append(f"{unit}@{t}: IW row {r} width {s.n}")
                rows.setdefault((unit, r), []).append((ts + d_iw, s.tags[0]))
            if sum(s.n for _, s in instr.rows) > config.iw_max_streams:
                fails.append(f"{unit}@{t}: IW uses more than iw_max_streams")
        if isinstance(instr, (IW, MatVec)):
            if instr.dtype == DType.F16:
                if not unit.endswith(".0"):
                    fails.append(f"{unit}@{t}: F16 on plane .1")
                f16_planes[unit.split(".")[0]] = True
            elif f16_planes.get(unit.split(".")[0]):
                fails.append(f"{unit}@{t}: I8 work in a hemisphere that holds F16 rows")
    for unit, t, ts, tv, instr in events:
        if isinstance(instr, MatVec):
            if len(instr.expect_rows) != instr.k:
                fails.append(f"{unit}@{t}: len(expect_rows) != k")
            for r, want in enumerate(instr.expect_rows):
                hist = [tag for (c, tag) in rows.get((unit, r), []) if c <= ts]
                if not hist or hist[-1] != want:
                    fails.append(f"{unit}@{t}: row {r} holds {hist[-1] if hist else None!r}, expected {want!r}")
    return fails

