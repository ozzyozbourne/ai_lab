"""MXM planes: weight install and matrix-vector product (plan.md 2.8, L-X1..L-X9).

Each plane (one queue, `MXM_W.0`, ...) owns a weight buffer of `lanes` rows. A
row is (byte planes, dtype, tag). Rows sampled by an IW become usable at
`t_s + d_func(IW)`; the cycle loop calls `install` at that cycle, and the L-X9
clearing rules are applied at the same moment.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from .. import numerics
from ..config import EAST, WEST, ChipConfig
from ..isa import IW, DType, MatVec, from_bytes, to_bytes
from .errors import FP16_UNIT, OPERAND_RULE, WEIGHT_ROW, Violation
from .operands import check_sref

MXM_DTYPES = (DType.I8, DType.F16)


@dataclass(frozen=True)
class Row:
    planes: np.ndarray     # (dtype.nbytes, lanes) uint8
    dtype: DType
    tag: str               # tag seen on the row's first stream


def plane_index(unit: str) -> int:
    return int(unit.split(".")[1])


def directions(config: ChipConfig, unit: str) -> tuple[str, str]:
    """(operand direction, result direction): outward in, inward out (L-X6)."""
    return (WEST, EAST) if config.hemi(unit) == WEST else (EAST, WEST)


def k_max(config: ChipConfig, dtype: DType) -> int:
    """lanes for I8, lanes/2 for F16 (L-X2, L-X8)."""
    return config.lanes // dtype.nbytes


class MXM:
    """Weight buffers of every MXM plane of the chip."""

    def __init__(self, config: ChipConfig):
        self.cfg = config
        self.rows: dict[str, dict[int, Row]] = {
            u: {} for u in config.unit_names() if config.kind(u) == "MXM"}

    def _siblings(self, unit: str) -> list[str]:
        s = self.cfg.slice_of(unit)
        return [u for u in self.cfg.units_of(s) if u != unit]

    def _plane0(self, unit: str) -> str:
        return self.cfg.units_of(self.cfg.slice_of(unit))[0]

    def holds_f16(self, unit: str) -> bool:
        return any(r.dtype == DType.F16 for r in self.rows[unit].values())

    # ---- issue-time rules ---------------------------------------------------
    def check_instr(self, unit: str, instr) -> None:
        cfg = self.cfg
        plane = plane_index(unit)
        # L-X9 first: the fp16 unit rule.
        if instr.dtype == DType.F16 and plane != 0:
            raise Violation(FP16_UNIT, f"F16 {type(instr).__name__} is legal only on plane .0")
        if plane != 0 and self.holds_f16(self._plane0(unit)):
            raise Violation(FP16_UNIT, f"plane .{plane} must stay idle while {self._plane0(unit)} holds F16 rows")
        if instr.dtype not in MXM_DTYPES:
            raise Violation(OPERAND_RULE, f"MXM dtype must be I8 or F16, got {instr.dtype.value}")
        d_in, d_out = directions(cfg, unit)
        w = instr.dtype.nbytes
        if isinstance(instr, IW):
            if not instr.rows:
                raise Violation(OPERAND_RULE, "IW installs no row")
            seen: dict[int, bool] = {}
            for r, ref in instr.rows:
                if not 0 <= r < cfg.lanes:
                    raise Violation(OPERAND_RULE, f"row index {r} out of range 0..{cfg.lanes - 1}")
                if r in seen:
                    raise Violation(OPERAND_RULE, f"row {r} listed twice in one IW")
                seen[r] = True
                check_sref(cfg, ref, w, f"IW row {r}", d_in)
            total = sum(ref.n for _, ref in instr.rows)
            if total > cfg.iw_max_streams:
                raise Violation(OPERAND_RULE, f"IW samples {total} streams, at most {cfg.iw_max_streams} (L-X3)")
        else:
            kmax = k_max(cfg, instr.dtype)
            if not 1 <= instr.k <= kmax:
                raise Violation(OPERAND_RULE, f"k={instr.k} out of range 1..{kmax}")
            if len(instr.expect_rows) != instr.k:
                raise Violation(WEIGHT_ROW, f"len(expect_rows)={len(instr.expect_rows)} != k={instr.k}")
            check_sref(cfg, instr.a, w, "activation", d_in)
            check_sref(cfg, instr.out, instr.out_dtype.nbytes, "result", d_out)

    # ---- state changes ------------------------------------------------------
    def install(self, unit: str, dtype: DType, rows: list[tuple[int, Row]]) -> None:
        """Rows of one IW become usable (called at t_s + d_func(IW))."""
        if plane_index(unit) == 0:
            if dtype == DType.F16:               # an F16 IW on .0 clears plane .1 (L-X9)
                for u in self._siblings(unit):
                    self.rows[u].clear()
            else:                                # an I8 IW on .0 clears its F16 rows (L-X9)
                buf = self.rows[unit]
                for r in [r for r, row in buf.items() if row.dtype == DType.F16]:
                    del buf[r]
        for r, row in rows:
            self.rows[unit][r] = row

    def used_rows(self, unit: str, instr: MatVec) -> list[Row]:
        """Rows 0..k-1 for a MATVEC at its sample cycle (fault 5 if missing or of another dtype)."""
        buf = self.rows[unit]
        out = []
        for r in range(instr.k):
            row = buf.get(r)
            if row is None:
                raise Violation(WEIGHT_ROW, f"row {r} is not installed")
            if row.dtype != instr.dtype:
                raise Violation(WEIGHT_ROW, f"row {r} holds {row.dtype.value}, MATVEC is {instr.dtype.value}")
            out.append(row)
        return out


def matvec(config: ChipConfig, instr: MatVec, a: np.ndarray, rows: list[Row]) -> np.ndarray:
    """a: activation byte planes. Returns the result's byte planes (I32 or F32)."""
    x = from_bytes(a, instr.dtype)[: instr.k]
    w = np.stack([from_bytes(r.planes, instr.dtype) for r in rows])
    res = numerics.matvec(instr.dtype, x, w)
    return to_bytes(res, instr.out_dtype, config.lanes)
