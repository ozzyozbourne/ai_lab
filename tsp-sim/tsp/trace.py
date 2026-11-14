"""Trace produced by the simulator. See plan.md section 3.5 for the meaning of each event."""
from __future__ import annotations

import hashlib
import json
from dataclasses import asdict, dataclass, field

EVENT_KINDS = ("issue", "sample", "drive", "mem_read", "mem_write", "iw_row", "matvec_row")


@dataclass(frozen=True)
class Event:
    cycle: int
    kind: str                    # one of EVENT_KINDS
    unit: str
    pos: int
    opcode: str
    dir: str | None = None       # sample / drive
    stream: int | None = None    # sample / drive
    tag: str | None = None       # tag seen (sample, mem_read, matvec_row) or produced (drive, mem_write, iw_row)
    expect: str | None = None    # tag the instruction expected (sample, mem_read, matvec_row)
    bank: int | None = None      # mem_read / mem_write
    addr: int | None = None      # mem_read / mem_write
    row: int | None = None       # iw_row / matvec_row
    text: str | None = None      # issue: isa.text(instr)
    issue_cycle: int | None = None    # every kind: cycle at which the instruction behind this event was issued
    sample_cycle: int | None = None   # issue: t_s of the instruction
    visible_cycle: int | None = None  # issue: t_s + d_func (result on stream / word or row usable)

    def to_dict(self) -> dict:
        return {k: v for k, v in asdict(self).items() if v is not None}

    @staticmethod
    def from_dict(d: dict) -> "Event":
        return Event(**d)


@dataclass
class Trace:
    config_name: str
    n_cycles: int
    events: list[Event] = field(default_factory=list)
    # occupancy[t] = sorted list of (dir, stream, pos, tag) for every non-empty cell during cycle t
    occupancy: list[list[tuple[str, int, int, str]]] = field(default_factory=list)
    # digests[t] = sha256 hex over every cell's bytes and tag during cycle t
    digests: list[str] = field(default_factory=list)

    def to_obj(self) -> dict:
        return {
            "config_name": self.config_name,
            "n_cycles": self.n_cycles,
            "events": [e.to_dict() for e in self.events],
            "occupancy": [[list(c) for c in cyc] for cyc in self.occupancy],
            "digests": list(self.digests),
        }

    def to_json(self) -> str:
        """Canonical JSON: equal traces give byte-equal strings."""
        return json.dumps(self.to_obj(), sort_keys=True, separators=(",", ":"))

    @staticmethod
    def from_json(s: str) -> "Trace":
        o = json.loads(s)
        return Trace(
            config_name=o["config_name"],
            n_cycles=o["n_cycles"],
            events=[Event.from_dict(e) for e in o["events"]],
            occupancy=[[tuple(c) for c in cyc] for cyc in o["occupancy"]],
            digests=list(o["digests"]),
        )

    def digest(self) -> str:
        return hashlib.sha256(self.to_json().encode()).hexdigest()

    def by_kind(self, kind: str) -> list[Event]:
        return [e for e in self.events if e.kind == kind]
