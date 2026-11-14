"""Arithmetic kernels shared by the simulator and the bit-exact reference.

One definition of every operation's numerics, so that "the chip" and "the
reference" cannot drift apart in the last bit (plan.md 2.7, 2.8). Everything is
computed with operations whose result is fixed by IEEE 754 or by exact integer
arithmetic, with two exceptions noted at `exp` and `tanh`.
"""
from __future__ import annotations

import math

import numpy as np

from .isa import CASTS, DType

_I8 = np.iinfo(np.int8)
_F32_NAN = np.float32("nan")


def canon(a: np.ndarray) -> np.ndarray:
    """Replace every NaN by one canonical quiet NaN, so bytes do not depend on the CPU."""
    if a.dtype.kind == "f":
        a = a.copy()
        a[np.isnan(a)] = np.array(np.nan, dtype=a.dtype)
    return a


def _wrap_i32(a64: np.ndarray) -> np.ndarray:
    return a64.astype(np.int64).astype(np.uint32).astype(DType.I32.np)  # modulo 2**32 (L-V7)


def _map_f64(fn, a: np.ndarray) -> np.ndarray:
    out = np.empty(a.shape, dtype=np.float64)
    for i, v in enumerate(a.astype(np.float64).tolist()):
        try:
            out[i] = fn(v)
        except OverflowError:
            out[i] = math.inf
        except ValueError:
            out[i] = math.nan
    with np.errstate(over="ignore"):
        return canon(out.astype(DType.F32.np))


def _rsqrt(v: float) -> float:
    if v == 0.0:
        return math.inf
    return 1.0 / math.sqrt(v)   # sqrt and division are correctly rounded; negative raises ValueError -> NaN


def vop(op: str, dtype: DType, a: np.ndarray, b: np.ndarray | None = None,
        imm: int = 0, to: DType | None = None) -> np.ndarray:
    """One VXM operation on whole vectors. Returns an array of the result dtype."""
    a = np.asarray(a, dtype=dtype.np)
    if op in ("ADD", "SUB", "MUL"):
        b = np.asarray(b, dtype=dtype.np)
        if dtype == DType.I32:
            x, y = a.astype(np.int64), b.astype(np.int64)
            return _wrap_i32({"ADD": x + y, "SUB": x - y, "MUL": x * y}[op])
        if dtype == DType.F32:
            with np.errstate(all="ignore"):
                return canon({"ADD": a + b, "SUB": a - b, "MUL": a * b}[op].astype(DType.F32.np))
    elif op == "RELU" and dtype in (DType.I32, DType.F32):
        return canon(np.maximum(a, np.zeros((), dtype=dtype.np)).astype(dtype.np))
    elif op == "REQUANT" and dtype == DType.I32:
        return np.clip(a >> imm, _I8.min, _I8.max).astype(DType.I8.np)   # L-V5
    elif op == "CAST" and (dtype, to) in CASTS:                           # L-V6
        with np.errstate(over="ignore"):
            return canon(a.astype(to.np)) if to.is_float else a.astype(to.np)
    elif dtype == DType.F32 and op == "EXP":
        # math.exp comes from the C library; not guaranteed correctly rounded on every platform.
        return _map_f64(math.exp, a)
    elif dtype == DType.F32 and op == "TANH":
        return _map_f64(math.tanh, a)   # same caveat as EXP
    elif dtype == DType.F32 and op == "RSQRT":
        return _map_f64(_rsqrt, a)
    raise ValueError(f"unsupported VXM operation {op} on {dtype.value}" + (f" -> {to.value}" if to else ""))


def matvec(dtype: DType, x: np.ndarray, rows: np.ndarray) -> np.ndarray:
    """out[l] = sum_r x[r] * rows[r, l].  x: (k,), rows: (k, lanes).

    I8: exact, returned as I32. F16: every product is exact in float64, the sum of
    each lane is the correctly rounded sum (math.fsum, independent of order), then
    rounded once to F32 (L-X4).
    """
    x = np.asarray(x, dtype=dtype.np)
    rows = np.asarray(rows, dtype=dtype.np)
    if rows.ndim != 2 or rows.shape[0] != x.shape[0]:
        raise ValueError(f"matvec shapes {x.shape} x {rows.shape}")
    if dtype == DType.I8:
        return _wrap_i32(x.astype(np.int64) @ rows.astype(np.int64))
    if dtype == DType.F16:
        xs = x.astype(np.float64).tolist()
        cols = rows.astype(np.float64).T.tolist()       # one list of k weights per lane
        out = np.empty(len(cols), dtype=np.float64)
        for l, col in enumerate(cols):
            terms = [xv * w for xv, w in zip(xs, col)]
            try:
                out[l] = math.fsum(terms)
            except (ValueError, OverflowError):
                out[l] = math.nan if any(math.isnan(t) for t in terms) or (
                    math.inf in terms and -math.inf in terms) else (math.inf if math.inf in terms else -math.inf)
        with np.errstate(over="ignore"):
            return canon(out.astype(DType.F32.np))
    raise ValueError(f"matvec on {dtype.value}")


def shift_lanes(a: np.ndarray, n: int) -> np.ndarray:
    """out[l] = a[l - n] if in range else 0 (L-S3). Works on any 1-D array."""
    out = np.zeros_like(a)
    size = a.shape[0]
    if n >= 0:
        out[n:] = a[: max(size - n, 0)]
    else:
        out[: max(size + n, 0)] = a[-n:]
    return out
