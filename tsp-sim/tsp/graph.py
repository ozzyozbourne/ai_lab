"""A small fixed-shape compute graph: the compiler's input.

Every value is a vector of at most `lanes` elements.  A matrix is an ordered
list of row vectors.  Shapes and dtypes are fixed when a node is added; there
are no implicit casts and no dynamic shapes (dossier section 3, static shapes).

Lanes at or above a tensor's length n are always zero (ledger B19).
"""

from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple

import numpy as np

from . import isa
from .errors import GraphError

UNARY_SAME_TYPE = ("neg", "relu", "tanh", "exp", "rsqrt")
BINARY = ("add", "sub", "mul")
FLOAT_ONLY = ("tanh", "exp", "rsqrt")
CASTS = (("fp32", "fp16"), ("fp16", "fp32"), ("int32", "fp32"))


@dataclass
class Tensor:
    id: int
    name: str
    dtype: str
    n: int
    kind: str                       # "input", "const" or "op"
    data: Optional[np.ndarray] = None   # for kind == "const": length-n array
    op: str = ""                    # for kind == "op": matvec, add, sub, mul, neg, relu, tanh, exp, rsqrt, cast, requant, broadcast
    args: Tuple[int, ...] = ()      # operand tensor ids (vector operands only)
    matrix: Optional[int] = None    # for matvec: matrix id
    attr: int = 0                   # requant: shift; broadcast: source lane


@dataclass
class Matrix:
    id: int
    name: str
    dtype: str
    rows: Tuple[int, ...]           # tensor ids of the rows, row 0 first
    n_cols: int


