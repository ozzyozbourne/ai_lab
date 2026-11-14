"""Compute-graph IR: the compiler's input.

A Graph records structure only. It checks dtypes and shapes when nodes are
added and never evaluates anything. Semantics of each node kind: plan.md 3.3.
Nodes keep creation order; node ids are the tie-break everywhere downstream.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from .isa import CASTS, DType

LEAF = "vector"
ELEMENTWISE_BINARY = ("add", "sub", "mul")
ELEMENTWISE_UNARY = ("relu", "exp", "rsqrt", "tanh", "requant", "cast", "shift")
KINDS = (LEAF, "matvec", "matvec_cols") + ELEMENTWISE_BINARY + ELEMENTWISE_UNARY


class GraphError(ValueError):
    pass


@dataclass(frozen=True)
class Matrix:
    """A dense m x n matrix leaf. Constant if the graph holds data for it, else a runtime input."""
    name: str
    dtype: DType
    m: int
    n: int


@dataclass(frozen=True)
class Node:
    id: int
    kind: str                       # one of KINDS
    name: str                       # unique; used as the tag prefix of the value
    dtype: DType                    # dtype of the value this node produces
    n: int                          # number of elements
    inputs: tuple[int, ...] = ()    # node ids. matvec: (x,). matvec_cols: (x, col_0, .., col_{k-1})
    matrix: str | None = None       # matvec: name of the Matrix
    imm: int = 0                    # requant: shift amount. shift: lane offset n


class Value:
    """Handle returned by the builder methods."""
    def __init__(self, graph: "Graph", node_id: int):
        self.graph, self.id = graph, node_id

    @property
    def node(self) -> Node:
        return self.graph.nodes[self.id]

    def __repr__(self):
        n = self.node
        return f"<Value {n.name} {n.dtype.value}[{n.n}]>"


class Graph:
    def __init__(self, name: str):
        self.name = name
        self.nodes: list[Node] = []
        self.matrices: dict[str, Matrix] = {}
        self.constants: dict[str, np.ndarray] = {}   # leaf vector name or matrix name -> data
        self.outputs: dict[str, int] = {}            # output name -> node id
        self._names: set[str] = set()                # membership tests only; never iterated

    # ---- leaves ---------------------------------------------------------------
    def vector(self, name: str, dtype: DType, n: int, data=None) -> Value:
        if data is not None:
            arr = np.asarray(data)
            if arr.shape != (n,):
                raise GraphError(f"{name}: data shape {arr.shape} != ({n},)")
            self._check_cast(name, arr, dtype)
            self.constants[name] = arr.astype(dtype.np)
        return self._add(LEAF, dtype, n, name=name)

    def matrix(self, name: str, dtype: DType, m: int, n: int, data=None) -> Matrix:
        if dtype not in (DType.I8, DType.F16):
            raise GraphError(f"{name}: matrices must be I8 or F16")
        self._claim(name)
        if data is not None:
            arr = np.asarray(data)
            if arr.shape != (m, n):
                raise GraphError(f"{name}: data shape {arr.shape} != ({m}, {n})")
            self._check_cast(name, arr, dtype)
            self.constants[name] = arr.astype(dtype.np)
        mat = Matrix(name, dtype, m, n)
        self.matrices[name] = mat
        return mat

    # ---- matrix-vector products -------------------------------------------------
    def matvec(self, W: Matrix, x: Value, name: str | None = None) -> Value:
        """W @ x. (I8, I8) -> I32, (F16, F16) -> F32."""
        xn = x.node
        if xn.dtype != W.dtype:
            raise GraphError(f"matvec: operand is {xn.dtype.value}, matrix {W.name} is {W.dtype.value}")
        if xn.n != W.n:
            raise GraphError(f"matvec: operand has {xn.n} elements, matrix {W.name} has {W.n} columns")
        return self._add("matvec", _mv_out(W.dtype), W.m, inputs=(x.id,), matrix=W.name, name=name)

    def matvec_cols(self, cols: list[Value], x: Value, name: str | None = None) -> Value:
        """sum_{r < len(cols)} x[r] * cols[r]; elements of x beyond len(cols) are ignored.

        Every column is a vector Value (leaf or computed) of one length.
        """
        xn = x.node
        if not cols or len(cols) > xn.n:
            raise GraphError(f"matvec_cols: {len(cols)} columns for an operand of {xn.n} elements")
        m = cols[0].node.n
        for c in cols:
            if c.node.dtype != xn.dtype or c.node.n != m:
                raise GraphError("matvec_cols: columns must match the operand dtype and each other's length")
        if xn.dtype not in (DType.I8, DType.F16):
            raise GraphError("matvec_cols: operand must be I8 or F16")
        return self._add("matvec_cols", _mv_out(xn.dtype), m,
                         inputs=(x.id,) + tuple(c.id for c in cols), name=name)

    # ---- elementwise ------------------------------------------------------------
    def add(self, a: Value, b: Value, name: str | None = None) -> Value:
        return self._binary("add", a, b, name)

    def sub(self, a: Value, b: Value, name: str | None = None) -> Value:
        return self._binary("sub", a, b, name)

    def mul(self, a: Value, b: Value, name: str | None = None) -> Value:
        return self._binary("mul", a, b, name)

    def relu(self, a: Value, name: str | None = None) -> Value:
        self._need(a, (DType.I32, DType.F32), "relu")
        return self._add("relu", a.node.dtype, a.node.n, inputs=(a.id,), name=name)

    def exp(self, a: Value, name: str | None = None) -> Value:
        return self._trans("exp", a, name)

    def rsqrt(self, a: Value, name: str | None = None) -> Value:
        return self._trans("rsqrt", a, name)

    def tanh(self, a: Value, name: str | None = None) -> Value:
        return self._trans("tanh", a, name)

    def requant(self, a: Value, shift: int, name: str | None = None) -> Value:
        self._need(a, (DType.I32,), "requant")
        if not 0 <= shift < 32:
            raise GraphError("requant: shift must be in 0..31")
        return self._add("requant", DType.I8, a.node.n, inputs=(a.id,), imm=shift, name=name)

    def cast(self, a: Value, to: DType, name: str | None = None) -> Value:
        if (a.node.dtype, to) not in CASTS:
            raise GraphError(f"cast {a.node.dtype.value} -> {to.value} is not supported")
        return self._add("cast", to, a.node.n, inputs=(a.id,), name=name)

    def shift(self, a: Value, n: int, name: str | None = None) -> Value:
        """out[i] = a[i - n] if i - n >= 0 else 0, for 0 <= i < len(a). n must be >= 0."""
        if n < 0:
            raise GraphError("shift: only n >= 0 is supported (a negative shift would read padding lanes)")
        return self._add("shift", a.node.dtype, a.node.n, inputs=(a.id,), imm=n, name=name)

    # ---- outputs ----------------------------------------------------------------
    def output(self, name: str, v: Value) -> None:
        if name in self.outputs:
            raise GraphError(f"duplicate output {name}")
        if v.node.kind == LEAF:
            raise GraphError("an output must be a computed value")
        self.outputs[name] = v.id

    # ---- queries ----------------------------------------------------------------
    def input_names(self) -> list[str]:
        """Leaves (vectors, then matrices, in creation order) that need a feed at load time."""
        vecs = [n.name for n in self.nodes if n.kind == LEAF and n.name not in self.constants]
        mats = [m for m in self.matrices if m not in self.constants]
        return vecs + mats

    def consumers(self, node_id: int) -> list[int]:
        return [n.id for n in self.nodes if node_id in n.inputs]

    # ---- internals --------------------------------------------------------------
    def _binary(self, kind, a, b, name):
        self._need(a, (DType.I32, DType.F32), kind)
        if a.node.dtype != b.node.dtype or a.node.n != b.node.n:
            raise GraphError(f"{kind}: operands differ: {a!r} vs {b!r}")
        return self._add(kind, a.node.dtype, a.node.n, inputs=(a.id, b.id), name=name)

    def _trans(self, kind, a, name):
        self._need(a, (DType.F32,), kind)
        return self._add(kind, DType.F32, a.node.n, inputs=(a.id,), name=name)

    @staticmethod
    def _need(a: Value, dtypes, what):
        if a.node.dtype not in dtypes:
            raise GraphError(f"{what}: operand dtype {a.node.dtype.value} not allowed")

    @staticmethod
    def _check_cast(name, arr, dtype: DType):
        if not dtype.is_float and not np.array_equal(arr, arr.astype(dtype.np)):
            raise GraphError(f"{name}: data does not fit {dtype.value}")

    def _claim(self, name: str):
        if "#" in name or not name:
            raise GraphError(f"bad name {name!r} ('#' is reserved for plane tags)")
        if name in self._names:
            raise GraphError(f"duplicate name {name}")
        self._names.add(name)

    def _add(self, kind, dtype, n, inputs=(), matrix=None, imm=0, name=None) -> Value:
        if n < 1:
            raise GraphError("vectors need at least one element")
        for i in inputs:
            if not 0 <= i < len(self.nodes):
                raise GraphError("operand belongs to another graph")
        nid = len(self.nodes)
        name = name if name is not None else f"n{nid}_{kind}"
        self._claim(name)
        self.nodes.append(Node(nid, kind, name, dtype, n, tuple(inputs), matrix, imm))
        return Value(self, nid)


def _mv_out(dtype: DType) -> DType:
    return DType.I32 if dtype == DType.I8 else DType.F32
