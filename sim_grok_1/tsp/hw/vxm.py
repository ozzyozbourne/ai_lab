"""VXM: point-wise ALUs at the centre of the chip.

Each of the `vxm_alus` ALUs (ledger G12) has its own queue (ledger G14) and
executes one Vxm instruction per cycle.  Operations and data types follow
ledger B11: operands are int32 or fp32, except `cast` from fp16.  Latency
classes are T8 (simple), T9 (mul) and T10 (transcendental), looked up by the
simulator in config.latency.

Arithmetic (ledger B11, B19, B20):
- add, sub, mul, neg, relu keep the data type; int32 wraps modulo 2**32.
- fp32 add, sub, mul are single float32 NumPy operations.
- relu keeps lanes with x > 0 and sets every other lane to +0.
- tanh, exp: numpy.tanh / numpy.exp on float32 arrays; rsqrt: float32(1) / numpy.sqrt(x).
- cast: fp32 -> fp16 (round to nearest even), fp16 -> fp32, int32 -> fp32.
- requant: int32 arithmetic shift right by `imm`, then saturate to int8.
Only lanes below `n` are computed; lanes >= n of the result are zero (B19).
"""

import numpy as np

from .. import isa, params
from ..errors import ProgramError

_SAME_TYPE = {"int32": "int32", "fp32": "fp32"}
_FP32_ONLY = {"fp32": "fp32"}

# op -> {operand dtype: result dtype}
LEGAL = {
    "add": _SAME_TYPE,
    "sub": _SAME_TYPE,
    "mul": _SAME_TYPE,
    "neg": _SAME_TYPE,
    "relu": _SAME_TYPE,
    "tanh": _FP32_ONLY,
    "exp": _FP32_ONLY,
    "rsqrt": _FP32_ONLY,
    "cast": {"fp32": "fp16", "fp16": "fp32", "int32": "fp32"},
    "requant": {"int32": "int8"},
}


def is_binary(op):
    return op in params.VXM_BINARY_OPS


def result_dtype(instr):
    """Result data type of a Vxm instruction; raises ProgramError for an illegal op/dtype pair."""
    table = LEGAL.get(instr.op)
    if table is None:
        raise ProgramError(f"unknown VXM operation {instr.op!r}")
    if instr.dtype not in table:
        raise ProgramError(f"VXM {instr.op} does not accept {instr.dtype}")
    want = table[instr.dtype]
    if instr.op == "cast":
        if instr.out_dtype != want:
            raise ProgramError(f"VXM cast {instr.dtype} -> {instr.out_dtype!r} is not supported")
        return want
    if instr.out_dtype not in ("", want):
        raise ProgramError(f"VXM {instr.op} on {instr.dtype} gives {want}, not {instr.out_dtype}")
    return want


def operand_refs(instr):
    """Stream operands in operand order: (a,) or (a, b).  For op(a, a), b equals a."""
    if is_binary(instr.op):
        if instr.b is None:
            raise ProgramError(f"VXM {instr.op} needs two operands")
        return (instr.a, instr.b)
    return (instr.a,)


def _apply(op, dtype, a, b, imm):
    """The operation on lanes below n.  a, b are arrays of the operand dtype."""
    if op == "add":
        return a + b
    if op == "sub":
        return a - b
    if op == "mul":
        return a * b
    if op == "neg":
        return -a
    if op == "relu":
        return np.where(a > a.dtype.type(0), a, a.dtype.type(0))
    if op == "tanh":
        return np.tanh(a)
    if op == "exp":
        return np.exp(a)
    if op == "rsqrt":
        return np.float32(1) / np.sqrt(a)
    if op == "requant":
        shifted = np.right_shift(a, np.int32(imm))
        return np.clip(shifted, params.INT8_MIN, params.INT8_MAX).astype(np.int8)
    if op == "cast":
        return a
    raise ProgramError(f"unknown VXM operation {op!r}")


def compute(instr, operands, lanes):
    """Evaluate a Vxm instruction.

    operands: arrays (length `lanes`, operand dtype) in operand order.
    Returns a `lanes`-long array of the result dtype, zero at lanes >= n (B19).
    """
    out_dt = result_dtype(instr)
    n = instr.n
    a = operands[0][:n]
    b = operands[1][:n] if len(operands) > 1 else None
    with np.errstate(all="ignore"):
        r = _apply(instr.op, instr.dtype, a, b, instr.imm)
    result = np.zeros(lanes, dtype=isa.np_dtype(out_dt))
    result[:n] = np.asarray(r).astype(isa.np_dtype(out_dt))
    return result
