"""Stream-group reference rules shared by every unit (plan.md 2.4, L-G8)."""
from __future__ import annotations

from ..config import ChipConfig
from ..isa import DType, SRef
from .errors import OPERAND_RULE, Violation

# Widths a stream group may have: the byte counts of the data types (L-G6, L-G7).
GROUP_WIDTHS = tuple(sorted({d.nbytes for d in DType}))


def check_sref(config: ChipConfig, ref: SRef, width: int, what: str, direction: str | None = None) -> None:
    """Width, range, alignment and (optionally) direction of one stream group."""
    if ref.n != width:
        raise Violation(OPERAND_RULE, f"{what}: {ref.n} streams, need {width}")
    if ref.base < 0 or ref.base + ref.n > config.streams_per_dir:
        raise Violation(OPERAND_RULE, f"{what}: streams {ref.base}..{ref.base + ref.n - 1} out of range "
                                      f"0..{config.streams_per_dir - 1}")
    if ref.base % width != 0:
        raise Violation(OPERAND_RULE, f"{what}: base stream {ref.base} is not a multiple of {width}")
    if direction is not None and ref.dir != direction:
        raise Violation(OPERAND_RULE, f"{what}: must flow {direction}, got {ref.dir}")
