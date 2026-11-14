"""Trace validator: the four checks of plan.md section 5.1.

`validate(program, trace)` looks only at the compiled Program and the Trace
of a run (plus `asm.dispatch_times` and `config.latency`) and returns a list
of human-readable failure messages; an empty list means the run is valid.

1. Stream exclusivity: no two trace cells share (cycle, dir, stream, pos);
   a value that was overwritten is never read afterwards; every value
   planned in Program.schedule is found, with its tag, in every register on
   its way from the producer to its farthest reader.
2. Unit exclusivity: no unit dispatches twice on one cycle; the dispatches
   of every unit equal the static expansion of its queue.
3. Exact arrival: every read found a value, and that value had travelled
   exactly |read pos - emit pos| cycles in its own direction; the reads in
   the trace and the readers in Program.schedule are the same set.
4. Latency: every emission happened exactly config.latency[kind] cycles
   after the dispatch that produced it (ledger T6 to T13).

Each message starts with the name of the check, e.g. "[2 unit exclusivity]".

The cell-based parts of check 1 need the trace's `cells`; a run made with
`record_cells=False` must be validated with `check_cells=False`.
"""

from .isa import kind_of

CHECK1 = "[1 stream exclusivity]"
CHECK2 = "[2 unit exclusivity]"
CHECK3 = "[3 exact arrival]"
CHECK4 = "[4 latency]"


def _all_reads(trace):
    """Every operand read in the trace as (dispatch, read) pairs, in trace order."""
    out = []
    for d in trace.dispatches:
        for r in d.get("reads", []):
            out.append((d, r))
    return out


def _emission_by_vid(trace):
    """vid -> emission record."""
    return {e["vid"]: e for e in trace.emissions}


def _tag_of(trace, vid):
    v = trace.values.get(str(vid))
    return v["tag"] if v is not None else None


def _farthest(entry):
    """Position of the reader farthest from the producer, in the value's direction."""
    xs = [r["x"] for r in entry.get("readers", [])]
    if not xs:
        return entry["x_from"]
    return max(xs) if entry["dir"] == "E" else min(xs)


# --- check 1 ---------------------------------------------------------------
def check_stream_exclusivity(program, trace, check_cells=True):
    """Check 1: one value per register; no read after an overwrite; planned routes intact."""
    errors = []
    cells = {}
    if check_cells:
        if not trace.cells and trace.emissions:
            errors.append(f"{CHECK1} trace has no cells (run with record_cells=False?); "
                          "use check_cells=False to skip the cell checks")
        for cell in trace.cells:
            cycle, d, s, pos, vid = cell
            key = (cycle, d, s, pos)
            if key in cells:
                errors.append(f"{CHECK1} cycle {cycle} register {d}/{s} at position {pos} "
                              f"holds two values: vid {cells[key]} and vid {vid}")
            else:
                cells[key] = vid

    # A value that has been overwritten is gone: it may not be read at that cycle or later.
    overwritten = {}
    for e in trace.emissions:
        old = e.get("overwrote")
        if old is not None and old not in overwritten:
            overwritten[old] = e
    for d, r in _all_reads(trace):
        e = overwritten.get(r.get("vid"))
        if e is not None and d["cycle"] >= e["cycle"]:
            errors.append(f"{CHECK1} cycle {d['cycle']} {d['unit']} read vid {r['vid']} "
                          f"(tag {r.get('tag')!r}) on {r['dir']}/{r['s']} after it was overwritten "
                          f"at cycle {e['cycle']} by {e['unit']} (tag {e.get('tag')!r})")

    # Every planned route must be intact from the producer to the farthest reader.
    if check_cells and trace.cells:
        for entry in program.schedule:
            step = 1 if entry["dir"] == "E" else -1
            x_end = _farthest(entry)
            for x in range(entry["x_from"], x_end + step, step):
                cycle = entry["t_emit"] + abs(x - entry["x_from"])
                key = (cycle, entry["dir"], entry["s"], x)
                vid = cells.get(key)
                found = _tag_of(trace, vid) if vid is not None else None
                if found != entry["tag"]:
                    what = "is empty" if vid is None else f"holds vid {vid} (tag {found!r})"
                    errors.append(f"{CHECK1} cycle {cycle} register {entry['dir']}/{entry['s']} "
                                  f"at position {x} {what}; the schedule expects {entry['tag']!r} "
                                  f"from {entry['unit']}")
                    break
    return errors


