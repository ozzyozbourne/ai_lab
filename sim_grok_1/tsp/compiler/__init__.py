"""The toy scheduling compiler: Graph -> Program (plan section 4).

The pipeline, one file per stage:

1. tiling.py     cut the graph into rigid tiles (fusion, install slots)
2. placement.py  give every stored tensor a place in MEM
3. binding.py    choose units and stream directions
4. timetable.py  fix relative times inside each tile; self-check and restart
5. schedule.py   place tiles in absolute time over a reservation table (reserve.py)
6. emit.py       build per-unit instruction queues and the Program

compile_graph is pure and deterministic (ledger C3): the same graph and
configuration always give a byte-identical Program.to_json().
"""

from ..errors import CompileError
from ..graph import Graph
from ..params import ChipConfig
from ..program import Program
from .emit import emit
from .schedule import schedule
from .timetable import plan_graph


def compile_graph(graph: Graph, config: ChipConfig) -> Program:
    """Compile a fixed-shape graph to a Program for the given chip.

    A vector longer than the chip's lane count cannot be stored in one MEM
    word or carried on a stream (ledger B5), so it is a CompileError.
    """
    for t in graph.tensors:
        if t.n > config.lanes:
            raise CompileError(f"{t.name}: length {t.n} does not fit the chip's {config.lanes} lanes")
    planned = plan_graph(graph, config)
    placed = schedule(graph, planned, config)
    return emit(graph, config, planned, placed)


__all__ = ["compile_graph"]
