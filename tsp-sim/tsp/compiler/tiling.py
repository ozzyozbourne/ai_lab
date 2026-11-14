"""Pass 1 (plan 5.1): tiling.

Turns the whole-tensor graph into a tile-level DAG.

Output data structure (`Tiled`):
- `vals`: every tile-level value (`TVal`): leaf vector tiles, matrix columns
  (one per weight-tile install row) and the results of tile operations. Each has
  a unique tag prefix (plan 3.4): leaf tile `f"{name}.t{i}"`, matrix column
  `f"{name}.o{out_tile}.c{column}"`, computed tile `f"{node}.t{i}"`, matvec
  partial product `f"{node}.t{i}.p{j}"`, partial sum `f"{node}.t{i}.s{j}"`.
- `ops`: tile operations (`TOp`) in deterministic order (graph node id, then
  tile index; within one matvec output tile its MATVECs come before its ADDs).
  A `matvec_cols` becomes an ordinary MATVEC whose install rows are column tiles.

Policy choices where the plan is open:
- Dead code: only nodes that some graph output depends on are tiled into
  operations. Every leaf still gets tile values (it needs a memory layout,
  because `Program.inputs` lists every leaf).
"""
from __future__ import annotations

from dataclasses import dataclass, field

from ..config import ChipConfig
from ..graph import ELEMENTWISE_BINARY, LEAF, Graph
from ..isa import DType
from .errors import CompileError

MATVEC = "matvec"


@dataclass(frozen=True)
class TVal:
    vid: int
    prefix: str                 # tag prefix; plane j is f"{prefix}#{j}"
    dtype: DType
    node: int | None            # graph node id (None for matrix columns)
    tile: int                   # tile index within the node (matrix columns: out tile)
    leaf: str | None = None     # leaf vector or matrix name for stored leaves
    index: tuple[int, ...] = ()  # layout index: (i,) or (out_tile, in_tile, r)
    producer: int | None = None  # op id for computed values


@dataclass(frozen=True)
class TOp:
    oid: int
    kind: str                   # "matvec" or a graph elementwise kind (add, relu, cast, shift, ...)
    node: int                   # graph node id
    tile: int                   # output tile index
    in_dtype: DType             # operand dtype
    dtype: DType                # result dtype
    operands: tuple[int, ...]   # vids; matvec: (activation,)
    out: int                    # vid of the result
    rows: tuple[int, ...] = ()  # matvec: vids of install rows 0..k-1
    imm: int = 0                # requant shift / shift distance


@dataclass
class Tiled:
    tile_len: int
    vals: list[TVal] = field(default_factory=list)
    ops: list[TOp] = field(default_factory=list)
    node_tiles: dict[int, list[int]] = field(default_factory=dict)    # graph node id -> vids of its tiles
    leaf_vectors: list[str] = field(default_factory=list)             # leaf vector names, node order
    matrix_cols: dict[str, list[int]] = field(default_factory=dict)   # matrix name -> column vids
    outputs: dict[str, int] = field(default_factory=dict)             # output name -> graph node id
    consumers: dict[int, list[int]] = field(default_factory=dict)     # vid -> op ids reading it as operand
    row_users: dict[int, list[int]] = field(default_factory=dict)     # vid -> MATVEC op ids installing it
    is_output: dict[int, bool] = field(default_factory=dict)          # vid -> True for graph output tiles
    node_names: list[str] = field(default_factory=list)               # graph node id -> name


