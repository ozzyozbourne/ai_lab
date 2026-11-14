"""SXM: lane-moving operations (ledger B13, G13).

The value occupies `width` consecutive streams; the same lane map is applied
to every byte plane.  The result appears d_func cycles after dispatch
(ledger T13).  Result lanes >= n are zero (ledger B19).

- Distribute: within each superlane, lane i receives lane map[i] of that
  superlane, or zero if map[i] is -1.  map has lanes_per_superlane entries.
- Permute: out[i] = in[map[i]] over all lanes; map must be a bijection.
- Shift: out[i] = in[i - shift], zero fill (shift may be negative).

Per-tile stagger of SXM operations is not modelled (plan 2.4).
"""

import numpy as np

from .. import isa
from ..errors import ProgramError


def _lane_source(instr, lanes, lanes_per_superlane):
    """For each output lane, the input lane it copies, or -1 for zero."""
    if isinstance(instr, isa.Distribute):
        if len(instr.map) != lanes_per_superlane:
            raise ProgramError(f"Distribute map needs {lanes_per_superlane} entries, got {len(instr.map)}")
        src = []
        for i in range(lanes):
            base = (i // lanes_per_superlane) * lanes_per_superlane
            m = instr.map[i % lanes_per_superlane]
            if not -1 <= m < lanes_per_superlane:
                raise ProgramError(f"Distribute map entry {m} out of range")
            src.append(-1 if m == -1 else base + m)
        return src
    if isinstance(instr, isa.Permute):
        if sorted(instr.map) != list(range(lanes)):
            raise ProgramError("Permute map must be a bijection over all lanes")
        return list(instr.map)
    if isinstance(instr, isa.Shift):
        return [i - instr.shift if 0 <= i - instr.shift < lanes else -1 for i in range(lanes)]
    raise ProgramError(f"not an SXM instruction: {instr!r}")


def compute(instr, planes, lanes, lanes_per_superlane):
    """Apply the lane map to every uint8 plane; zero lanes >= n.  Returns a list of planes."""
    src = _lane_source(instr, lanes, lanes_per_superlane)
    out = []
    for p in planes:
        q = np.zeros(lanes, dtype=np.uint8)
        for i in range(instr.n):
            if src[i] != -1:
                q[i] = p[src[i]]
        out.append(q)
    return out
