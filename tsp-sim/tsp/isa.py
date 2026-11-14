"""Instruction set and data-type encoding shared by the compiler and the simulator.

Pure data: no behaviour beyond encoding helpers. Semantics are in plan.md section 2.
"""
from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import Union

import numpy as np

from .config import DIRS


class DType(Enum):
    I8 = "i8"
    F16 = "f16"
    I32 = "i32"
    F32 = "f32"

    @property
    def nbytes(self) -> int:
        """Bytes per element == streams per value == alignment of the base stream."""
        return {
            DType.I8: 1,   # L-G6
            DType.F16: 2,  # L-G7
            DType.I32: 4,  # L-G6
            DType.F32: 4,  # L-G6
        }[self]

    @property
    def np(self) -> np.dtype:
        # Explicit little-endian so byte planes are identical on every host.
        return np.dtype({DType.I8: "<i1", DType.F16: "<f2", DType.I32: "<i4", DType.F32: "<f4"}[self])

    @property
    def is_float(self) -> bool:
        return self in (DType.F16, DType.F32)


@dataclass(frozen=True)
class SRef:
    """A group of adjacent streams at the issuing unit's position.

    `dir` is the direction of flow. `tags` has one entry per stream: the tag the
    instruction expects to find (operand) or the tag it produces (result).
    """
    dir: str
    base: int
    tags: tuple[str, ...]

    def __post_init__(self):
        if self.dir not in DIRS:
            raise ValueError(f"bad direction {self.dir!r}")
        if not self.tags:
            raise ValueError("SRef needs at least one stream")

    @property
    def n(self) -> int:
        return len(self.tags)

    @property
    def streams(self) -> tuple[int, ...]:
        return tuple(range(self.base, self.base + self.n))


def plane_tags(value: str, dtype: DType) -> tuple[str, ...]:
    """Tags of the byte planes of value `value`: plane j is f'{value}#{j}'."""
    return tuple(f"{value}#{j}" for j in range(dtype.nbytes))


def value_of_tag(tag: str) -> str:
    """Inverse of plane_tags for one tag: 'x#2' -> 'x'."""
    return tag.rsplit("#", 1)[0]


# ---- MEM ------------------------------------------------------------------
@dataclass(frozen=True)
class Read:
    bank: int
    addr: int
    out: SRef       # exactly one stream; out.tags[0] is the tag expected in the word


@dataclass(frozen=True)
class Write:
    bank: int
    addr: int
    src: SRef       # exactly one stream


# ---- VXM ------------------------------------------------------------------
VOPS_BINARY = ("ADD", "SUB", "MUL")
VOPS_UNARY_ARITH = ("RELU", "REQUANT", "CAST")
VOPS_TRANS = ("EXP", "RSQRT", "TANH")
VOPS = VOPS_BINARY + VOPS_UNARY_ARITH + VOPS_TRANS


@dataclass(frozen=True)
class VOp:
    op: str                 # one of VOPS
    dtype: DType            # operand dtype
    a: SRef
    b: SRef | None          # second operand for ADD/SUB/MUL, else None
    out: SRef
    imm: int = 0            # REQUANT: right-shift amount
    to: DType | None = None  # CAST: target dtype

    @property
    def out_dtype(self) -> DType:
        if self.op == "REQUANT":
            return DType.I8
        if self.op == "CAST":
            assert self.to is not None
            return self.to
        return self.dtype


CASTS = ((DType.I8, DType.I32), (DType.F32, DType.F16), (DType.F16, DType.F32))  # L-V6


# ---- MXM ------------------------------------------------------------------
@dataclass(frozen=True)
class IW:
    dtype: DType                              # I8 or F16
    rows: tuple[tuple[int, SRef], ...]        # (row index, where the row is on the streams)


@dataclass(frozen=True)
class MatVec:
    dtype: DType                 # I8 or F16 (operand dtype); result is I32 or F32
    k: int                       # rows 0..k-1 take part
    a: SRef
    out: SRef
    expect_rows: tuple[str, ...]  # expect_rows[r] == tag of installed row r (first plane tag)

    @property
    def out_dtype(self) -> DType:
        return DType.I32 if self.dtype == DType.I8 else DType.F32


# ---- SXM ------------------------------------------------------------------
@dataclass(frozen=True)
class Shift:
    n: int
    a: SRef
    out: SRef


@dataclass(frozen=True)
class Permute:
    map: tuple[int, ...]
    a: SRef
    out: SRef


@dataclass(frozen=True)
class Distribute:
    map: tuple[int, ...]
    a: SRef
    out: SRef


Instr = Union[Read, Write, VOp, IW, MatVec, Shift, Permute, Distribute]


# ---- queue entries --------------------------------------------------------
@dataclass(frozen=True)
class Nop:
    n: int


@dataclass(frozen=True)
class Issue:
    instrs: tuple[Instr, ...]


Entry = Union[Nop, Issue]


