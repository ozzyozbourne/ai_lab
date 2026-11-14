"""SXM shift / permute / distribute (plan.md 2.9, L-S1..L-S4).

All three act on bytes, identically on every stream of the group.
"""
from __future__ import annotations

import numpy as np

from .. import numerics
from ..config import ChipConfig
from ..isa import Distribute, Permute, Shift
from .errors import OPERAND_RULE, QUEUE_ENTRY, Violation
from .operands import GROUP_WIDTHS, check_sref

# Which SXM queue (config.SXM_UNITS) runs which instruction.
UNIT_OF = {Shift: "shift", Permute: "permute", Distribute: "distribute"}


def check_instr(config: ChipConfig, unit: str, instr) -> None:
    sub = unit.split(".")[1]
    if UNIT_OF[type(instr)] != sub:
        raise Violation(QUEUE_ENTRY, f"{type(instr).__name__} cannot run on the {sub} unit")
    if instr.a.n not in GROUP_WIDTHS:
        raise Violation(OPERAND_RULE, f"operand a: {instr.a.n} streams is not a data-type width {GROUP_WIDTHS}")
    check_sref(config, instr.a, instr.a.n, "operand a")
    check_sref(config, instr.out, instr.a.n, "result")
    lanes, lps = config.lanes, config.lanes_per_superlane
    if isinstance(instr, Permute):
        if len(instr.map) != lanes or sorted(instr.map) != list(range(lanes)):
            raise Violation(OPERAND_RULE, f"permute map must be a bijection on {lanes} lanes")
    if isinstance(instr, Distribute):
        if len(instr.map) != lps or any(not -1 <= m < lps for m in instr.map):
            raise Violation(OPERAND_RULE, f"distribute map needs {lps} entries in -1..{lps - 1}")


def _one_plane(config: ChipConfig, instr, p: np.ndarray) -> np.ndarray:
    if isinstance(instr, Shift):
        return numerics.shift_lanes(p, instr.n)
    if isinstance(instr, Permute):
        return p[np.array(instr.map, dtype=np.int64)]
    # Distribute: out[16j + i] = a[16j + map[i]], or 0 where map[i] = -1
    lps = config.lanes_per_superlane
    blocks = p.reshape(config.superlanes, lps)
    src = np.array([max(m, 0) for m in instr.map], dtype=np.int64)
    keep = np.array([m >= 0 for m in instr.map])
    out = np.where(keep[None, :], blocks[:, src], 0).astype(np.uint8)
    return out.reshape(-1)


def execute(config: ChipConfig, instr, a: np.ndarray) -> np.ndarray:
    """a: (n_streams, lanes) bytes -> same shape."""
    return np.stack([_one_plane(config, instr, a[j]) for j in range(a.shape[0])])