def tile_count(n: int, tile_len: int) -> int:
    return -(-n // tile_len)


def tile_length(graph: Graph, config: ChipConfig) -> int:
    """plan 3.4: lanes, or lanes // 2 when the graph holds any F16 value."""
    has_f16 = any(n.dtype == DType.F16 for n in graph.nodes) or any(
        m.dtype == DType.F16 for m in graph.matrices.values())
    return config.lanes // 2 if has_f16 else config.lanes


def check_restrictions(graph: Graph, tile_len: int) -> None:
    """Graph restrictions of plan 3.3 -> CompileError."""
    mv_dtypes = []
    for n in graph.nodes:
        if n.kind == "matvec":
            mv_dtypes.append(graph.matrices[n.matrix].dtype)
        elif n.kind == "matvec_cols":
            mv_dtypes.append(graph.nodes[n.inputs[0]].dtype)
            if len(n.inputs) - 1 > tile_len:
                raise CompileError(f"{n.name}: matvec_cols with {len(n.inputs) - 1} columns, "
                                   f"more than one input tile ({tile_len})")
        elif n.kind == "shift":
            if graph.nodes[n.inputs[0]].n > tile_len:
                raise CompileError(f"{n.name}: shift operand has {graph.nodes[n.inputs[0]].n} elements, "
                                   f"more than one tile ({tile_len})")
    if DType.I8 in mv_dtypes and DType.F16 in mv_dtypes:
        raise CompileError("graph mixes I8 and F16 matvecs (L-X9: fp16 uses both planes of a hemisphere)")


def live_nodes(graph: Graph) -> list[bool]:
    """live[i] is True when some graph output depends on node i."""
    live = [False] * len(graph.nodes)
    stack = list(graph.outputs.values())
    while stack:
        i = stack.pop()
        if not live[i]:
            live[i] = True
            stack.extend(graph.nodes[i].inputs)
    return live


def tile_graph(graph: Graph, config: ChipConfig) -> Tiled:
    T = tile_length(graph, config)
    check_restrictions(graph, T)
    tg = Tiled(tile_len=T, outputs=dict(graph.outputs), node_names=[n.name for n in graph.nodes])

    def new_val(prefix, dtype, node, tile, leaf=None, index=(), producer=None) -> int:
        vid = len(tg.vals)
        tg.vals.append(TVal(vid, prefix, dtype, node, tile, leaf, index, producer))
        return vid

    def new_op(kind, node, tile, in_dtype, dtype, operands, prefix, rows=(), imm=0) -> int:
        oid = len(tg.ops)
        out = new_val(prefix, dtype, node.id, tile, producer=oid)
        tg.ops.append(TOp(oid, kind, node.id, tile, in_dtype, dtype, tuple(operands), out, tuple(rows), imm))
        return out

    # Matrix columns: every matrix, in creation order (each needs an input layout).
    for mat in graph.matrices.values():
        cols = []
        for o in range(tile_count(mat.m, T)):
            for j in range(tile_count(mat.n, T)):
                for r in range(min(T, mat.n - j * T)):
                    col = j * T + r
                    cols.append(new_val(f"{mat.name}.o{o}.c{col}", mat.dtype, None, o,
                                        leaf=mat.name, index=(o, j, r)))
        tg.matrix_cols[mat.name] = cols

    live = live_nodes(graph)
    for node in graph.nodes:
        nt = tile_count(node.n, T)
        if node.kind == LEAF:
            tg.leaf_vectors.append(node.name)
            tg.node_tiles[node.id] = [new_val(f"{node.name}.t{i}", node.dtype, node.id, i,
                                              leaf=node.name, index=(i,)) for i in range(nt)]
            continue
        if not live[node.id]:
            continue
        ins = [tg.node_tiles[i] for i in node.inputs]
        tiles = []
        if node.kind == "matvec":
            mat = graph.matrices[node.matrix]
            cols = tg.matrix_cols[mat.name]
            n_in = tile_count(mat.n, T)
            x = ins[0]
            pos = 0
            for o in range(nt):
                parts = []
                for j in range(n_in):
                    k = min(T, mat.n - j * T)
                    rows = cols[pos:pos + k]
                    pos += k
                    prefix = f"{node.name}.t{o}" if n_in == 1 else f"{node.name}.t{o}.p{j}"
                    parts.append(new_op(MATVEC, node, o, mat.dtype, node.dtype, (x[j],), prefix, rows=rows))
                acc = parts[0]
                for j in range(1, n_in):
                    prefix = f"{node.name}.t{o}" if j == n_in - 1 else f"{node.name}.t{o}.s{j}"
                    acc = new_op("add", node, o, node.dtype, node.dtype, (acc, parts[j]), prefix)
                tiles.append(acc)
        elif node.kind == "matvec_cols":
            x, cols = ins[0], ins[1:]
            xd = graph.nodes[node.inputs[0]].dtype
            for o in range(nt):
                rows = [c[o] for c in cols]
                tiles.append(new_op(MATVEC, node, o, xd, node.dtype, (x[0],), f"{node.name}.t{o}", rows=rows))
        else:
            in_dtype = graph.nodes[node.inputs[0]].dtype
            for i in range(nt):
                operands = [t[i] for t in ins]
                if node.kind not in ELEMENTWISE_BINARY:
                    operands = operands[:1]
                tiles.append(new_op(node.kind, node, i, in_dtype, node.dtype, operands,
                                    f"{node.name}.t{i}", imm=node.imm))
        tg.node_tiles[node.id] = tiles

    # Consumer and row-use indexes (op order, no duplicates: r*r counts once).
    for op in tg.ops:
        for v in dict.fromkeys(op.operands):
            tg.consumers.setdefault(v, []).append(op.oid)
        for v in dict.fromkeys(op.rows):
            tg.row_users.setdefault(v, []).append(op.oid)
    for nid in graph.outputs.values():
        for v in tg.node_tiles[nid]:
            tg.is_output[v] = True

    seen: dict[str, int] = {}
    for v in tg.vals:
        if v.prefix in seen:
            raise CompileError(f"tag prefix {v.prefix!r} is not unique (node names collide with tile names)")
        seen[v.prefix] = v.vid
    return tg
