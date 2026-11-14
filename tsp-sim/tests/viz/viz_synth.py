"""Hand-built, self-consistent traces for the viz tests (no simulator needed).

`make_trace` takes drives and samples, propagates the drives with the stream
rule of plan 2.2 to fill `occupancy`, and fills the tag each sample sees.
"""
from __future__ import annotations

from tsp.config import ChipConfig
from tsp.trace import Event, Trace


def occupancy_of(drives, n_positions: int, n_cycles: int):
    """drives: (dir, stream, pos, cycle, tag). Returns per-cycle sorted cells."""
    cells = {}  # (dir, stream, pos) -> tag, for the current cycle
    by_cycle = {}
    for d in drives:
        by_cycle.setdefault(d[3], []).append(d)
    occ = []
    for t in range(n_cycles):
        nxt = {}
        for (d, s, x), tag in cells.items():
            y = x + 1 if d == "E" else x - 1
            if 0 <= y < n_positions:
                nxt[(d, s, y)] = tag
        for d, s, x, _, tag in by_cycle.get(t, []):
            nxt[(d, s, x)] = tag
        cells = nxt
        occ.append(sorted((d, s, x, tag) for (d, s, x), tag in cells.items()))
    return occ


def make_trace(config: ChipConfig, drives, samples=(), issues=(), n_cycles=None) -> Trace:
    """drives: (dir, stream, pos, cycle, tag, unit); samples: (dir, stream, pos, cycle, unit);
    issues: (cycle, unit, opcode, text, sample_cycle, visible_cycle)."""
    last = max([d[3] for d in drives] + [s[3] for s in samples] + [i[0] for i in issues] + [0])
    n = n_cycles if n_cycles is not None else last + 1
    occ = occupancy_of([d[:5] for d in drives], config.n_positions, n)
    events = []
    for c, unit, op, text, ts, tv in issues:
        events.append(Event(c, "issue", unit, config.pos(unit), op, text=text, issue_cycle=c,
                            sample_cycle=ts, visible_cycle=tv))
    for d, s, x, c, tag, unit in drives:
        events.append(Event(c, "drive", unit, x, "OP", dir=d, stream=s, tag=tag))
    for d, s, x, c, unit in samples:
        seen = next((tag for (dd, ss, xx, tag) in occ[c] if (dd, ss, xx) == (d, s, x)), None)
        events.append(Event(c, "sample", unit, x, "OP", dir=d, stream=s, tag=seen, expect=seen))
    order = {u: i for i, u in enumerate(config.unit_names())}
    events.sort(key=lambda e: (e.cycle, order.get(e.unit, len(order))))  # stable: emission order kept
    return Trace(config.name, n, events, occ, [f"d{t}" for t in range(n)])


def big_trace(config: ChipConfig, n_cycles: int = 1500, seed: int = 7) -> Trace:
    """A larger, deterministic, collision-free synthetic trace (READ -> VXM op -> WRITE chains)."""
    state = seed
    def rnd(k):
        nonlocal state
        state = (state * 6364136223846793005 + 1442695040888963407) % 2**64
        return (state >> 33) % k
    m = config.mem_slices_per_hemi
    vx = config.vxm_pos
    drives, samples, issues = [], [], []
    used = set()  # (dir, stream, diagonal) already taken
    t = 0
    v = 0
    while t < n_cycles - 3 * config.n_positions:
        i = rnd(m)
        src = f"MEM_W{i}"
        ps = config.pos(src)
        s = rnd(config.streams_per_dir)
        tag = f"x{v}.t0#0"
        key = ("E", s, t + 2 - ps)
        if key in used:
            t += 1
            continue
        used.add(key)
        # READ at t: drives E s at pos ps, cycle t+2; VXM samples it at vx
        issues.append((t, src, "READ", f"READ b0@{v % 64} -> E{s}<{tag}>", t, t + 2))
        drives.append(("E", s, ps, t + 2, tag, src))
        ts = t + 2 + (vx - ps)
        samples.append(("E", s, vx, ts, f"VXM.{v % 16}"))
        out = f"y{v}.t0#0"
        s2 = rnd(config.streams_per_dir)
        d2 = "E" if rnd(2) else "W"
        alu = f"VXM.{v % 16}"
        issues.append((ts, alu, "RELU", f"RELU.i32 E{s}<x{v}.t0> -> {d2}{s2}<y{v}.t0>", ts, ts + 1))
        key2 = (d2, s2, (ts + 1 - vx) if d2 == "E" else (ts + 1 + vx))
        if key2 not in used:
            used.add(key2)
            drives.append((d2, s2, vx, ts + 1, out, alu))
            dst = f"MEM_{d2}{rnd(m)}"
            pd = config.pos(dst)
            tw = ts + 1 + abs(pd - vx)
            samples.append((d2, s2, pd, tw, dst))
            issues.append((tw, dst, "WRITE", f"WRITE {d2}{s2}<{out}> -> b1@{v % 64}", tw, tw + 1))
        v += 1
        t += 1 + rnd(3)
    return make_trace(config, drives, samples, issues, n_cycles=n_cycles)
