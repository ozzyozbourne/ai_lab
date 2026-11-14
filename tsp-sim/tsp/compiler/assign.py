"""Pass 2 (plan 5.3): unit assignment. Runs before placement because placement uses it.

Output: `units[oid]`, a unit name for MXM and SXM operations and the slice name
"VXM" for VXM operations (the ALU index is chosen by the scheduler, plan 5.6).

Rules:
- I8 MATVECs take planes in the rotation MXM_W.0, MXM_E.0, MXM_W.1, MXM_E.1 (plane
  index outer, hemisphere inner); F16 MATVECs alternate MXM_W.0, MXM_E.0 (L-X9).
- SHIFT goes to the SXM of the hemisphere where its operand is produced. Policy
  where the plan is open: an operand produced at the VXM, or a stored leaf,
  counts as West. (A leaf's hemisphere is itself derived from its first
  consumer, so "West" breaks that circularity; placement then puts such a leaf
  West, and a VXM value whose first consumer is that shift is parked West.)
"""
from __future__ import annotations

from ..config import EAST, WEST, ChipConfig
from ..isa import DType
from .tiling import MATVEC, Tiled

VXM = "VXM"


def mxm_rotation(dtype: DType, config: ChipConfig) -> list[str]:
    planes = range(config.planes_per_mxm) if dtype == DType.I8 else range(1)
    return [f"MXM_{h}.{p}" for p in planes for h in (WEST, EAST)]


def assign_units(tg: Tiled, config: ChipConfig) -> list[str]:
    units: list[str] = []
    turn = 0
    for op in tg.ops:
        if op.kind == MATVEC:
            rot = mxm_rotation(op.in_dtype, config)
            units.append(rot[turn % len(rot)])
            turn += 1
        elif op.kind == "shift":
            prod = tg.vals[op.operands[0]].producer
            h = WEST
            if prod is not None and units[prod] != VXM:
                h = config.hemi(units[prod])
            units.append(f"SXM_{h}.shift")
        else:
            units.append(VXM)
    return units


def unit_pos(unit: str, config: ChipConfig) -> int:
    return config.vxm_pos if unit == VXM else config.pos(unit)
