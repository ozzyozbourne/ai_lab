"""VXM ALUs (plan.md 2.7, L-V1..L-V7). Arithmetic is numerics.vop, nothing else."""
from __future__ import annotations

import numpy as np

from .. import numerics
from ..config import ChipConfig
from ..isa import CASTS, VOPS_BINARY, VOPS_TRANS, DType, VOp, from_bytes, to_bytes
from .errors import OPERAND_RULE, Violation
from .operands import check_sref

_INT_FLOAT = (DType.I32, DType.F32)
_I32_BITS = DType.I32.nbytes * 8  # not a machine parameter: bits per byte


def _legal(instr: VOp) -> bool:
    op, dt = instr.op, instr.dtype
    if op in VOPS_BINARY or op == "RELU":
        return dt in _INT_FLOAT
    if op == "REQUANT":
        return dt == DType.I32 and 0 <= instr.imm < _I32_BITS
    if op == "CAST":
        return (dt, instr.to) in CASTS
    if op in VOPS_TRANS:
        return dt == DType.F32
    return False


def check_instr(config: ChipConfig, instr: VOp) -> None:
    if not _legal(instr):
        to = f" -> {instr.to.value}" if instr.to is not None else ""
        raise Violation(OPERAND_RULE, f"{instr.op} is not defined on {instr.dtype.value}{to} (imm={instr.imm})")
    check_sref(config, instr.a, instr.dtype.nbytes, "operand a")
    if instr.op in VOPS_BINARY:
        if instr.b is None:
            raise Violation(OPERAND_RULE, f"{instr.op} needs operand b")
        check_sref(config, instr.b, instr.dtype.nbytes, "operand b")
    elif instr.b is not None:
        raise Violation(OPERAND_RULE, f"{instr.op} takes one operand")
    check_sref(config, instr.out, instr.out_dtype.nbytes, "result")


def execute(config: ChipConfig, instr: VOp, a: np.ndarray, b: np.ndarray | None) -> np.ndarray:
    """a, b: operand byte planes (nbytes, lanes). Returns the result's byte planes."""
    av = from_bytes(a, instr.dtype)
    bv = from_bytes(b, instr.dtype) if b is not None else None
    res = numerics.vop(instr.op, instr.dtype, av, bv, imm=instr.imm, to=instr.to)
    return to_bytes(res, instr.out_dtype, config.lanes)
