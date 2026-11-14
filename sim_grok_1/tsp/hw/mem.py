"""MEM slices.

One address holds one vector of `lanes` bytes (ledger B5); a slice has
`mem_words` addresses (ledger G9).  A slice executes one instruction per
cycle, a Read or a Write (ledger B4); banks are not modelled (ledger B17).

- Read(addr, out): the word is sampled on the dispatch cycle and appears on
  stream `out` at the slice's own position d_func cycles later (ledger T6, T3).
- Write(addr, src): the plane on stream `src` is sampled on the dispatch
  cycle t and stored at the end of cycle t + d_func - 1 (ledger T7).

Reading an address that was never written (and was not in the memory image
or poked as an input, ledger B22) raises EmptyOperandError.
"""

import numpy as np

from ..errors import EmptyOperandError


class Memory:
    """The words of every MEM slice, keyed by (slice name, address)."""

    def __init__(self, lanes, mem_words):
        self.lanes = lanes
        self.mem_words = mem_words
        self.words = {}

    def _check(self, unit, addr, data=None):
        if not 0 <= addr < self.mem_words:
            raise EmptyOperandError(f"{unit}: address {addr} out of range")
        if data is not None and len(data) != self.lanes:
            raise ValueError(f"{unit}[{addr}]: word must have {self.lanes} bytes, got {len(data)}")

    def read(self, unit, addr):
        """Return a copy of the word at (unit, addr) as a uint8 vector."""
        self._check(unit, addr)
        key = (unit, addr)
        if key not in self.words:
            raise EmptyOperandError(f"{unit}: read of address {addr}, which was never written")
        return self.words[key].copy()

    def write(self, unit, addr, data):
        """Store a word (bytes or uint8 vector of `lanes` bytes)."""
        arr = np.frombuffer(bytes(data), dtype=np.uint8).copy() if isinstance(data, (bytes, bytearray)) \
            else np.asarray(data, dtype=np.uint8).copy()
        self._check(unit, addr, arr)
        self.words[(unit, addr)] = arr

    def has(self, unit, addr):
        return (unit, addr) in self.words