@dataclass
class Graph:
    name: str
    lanes: int = 16  # not-a-parameter: default equals params.LANES_PER_SUPERLANE * TILES_TOY; pass config.lanes
    tensors: List[Tensor] = field(default_factory=list)
    matrices: List[Matrix] = field(default_factory=list)
    outputs: Dict[str, int] = field(default_factory=dict)

    # -- helpers -------------------------------------------------------------
    def _new(self, name, dtype, n, kind, **kw):
        if dtype not in isa.DTYPES:
            raise GraphError(f"unknown dtype {dtype!r}")
        if not 1 <= n <= self.lanes:
            raise GraphError(f"{name}: length {n} is outside 1..{self.lanes}")
        if any(t.name == name for t in self.tensors):
            raise GraphError(f"duplicate tensor name {name!r}")
        t = Tensor(len(self.tensors), name, dtype, n, kind, **kw)
        self.tensors.append(t)
        return t.id

    def t(self, tid):
        return self.tensors[tid]

    def _auto(self, op):
        return f"{op}{len(self.tensors)}"

    # -- leaves --------------------------------------------------------------
    def input(self, name, dtype, n):
        """A vector supplied by the host before each run."""
        return self._new(name, dtype, n, "input")

    def const(self, name, array, dtype):
        """A constant vector, preloaded into memory."""
        a = np.asarray(array)
        if a.ndim != 1:
            raise GraphError(f"{name}: constant must be 1-D")
        return self._new(name, dtype, a.shape[0], "const", data=a.astype(isa.np_dtype(dtype)))

    def const_matrix(self, name, array2d, dtype):
        """A constant matrix: one constant vector per row, named name[r]."""
        a = np.asarray(array2d)
        if a.ndim != 2:  # not-a-parameter: a matrix is two-dimensional
            raise GraphError(f"{name}: matrix constant must be 2-D")
        rows = [self.const(f"{name}[{r}]", a[r], dtype) for r in range(a.shape[0])]
        return self.matrix(name, rows)

    def matrix(self, name, rows):
        """A matrix whose rows are existing vectors (constants, inputs or computed)."""
        rows = tuple(rows)
        if not 1 <= len(rows) <= self.lanes:
            raise GraphError(f"{name}: a matrix needs 1..{self.lanes} rows")
        first = self.t(rows[0])
        if first.dtype not in ("int8", "fp16"):
            raise GraphError(f"{name}: matrix rows must be int8 or fp16, not {first.dtype}")
        for r in rows:
            if self.t(r).dtype != first.dtype or self.t(r).n != first.n:
                raise GraphError(f"{name}: all rows must share dtype and length")
        m = Matrix(len(self.matrices), name, first.dtype, rows, first.n)
        self.matrices.append(m)
        return m.id

    # -- operations ----------------------------------------------------------
    def matvec(self, matrix, x, name=None):
        """y[r] = sum_c M[r][c] * x[c].  int8 -> int32, fp16 -> fp32.  len(y) = number of rows."""
        m = self.matrices[matrix]
        tx = self.t(x)
        if tx.dtype != m.dtype:
            raise GraphError(f"matvec: activation is {tx.dtype}, matrix {m.name} is {m.dtype}")
        if tx.n != m.n_cols:
            raise GraphError(f"matvec: activation length {tx.n} != matrix columns {m.n_cols}")
        out = "int32" if m.dtype == "int8" else "fp32"
        return self._new(name or self._auto("matvec"), out, len(m.rows), "op", op="matvec", args=(x,), matrix=matrix)

    def _binary(self, op, a, b, name):
        ta, tb = self.t(a), self.t(b)
        if ta.dtype != tb.dtype:
            raise GraphError(f"{op}: dtypes differ ({ta.dtype}, {tb.dtype})")
        if ta.dtype not in ("int32", "fp32"):
            raise GraphError(f"{op}: VXM arithmetic needs int32 or fp32, not {ta.dtype}")
        if ta.n != tb.n:
            raise GraphError(f"{op}: lengths differ ({ta.n}, {tb.n})")
        return self._new(name or self._auto(op), ta.dtype, ta.n, "op", op=op, args=(a, b))

    def add(self, a, b, name=None):
        return self._binary("add", a, b, name)

    def sub(self, a, b, name=None):
        return self._binary("sub", a, b, name)

    def mul(self, a, b, name=None):
        return self._binary("mul", a, b, name)

    def _unary(self, op, a, name):
        ta = self.t(a)
        if ta.dtype not in ("int32", "fp32"):
            raise GraphError(f"{op}: VXM arithmetic needs int32 or fp32, not {ta.dtype}")
        if op in FLOAT_ONLY and ta.dtype != "fp32":
            raise GraphError(f"{op}: defined for fp32 only")
        return self._new(name or self._auto(op), ta.dtype, ta.n, "op", op=op, args=(a,))

    def neg(self, a, name=None):
        return self._unary("neg", a, name)

    def relu(self, a, name=None):
        return self._unary("relu", a, name)

    def tanh(self, a, name=None):
        return self._unary("tanh", a, name)

    def exp(self, a, name=None):
        return self._unary("exp", a, name)

    def rsqrt(self, a, name=None):
        return self._unary("rsqrt", a, name)

    def cast(self, a, dtype, name=None):
        ta = self.t(a)
        if (ta.dtype, dtype) not in CASTS:
            raise GraphError(f"cast: {ta.dtype} -> {dtype} is not supported")
        return self._new(name or self._auto("cast"), dtype, ta.n, "op", op="cast", args=(a,))

    def requant(self, a, shift, name=None):
        """int32 -> int8: arithmetic shift right by `shift`, then saturate."""
        ta = self.t(a)
        if ta.dtype != "int32":
            raise GraphError("requant: operand must be int32")
        if not 0 <= shift <= 31:  # not-a-parameter: shift range of a 32-bit integer
            raise GraphError("requant: shift must be in 0..31")
        return self._new(name or self._auto("requant"), "int8", ta.n, "op", op="requant", args=(a,), attr=shift)

    def broadcast(self, a, lane, n, name=None):
        """result[i] = a[lane] for i < n."""
        ta = self.t(a)
        if not 0 <= lane < ta.n:
            raise GraphError(f"broadcast: lane {lane} is outside the operand's length {ta.n}")
        return self._new(name or self._auto("broadcast"), ta.dtype, n, "op", op="broadcast", args=(a,), attr=lane)

    def output(self, name, tid):
        """Mark a computed tensor as a program output."""
        if self.t(tid).kind != "op":
            raise GraphError("only computed tensors can be outputs")
        if name in self.outputs:
            raise GraphError(f"duplicate output {name!r}")
        self.outputs[name] = tid

    # -- queries -------------------------------------------------------------
    def ops(self):
        """Computed tensors in creation order (a topological order)."""
        return [t for t in self.tensors if t.kind == "op"]
