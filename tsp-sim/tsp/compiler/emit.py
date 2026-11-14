"""Pass 7 (plan 5.7): emission.

For each unit (config.unit_names() order) sort its instructions by issue cycle,
merge a MEM slice's Read and Write of one cycle into one Issue (Read first), and
fill the gaps with Nop(n) split at nop_max (L-T10). Units with no work get an
empty queue. Also builds the input and output layouts (plan 3.4).
"""
from __future__ import annotations

from ..config import ChipConfig
from ..graph import Graph
from ..isa import Entry, Issue, Nop, Read
from ..program import MATRIX_COLS, VECTOR, TensorLayout, TileLayout
from .errors import CompileError
from .placement import Memory
from .resolve import Placed
from .tiling import Tiled


def nops(n: int, nop_max: int) -> list[Nop]:
    out = []
    while n > 0:
        step = min(n, nop_max)
        out.append(Nop(step))
        n -= step
    return out


def emit_queues(placed: list[Placed], config: ChipConfig) -> dict[str, list[Entry]]:
    per_unit: dict[str, list[tuple[tuple[int, int, int], Placed]]] = {u: [] for u in config.unit_names()}
    for seq, p in enumerate(placed):
        if p.unit not in per_unit:
            raise CompileError(f"internal: unknown unit {p.unit}")
        per_unit[p.unit].append(((p.issue, 0 if isinstance(p.instr, Read) else 1, seq), p))
    queues: dict[str, list[Entry]] = {}
    for unit, items in per_unit.items():
        items.sort(key=lambda item: item[0])
        q: list[Entry] = []
        t = 0
        i = 0
        while i < len(items):
            cycle = items[i][1].issue
            group = []
            while i < len(items) and items[i][1].issue == cycle:
                group.append(items[i][1].instr)
                i += 1
            if cycle < t or len(group) > config.issue_width(unit):
                raise CompileError(f"internal: {unit} over-issued at cycle {cycle}")
            q.extend(nops(cycle - t, config.nop_max))
            q.append(Issue(tuple(group)))
            t = cycle + 1
        queues[unit] = q
    return queues


def tile_layout(index, tag, mem: Memory, vid: int) -> TileLayout:
    return TileLayout(tuple(index), tag, mem.loc[vid])


def input_layouts(graph: Graph, tg: Tiled, mem: Memory) -> dict[str, TensorLayout]:
    out: dict[str, TensorLayout] = {}
    for node in graph.nodes:
        if node.kind == "vector":
            tiles = tuple(tile_layout(tg.vals[v].index, tg.vals[v].prefix, mem, v) for v in tg.node_tiles[node.id])
            out[node.name] = TensorLayout(node.name, node.dtype, (node.n,), VECTOR, tiles)
    for mat in graph.matrices.values():
        tiles = tuple(tile_layout(tg.vals[v].index, tg.vals[v].prefix, mem, v) for v in tg.matrix_cols[mat.name])
        out[mat.name] = TensorLayout(mat.name, mat.dtype, (mat.m, mat.n), MATRIX_COLS, tiles)
    return out


def output_layouts(graph: Graph, tg: Tiled, mem: Memory) -> dict[str, TensorLayout]:
    out: dict[str, TensorLayout] = {}
    for name, nid in graph.outputs.items():
        node = graph.nodes[nid]
        tiles = tuple(TileLayout((i,), tg.vals[v].prefix, mem.loc[v]) for i, v in enumerate(tg.node_tiles[nid]))
        out[name] = TensorLayout(name, node.dtype, (node.n,), VECTOR, tiles)
    return out
