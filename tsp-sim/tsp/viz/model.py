"""What the timeline page draws, computed in Python.

`summarise` mirrors `buildModel` in app.js step by step, so tests can check the
content of the picture without a browser. Keep the two in sync.

Flight reconstruction (plan 2.2):
- A value driven at (dir, stream, pos p, cycle t) is at p+k (East) or p-k
  (West) at cycle t+k. All its cells share one *diagonal*: cycle - pos for
  East, cycle + pos for West.
- Drives on one (dir, stream, diagonal) are ordered in the direction of flow.
  Each flight ends where the next one on its diagonal starts (it is
  overwritten there, in that drive's visible cycle), or when it leaves the chip:
  East after pos n_positions-1, West after pos 0. `end_cycle` is the first
  cycle in which the flight is gone (exclusive end).
- A sample at (dir, stream, pos q, cycle t) reads the nearest drive upstream of
  or at q on its diagonal (East: greatest pos <= q; West: smallest pos >= q).
  The flight's `last_sample_cycle` is the latest such sample (None if none).
- Live part: [start_cycle, last_sample_cycle + 1); dead tail: up to end_cycle.
- Flights of one lane are stacked greedily into sub-rows: in order of
  (start_cycle, drive order), each goes to the first sub-row whose last bar
  ended at or before its start.
"""
from __future__ import annotations

from ..config import ChipConfig
from ..trace import Trace

TAGGED_KINDS = ("drive", "sample", "mem_read", "mem_write", "iw_row", "matvec_row")


def value_of(tag: str | None) -> str:
    """Tag without its '#j' plane suffix (same rule as isa.value_of_tag)."""
    if tag is None:
        return ""
    i = tag.rfind("#")
    return tag if i < 0 else tag[:i]


def lane_name(d: str, stream: int) -> str:
    return f"{d}{stream}"


def diagonal(d: str, cycle: int, pos: int) -> int:
    return cycle - pos if d == "E" else cycle + pos


def compute_flights(trace: Trace, n_positions: int) -> list[dict]:
    """One flight per drive event, in event order. See the module docstring."""
    flights: list[dict] = []
    groups: dict[tuple, list[int]] = {}
    for e in trace.events:
        if e.kind != "drive":
            continue
        f = {
            "dir": e.dir, "stream": e.stream, "lane": lane_name(e.dir, e.stream),
            "tag": e.tag, "value": value_of(e.tag),
            "unit": e.unit, "opcode": e.opcode,
            "start_cycle": e.cycle, "start_pos": e.pos,
            "last_sample_cycle": None, "last_sample_unit": None, "n_samples": 0,
            "end_cycle": None, "end_reason": None, "end_pos": None, "subrow": 0,
        }
        groups.setdefault((e.dir, e.stream, diagonal(e.dir, e.cycle, e.pos)), []).append(len(flights))
        flights.append(f)

    # Sort each diagonal in flow order (East: ascending pos, West: descending).
    ordered: dict[tuple, list[int]] = {}
    for key, idxs in groups.items():
        sign = 1 if key[0] == "E" else -1
        order = sorted(idxs, key=lambda i: (sign * flights[i]["start_pos"], i))
        ordered[key] = order
        for a, b in zip(order, order[1:] + [None]):
            fa = flights[a]
            if b is not None:
                fa["end_cycle"] = flights[b]["start_cycle"]
                fa["end_reason"] = "overwritten"
                fa["end_pos"] = flights[b]["start_pos"]
            elif fa["dir"] == "E":
                fa["end_cycle"] = fa["start_cycle"] + (n_positions - fa["start_pos"])
                fa["end_reason"] = "edge"
                fa["end_pos"] = n_positions
            else:
                fa["end_cycle"] = fa["start_cycle"] + fa["start_pos"] + 1
                fa["end_reason"] = "edge"
                fa["end_pos"] = -1

    for e in trace.events:
        if e.kind != "sample":
            continue
        i = find_flight(ordered, flights, e.dir, e.stream, e.cycle, e.pos)
        if i is None:
            continue
        f = flights[i]
        f["n_samples"] += 1
        if f["last_sample_cycle"] is None or e.cycle >= f["last_sample_cycle"]:
            f["last_sample_cycle"] = e.cycle
            f["last_sample_unit"] = e.unit

    assign_subrows(flights)
    return flights


def find_flight(ordered: dict, flights: list[dict], d: str, stream: int, cycle: int, pos: int) -> int | None:
    """Index of the flight a reader at (d, stream, pos, cycle) sees, or None."""
    order = ordered.get((d, stream, diagonal(d, cycle, pos)))
    if not order:
        return None
    found = None
    for i in order:  # flow order: the last one upstream of or at pos is the nearest
        p = flights[i]["start_pos"]
        if (p <= pos) if d == "E" else (p >= pos):
            found = i
        else:
            break
    return found


def assign_subrows(flights: list[dict]) -> dict[str, int]:
    """Set flights[i]['subrow']; return lane -> number of sub-rows."""
    by_lane: dict[str, list[int]] = {}
    for i, f in enumerate(flights):
        by_lane.setdefault(f["lane"], []).append(i)
    counts = {}
    for lane, idxs in by_lane.items():
        ends: list[int] = []
        for i in sorted(idxs, key=lambda i: (flights[i]["start_cycle"], i)):
            f = flights[i]
            for r, end in enumerate(ends):
                if end <= f["start_cycle"]:
                    break
            else:
                r = len(ends)
                ends.append(0)
            ends[r] = f["end_cycle"]
            f["subrow"] = r
        counts[lane] = len(ends)
    return counts


def all_lanes(config: ChipConfig) -> list[str]:
    return [lane_name(d, s) for d in ("E", "W") for s in range(config.streams_per_dir)]


def summarise(trace: Trace, config: ChipConfig) -> dict:
    """Content of the timeline page, computed as app.js computes it."""
    unit_order = config.unit_names()
    issue_counts: dict[str, int] = {}
    for e in trace.events:
        if e.kind == "issue":
            issue_counts[e.unit] = issue_counts.get(e.unit, 0) + 1
    known = [u for u in unit_order if u in issue_counts]
    unknown = sorted(u for u in issue_counts if u not in unit_order)
    issue_blocks_per_unit = {u: issue_counts[u] for u in known + unknown}

    flights = compute_flights(trace, config.n_positions)
    lane_order = all_lanes(config)
    per_lane: dict[str, int] = {}
    for f in flights:
        per_lane[f["lane"]] = per_lane.get(f["lane"], 0) + 1
    lanes_used = [l for l in lane_order if l in per_lane] + sorted(l for l in per_lane if l not in lane_order)
    subrows: dict[str, int] = {}
    for f in flights:
        subrows[f["lane"]] = max(subrows.get(f["lane"], 0), f["subrow"] + 1)

    values: list[str] = []
    seen = set()
    for e in trace.events:
        if e.kind in TAGGED_KINDS and e.tag is not None:
            v = value_of(e.tag)
            if v not in seen:
                seen.add(v)
                values.append(v)

    return {
        "n_cycles": trace.n_cycles,
        "issue_blocks_per_unit": issue_blocks_per_unit,
        "n_issue_blocks": sum(issue_counts.values()),
        "units_active": list(issue_blocks_per_unit),
        "flights": flights,
        "n_flights": len(flights),
        "flights_per_lane": {l: per_lane[l] for l in lanes_used},
        "subrows_per_lane": {l: subrows[l] for l in lanes_used},
        "lanes_used": lanes_used,
        "values": values,
    }