def entry_cycles(entry: Entry) -> int:
    return entry.n if isinstance(entry, Nop) else 1


def issue_cycles(queue: list[Entry]) -> list[tuple[int, Instr]]:
    """(issue cycle, instruction) for every instruction of a queue, in order."""
    out, t = [], 0
    for e in queue:
        if isinstance(e, Issue):
            out.extend((t, i) for i in e.instrs)
        t += entry_cycles(e)
    return out


def opcode(instr: Instr) -> str:
    """Short opcode used in traces and listings."""
    if isinstance(instr, Read):
        return "READ"
    if isinstance(instr, Write):
        return "WRITE"
    if isinstance(instr, VOp):
        return instr.op
    if isinstance(instr, IW):
        return "IW"
    if isinstance(instr, MatVec):
        return "MATVEC"
    if isinstance(instr, Shift):
        return "SHIFT"
    if isinstance(instr, Permute):
        return "PERMUTE"
    if isinstance(instr, Distribute):
        return "DISTRIBUTE"
    raise TypeError(instr)


def timing_key(instr: Instr) -> str:
    """Which ChipConfig.timing entry applies to this instruction."""
    if isinstance(instr, Read):
        return "READ"
    if isinstance(instr, Write):
        return "WRITE"
    if isinstance(instr, VOp):
        return "VTRANS" if instr.op in VOPS_TRANS else "VARITH"
    if isinstance(instr, IW):
        return "IW"
    if isinstance(instr, MatVec):
        return "MATVEC"
    return "SXM"


def unit_kind(instr: Instr) -> str:
    """Kind of unit that may issue this instruction."""
    if isinstance(instr, (Read, Write)):
        return "MEM"
    if isinstance(instr, VOp):
        return "VXM"
    if isinstance(instr, (IW, MatVec)):
        return "MXM"
    return "SXM"


# ---- byte-plane encoding (plan 2.4) ---------------------------------------
def to_bytes(values, dtype: DType, lanes: int) -> np.ndarray:
    """Encode up to `lanes` elements as byte planes: shape (dtype.nbytes, lanes), uint8.

    Plane j holds little-endian byte j of every element. Missing lanes are zero.
    """
    v = np.asarray(values)
    if v.ndim != 1 or v.shape[0] > lanes:
        raise ValueError(f"need a vector of at most {lanes} elements, got shape {v.shape}")
    full = np.zeros(lanes, dtype=dtype.np)
    full[: v.shape[0]] = v.astype(dtype.np)
    return np.ascontiguousarray(full.view(np.uint8).reshape(lanes, dtype.nbytes).T)


def from_bytes(planes: np.ndarray, dtype: DType) -> np.ndarray:
    """Inverse of to_bytes: (dtype.nbytes, lanes) uint8 -> `lanes` elements."""
    p = np.asarray(planes, dtype=np.uint8)
    if p.ndim != 2 or p.shape[0] != dtype.nbytes:
        raise ValueError(f"need {dtype.nbytes} planes, got shape {p.shape}")
    return np.ascontiguousarray(p.T).view(dtype.np).reshape(-1).copy()


# ---- listing --------------------------------------------------------------
def _sref(s: SRef) -> str:
    rng = f"{s.base}" if s.n == 1 else f"{s.base}-{s.base + s.n - 1}"
    return f"{s.dir}{rng}<{value_of_tag(s.tags[0])}>"


def text(instr: Instr) -> str:
    """One-line assembly-like rendering."""
    if isinstance(instr, Read):
        return f"READ b{instr.bank}@{instr.addr} -> {instr.out.dir}{instr.out.base}<{instr.out.tags[0]}>"
    if isinstance(instr, Write):
        return f"WRITE {instr.src.dir}{instr.src.base}<{instr.src.tags[0]}> -> b{instr.bank}@{instr.addr}"
    if isinstance(instr, VOp):
        ops = _sref(instr.a) + (", " + _sref(instr.b) if instr.b is not None else "")
        extra = f" >>{instr.imm}" if instr.op == "REQUANT" else (f" to {instr.to.value}" if instr.op == "CAST" else "")
        return f"{instr.op}.{instr.dtype.value} {ops}{extra} -> {_sref(instr.out)}"
    if isinstance(instr, IW):
        rows = ", ".join(f"r{r}={_sref(s)}" for r, s in instr.rows)
        return f"IW.{instr.dtype.value} {rows}"
    if isinstance(instr, MatVec):
        return f"MATVEC.{instr.dtype.value} k={instr.k} {_sref(instr.a)} -> {_sref(instr.out)}"
    if isinstance(instr, Shift):
        return f"SHIFT {instr.n:+d} {_sref(instr.a)} -> {_sref(instr.out)}"
    if isinstance(instr, Permute):
        return f"PERMUTE {_sref(instr.a)} -> {_sref(instr.out)}"
    if isinstance(instr, Distribute):
        return f"DISTRIBUTE {_sref(instr.a)} -> {_sref(instr.out)}"
    raise TypeError(instr)
