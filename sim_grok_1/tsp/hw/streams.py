"""Stream registers: SR[dir][s][x].

The chip has `streams_per_dir` streams flowing east and as many flowing west
(ledger G3).  Each stream has one register per position (ledger G8).  A
register is either empty (None) or holds a StreamVal: one byte per lane
(ledger G4), a value id and a debug tag (ledger B16).

Every cycle each eastward value moves from x to x+1 and each westward value
from x to x-1, one position per cycle (ledger T1).  A value that moves past
the chip edge is dropped (ledger B1).  Reading a register never empties it
(ledger B2).
"""

from dataclasses import dataclass

import numpy as np

from .. import isa


@dataclass(frozen=True)
class StreamVal:
    """One byte-plane in flight: `lanes` uint8 bytes, a value id and a debug tag."""

    data: np.ndarray
    vid: int
    tag: str


class StreamFile:
    """All stream registers of the chip, both directions."""

    def __init__(self, n_streams, n_positions):
        self.n_streams = n_streams
        self.n_positions = n_positions
        self.regs = {d: [[None] * n_positions for _ in range(n_streams)] for d in isa.DIRS}

    def get(self, d, s, x):
        """Contents of SR[d][s][x] (a StreamVal or None)."""
        return self.regs[d][s][x]

    def put(self, d, s, x, val):
        """Replace SR[d][s][x] with val; return what was there before (ledger T3)."""
        old = self.regs[d][s][x]
        self.regs[d][s][x] = val
        return old

    def shift(self):
        """Move every value one position in its direction; drop values leaving the chip (T1, B1)."""
        empty = [None]
        for row in self.regs["E"]:
            row[:] = empty + row[:-1]
        for row in self.regs["W"]:
            row[:] = row[1:] + empty

    def occupied(self):
        """Yield (dir, s, x, StreamVal) for every occupied register: E before W, then stream, then position."""
        for d in isa.DIRS:
            for s in range(self.n_streams):
                row = self.regs[d][s]
                for x in range(self.n_positions):
                    if row[x] is not None:
                        yield d, s, x, row[x]

    def any_occupied(self):
        return any(True for _ in self.occupied())
