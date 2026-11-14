"""Stream cells and the shift rule (plan.md 2.2).

A cell is (dir, stream, x). During a cycle it is empty or holds one `lanes`-byte
vector and a tag. Between cycles every eastward cell takes the content of its
western neighbour and every westward cell that of its eastern neighbour; the
cycle loop then overwrites the cells that are driven in the new cycle.

Invariant: an empty cell holds zero bytes, so the per-cycle digest only depends
on what is on the streams.
"""
from __future__ import annotations

import hashlib
import json

import numpy as np

from ..config import DIRS, EAST, ChipConfig
from .errors import OPERAND_RULE, Violation


class Streams:
    def __init__(self, config: ChipConfig):
        n_streams, n_pos, lanes = config.streams_per_dir, config.n_positions, config.lanes
        self.n_streams = n_streams
        self.n_pos = n_pos
        self.data = {d: np.zeros((n_streams, n_pos, lanes), dtype=np.uint8) for d in DIRS}
        self.tags = {d: np.full((n_streams, n_pos), None, dtype=object) for d in DIRS}
        self.full = {d: np.zeros((n_streams, n_pos), dtype=bool) for d in DIRS}
        self._empty_digest = None

    # ---- shift rule -------------------------------------------------------
    def shift(self) -> None:
        """Turn C_t into the undriven part of C_{t+1}."""
        for d in DIRS:
            full = self.full[d]
            if not full.any():
                continue
            data, tags = self.data[d], self.tags[d]
            if d == EAST:      # C_{t+1}(E, s, x) = C_t(E, s, x-1); empty at x = 0
                data[:, 1:] = data[:, :-1]
                tags[:, 1:] = tags[:, :-1]
                full[:, 1:] = full[:, :-1]
                edge = 0
            else:              # C_{t+1}(W, s, x) = C_t(W, s, x+1); empty at x = P-1
                data[:, :-1] = data[:, 1:]
                tags[:, :-1] = tags[:, 1:]
                full[:, :-1] = full[:, 1:]
                edge = -1
            data[:, edge] = 0
            tags[:, edge] = None
            full[:, edge] = False

    # ---- access -------------------------------------------------------------
    def check_cell(self, d: str, s: int, x: int) -> None:
        if not (0 <= s < self.n_streams and 0 <= x < self.n_pos):
            raise Violation(OPERAND_RULE, f"cell ({d}, {s}, {x}) is outside the chip")

    def get(self, d: str, s: int, x: int):
        """(bytes copy, tag) of a cell, or None if it is empty. Reading does not consume."""
        self.check_cell(d, s, x)
        if not self.full[d][s, x]:
            return None
        return self.data[d][s, x].copy(), self.tags[d][s, x]

    def put(self, d: str, s: int, x: int, data: np.ndarray, tag: str) -> None:
        self.check_cell(d, s, x)
        self.data[d][s, x] = data
        self.tags[d][s, x] = tag
        self.full[d][s, x] = True

    # ---- recording ----------------------------------------------------------
    def is_empty(self) -> bool:
        return not any(self.full[d].any() for d in DIRS)

    def occupancy(self) -> list[tuple[str, int, int, str]]:
        """(dir, stream, pos, tag) of every non-empty cell, sorted."""
        out = []
        for d in sorted(DIRS):
            tags = self.tags[d]
            for s, x in np.argwhere(self.full[d]).tolist():   # row-major: sorted by (stream, pos)
                out.append((d, int(s), int(x), tags[s, x]))
        return out

    def digest(self) -> str:
        """sha256 over every cell's bytes and tag, East then West, stream-major."""
        if self.is_empty() and self._empty_digest is not None:
            return self._empty_digest
        h = hashlib.sha256()
        for d in DIRS:
            h.update(d.encode())
            h.update(self.data[d].tobytes())
            h.update(json.dumps(self.tags[d].tolist()).encode())
        out = h.hexdigest()
        if self.is_empty():
            self._empty_digest = out
        return out