# --- check 2 ---------------------------------------------------------------
def check_unit_exclusivity(program, trace):
    """Check 2: one dispatch per unit per cycle, and dispatches equal the queue expansion."""
    from . import asm

    errors = []
    seen = {}
    for d in trace.dispatches:
        key = (d["unit"], d["cycle"])
        if key in seen:
            errors.append(f"{CHECK2} cycle {d['cycle']} {d['unit']} dispatched twice: "
                          f"{seen[key]['text']!r} and {d['text']!r}")
        else:
            seen[key] = d

    by_unit = {}
    for d in trace.dispatches:
        by_unit.setdefault(d["unit"], []).append(d)
    config = program.config
    known = config.units()
    for unit in sorted(by_unit):
        if unit not in known or unit not in program.queues:
            errors.append(f"{CHECK2} unit {unit} dispatched {len(by_unit[unit])} instructions "
                          "but has no queue in the program")
    for unit in known:
        if unit not in program.queues:
            continue
        planned = asm.dispatch_times(program.queues[unit], config)
        actual = by_unit.get(unit, [])
        for i in range(max(len(planned), len(actual))):
            if i >= len(actual):
                cycle, instr = planned[i]
                errors.append(f"{CHECK2} {unit}: dispatch {i} ({asm.format_instr(instr)!r}) "
                              f"expected at cycle {cycle} is missing from the trace")
                break
            if i >= len(planned):
                d = actual[i]
                errors.append(f"{CHECK2} {unit}: unexpected dispatch {i} at cycle {d['cycle']} "
                              f"({d['text']!r}); the queue has only {len(planned)}")
                break
            cycle, instr = planned[i]
            d = actual[i]
            text = asm.format_instr(instr)
            if d["cycle"] != cycle or d["kind"] != kind_of(instr) or d["text"] != text:
                errors.append(f"{CHECK2} {unit}: dispatch {i} is {d['text']!r} at cycle {d['cycle']}; "
                              f"the queue gives {text!r} at cycle {cycle}")
                break
    return errors


# --- check 3 ---------------------------------------------------------------
def check_exact_arrival(program, trace):
    """Check 3: reads find values that arrived exactly on time; trace reads equal planned readers."""
    errors = []
    emissions = _emission_by_vid(trace)
    trace_reads = []
    for d, r in _all_reads(trace):
        where = f"cycle {d['cycle']} {d['unit']} read {r['dir']}/{r['s']} at position {r['pos']}"
        trace_reads.append((d["unit"], d["cycle"], r.get("tag"), r["pos"]))
        vid = r.get("vid")
        if vid is None:
            errors.append(f"{CHECK3} {where}: the register was empty (tag {r.get('tag')!r})")
            continue
        e = emissions.get(vid)
        if e is None:
            errors.append(f"{CHECK3} {where}: vid {vid} has no emission record")
            continue
        if e["dir"] != r["dir"] or e["s"] != r["s"]:
            errors.append(f"{CHECK3} {where}: vid {vid} was emitted on {e['dir']}/{e['s']}")
            continue
        side_ok = r["pos"] >= e["pos"] if e["dir"] == "E" else r["pos"] <= e["pos"]
        expected = e["cycle"] + abs(r["pos"] - e["pos"])
        if not side_ok or d["cycle"] != expected:
            errors.append(f"{CHECK3} {where}: vid {vid} (tag {e['tag']!r}) was emitted by {e['unit']} "
                          f"at position {e['pos']} on cycle {e['cycle']} flowing {e['dir']}, so it "
                          + (f"can only be read at cycle {expected}" if side_ok
                             else "never passes this position"))

    planned = []
    for entry in program.schedule:
        for rd in entry.get("readers", []):
            planned.append((rd["unit"], rd["t"], entry["tag"], rd["x"]))
    trace_set = set(trace_reads)
    planned_set = set(planned)
    for item in planned:
        if item not in trace_set:
            unit, t, tag, x = item
            errors.append(f"{CHECK3} cycle {t} {unit} at position {x}: the schedule plans a read of "
                          f"{tag!r} that is not in the trace")
    for item in trace_reads:
        if item not in planned_set:
            unit, t, tag, x = item
            errors.append(f"{CHECK3} cycle {t} {unit} at position {x}: the trace reads {tag!r}, "
                          "which the schedule does not plan")
    return errors


# --- check 4 ---------------------------------------------------------------
def check_latency(program, trace):
    """Check 4: emission cycle minus dispatch cycle equals the latency of the dispatch's kind."""
    errors = []
    latency = program.config.latency
    for e in trace.emissions:
        did = e["did"]
        if not 0 <= did < len(trace.dispatches):
            errors.append(f"{CHECK4} cycle {e['cycle']} emission of {e.get('tag')!r} names "
                          f"unknown dispatch {did}")
            continue
        d = trace.dispatches[did]
        want = latency.get(d["kind"])
        got = e["cycle"] - d["cycle"]
        if want is None or got != want:
            errors.append(f"{CHECK4} cycle {e['cycle']} {e['unit']} emitted {e.get('tag')!r} on "
                          f"{e['dir']}/{e['s']} {got} cycles after dispatching {d['text']!r} at cycle "
                          f"{d['cycle']}; latency of {d['kind']!r} is {want}")
    return errors


# --- entry points ------------------------------------------------------------
def validate(program, trace, check_cells=True):
    """Run the four checks of plan.md section 5.1.  Returns failure messages; [] means valid."""
    errors = []
    errors += check_stream_exclusivity(program, trace, check_cells=check_cells)
    errors += check_unit_exclusivity(program, trace)
    errors += check_exact_arrival(program, trace)
    errors += check_latency(program, trace)
    return errors


def summary(program, trace):
    """Counts for reporting what the validator looked at."""
    reads = _all_reads(trace)
    return {
        "dispatches": len(trace.dispatches),
        "emissions": len(trace.emissions),
        "cells": len(trace.cells),
        "reads_checked": len(reads),
        "schedule_entries_checked": len(program.schedule),
        "planned_reads": sum(len(e.get("readers", [])) for e in program.schedule),
        "queues": len(program.queues),
        "n_cycles": trace.n_cycles,
    }
