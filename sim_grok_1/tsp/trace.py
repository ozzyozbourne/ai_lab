"""The record of one simulation run.  See plan.md section 3.4."""

import hashlib
import json
from dataclasses import dataclass, field
from typing import Dict, List


@dataclass
class Trace:
    config: dict
    n_cycles: int = 0
    # {did, cycle, unit, pos, kind, text, reads: [{dir, s, pos, vid, tag}]}; did = index in this list
    dispatches: List[dict] = field(default_factory=list)
    # {cycle, did, unit, dir, s, pos, vid, tag, overwrote}   overwrote = vid of the replaced value or None
    emissions: List[dict] = field(default_factory=list)
    # [cycle, dir, s, pos, vid]: every occupied stream register on every cycle, after the emit step
    cells: List[list] = field(default_factory=list)
    # {cycle, did, unit, addr, tag}   cycle = commit cycle
    mem_writes: List[dict] = field(default_factory=list)
    # vid (as str) -> {tag, unit, did, cycle}   cycle = emission cycle
    values: Dict[str, dict] = field(default_factory=dict)
    # output name -> hex of the tensor's planes (concatenated, plane 0 first) in MEM at the end of the run
    outputs: Dict[str, str] = field(default_factory=dict)

    def to_obj(self):
        return {
            "config": self.config,
            "n_cycles": self.n_cycles,
            "dispatches": self.dispatches,
            "emissions": self.emissions,
            "cells": self.cells,
            "mem_writes": self.mem_writes,
            "values": self.values,
            "outputs": self.outputs,
        }

    def to_json(self):
        """Canonical text form (sorted keys, no whitespace)."""
        return json.dumps(self.to_obj(), sort_keys=True, separators=(",", ":"))

    @classmethod
    def from_json(cls, text):
        return cls(**json.loads(text))

    def digest(self):
        """SHA-256 of the canonical form.  Equal digests mean identical runs."""
        return hashlib.sha256(self.to_json().encode("utf-8")).hexdigest()
