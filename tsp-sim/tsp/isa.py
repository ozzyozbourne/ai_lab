"""Instruction set: plain data only.  Semantics live in tsp/hw and tsp/icu.

Instruction names follow Table I of the ISCA 2020 paper (dossier 1.4).
The fields are this project's own; the paper gives no encoding.
"""

from dataclasses import dataclass
from typing import Optional, Tuple

import numpy as np

from . import params

DIRS = ("E", "W")
DTYPES = ("int8", "fp16", "int32", "fp32")

_WIDTH = {
    "int8": params.WIDTH_INT8,
    "fp16": params.WIDTH_FP16,
    "int32": params.WIDTH_INT32,
    "fp32": params.WIDTH_FP32,
}
_NP = {"int8": np.int8, "fp16": np.float16, "int32": np.int32, "fp32": np.float32}


def width(dtype):
    """Number of byte-streams (planes) one value of this dtype occupies."""
    return _WIDTH[dtype]


def np_dtype(dtype):
    """NumPy dtype for a TSP dtype name."""
    return np.dtype(_NP[dtype])


def to_planes(array, dtype):
    """Split a 1-D array into byte planes: plane j holds byte j (little-endian) of every element."""
    a = np.ascontiguousarray(np.asarray(array, dtype=np_dtype(dtype).newbyteorder("<")))
    raw = a.view(np.uint8).reshape(a.shape[0], width(dtype))
    return [raw[:, j].copy() for j in range(width(dtype))]


def from_planes(planes, dtype):
    """Inverse of to_planes."""
    raw = np.stack([np.asarray(p, dtype=np.uint8) for p in planes], axis=1)
    return np.ascontiguousarray(raw).view(np_dtype(dtype).newbyteorder("<")).reshape(-1).astype(np_dtype(dtype))


def plane_tag(name, j):
    """Debug tag of plane j of the value called name."""
    return f"{name}#{j}"


@dataclass(frozen=True)
class StreamRef:
    """A stream: direction of flow and stream number (the base stream for wide values)."""

    dir: str
    s: int


# --- queue control (executed by the ICU, never dispatched to a unit) ---------
@dataclass(frozen=True)
class Sync:
    pass


@dataclass(frozen=True)
class Notify:
    pass


@dataclass(frozen=True)
class Nop:
    n: int


@dataclass(frozen=True)
class Repeat:
    n: int
    d: int


# --- MEM ---------------------------------------------------------------------
@dataclass(frozen=True)
class Read:
    addr: int
    out: StreamRef
    tag: str = ""


@dataclass(frozen=True)
class Write:
    addr: int
    src: StreamRef
    expect: Tuple[str, ...] = ()


# --- VXM ---------------------------------------------------------------------
@dataclass(frozen=True)
class Vxm:
    """Point-wise operation on one ALU.

    dtype is the operand type.  out_dtype differs from dtype only for
    'cast' and 'requant'.  imm is the shift amount of 'requant'.
    n is the vector length: result lanes >= n are zero (ledger B19).
    For op(a, a) both a and b hold the same StreamRef.
    tag is the debug name of the result (without plane suffix);
    expect holds the debug names of operands a and b (without plane suffix).
    """

    op: str
    dtype: str
    a: StreamRef
    b: Optional[StreamRef]
    out: StreamRef
    n: int
    out_dtype: str = ""
    imm: int = 0
    tag: str = ""
    expect: Tuple[str, ...] = ()

    def result_dtype(self):
        return self.out_dtype or self.dtype


# --- MXM ---------------------------------------------------------------------
@dataclass(frozen=True)
class Iw:
    """Install weight rows.  entries = ((row index, StreamRef of that row), ...).

    expect holds one debug name per entry, in entry order.
    """

    dtype: str
    entries: Tuple[Tuple[int, StreamRef], ...]
    expect: Tuple[str, ...] = ()


@dataclass(frozen=True)
class Abc:
    """Multiply the installed weights by the activation on src; rows >= n_rows give zero."""

    dtype: str
    src: StreamRef
    out: StreamRef
    n_rows: int
    tag: str = ""
    expect: Tuple[str, ...] = ()

    def result_dtype(self):
        return "int32" if self.dtype == "int8" else "fp32"


# --- SXM ---------------------------------------------------------------------
@dataclass(frozen=True)
class Distribute:
    """Within each superlane, lane i receives lane map[i] of that superlane (-1 gives zero).

    map has lanes_per_superlane entries.  Result lanes >= n are zero.
    """

    width: int
    src: StreamRef
    out: StreamRef
    map: Tuple[int, ...]
    n: int
    tag: str = ""
    expect: Tuple[str, ...] = ()


@dataclass(frozen=True)
class Permute:
    """out[i] = in[map[i]]; map is a bijection over all lanes.  Result lanes >= n are zero."""

    width: int
    src: StreamRef
    out: StreamRef
    map: Tuple[int, ...]
    n: int
    tag: str = ""
    expect: Tuple[str, ...] = ()


@dataclass(frozen=True)
class Shift:
    """out[i] = in[i - shift], zero fill.  Result lanes >= n are zero."""

    width: int
    src: StreamRef
    out: StreamRef
    shift: int
    n: int
    tag: str = ""
    expect: Tuple[str, ...] = ()


QUEUE_CONTROL = (Sync, Notify, Nop, Repeat)
MEM_INSTRS = (Read, Write)
VXM_INSTRS = (Vxm,)
MXM_INSTRS = (Iw, Abc)
SXM_INSTRS = (Distribute, Permute, Shift)
ALLOWED = {"MEM": MEM_INSTRS, "VXM": VXM_INSTRS, "MXM": MXM_INSTRS, "SXM": SXM_INSTRS}


def kind_of(instr):
    """Latency-table key for a data instruction (see params.default_latency)."""
    if isinstance(instr, Vxm):
        return instr.op
    return type(instr).__name__.lower()
