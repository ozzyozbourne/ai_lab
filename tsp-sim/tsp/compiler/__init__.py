"""Toy static compiler: Graph -> Program with exact cycle timing (plan.md section 5).

Pipeline (each pass a pure function of its inputs; none reads tensor values):
  tiling.tile_graph      5.1  tile-level DAG
  assign.assign_units    5.3  MXM plane / SXM unit per operation
  chains.form_chains     5.4  rigid chains, predecessors
  timetable.chain_timing 5.5  ideal offsets relative to each chain's anchor
  placement.place_leaves 5.2  leaf planes -> (slice, bank, addr); runs after 5.4/5.5
                              because it avoids same-cycle reads within a chain
  timetable.heights / ideal_anchors   5.5  priorities and ASAP anchors
  resolve.run_schedule   5.6  reservation tables and the scheduling loop
  emit.emit_queues       5.7  queues with Nops; layouts
"""
from __future__ import annotations

from ..config import ChipConfig
from ..graph import Graph
from ..program import Program
from .assign import assign_units
from .chains import form_chains, successors, topo_order
from .emit import emit_queues, input_layouts, output_layouts
from .errors import CompileError
from .placement import leaf_positions, place_leaves
from .resolve import Scheduler, run_schedule
from .tiling import tile_graph
from .timetable import chain_timing, heights, ideal_anchors

__all__ = ["compile", "CompileError"]


def compile(graph: Graph, config: ChipConfig) -> Program:   # noqa: A001 (name fixed by plan 3)
    tg = tile_graph(graph, config)
    units = assign_units(tg, config)
    chains, _ = form_chains(tg)
    times = [chain_timing(tg, c, units, config) for c in chains]
    mem, marks = place_leaves(tg, chains, times, units, config)
    order = topo_order(chains)
    h = heights(tg, chains, times, successors(chains), order, config)
    ideal = ideal_anchors(tg, chains, times, order, leaf_positions(tg, mem, config), config)
    sched = Scheduler(tg, chains, times, mem, marks, config)
    report = run_schedule(sched, h, ideal)
    return Program(
        name=graph.name,
        config_name=config.name,
        config_fingerprint=config.fingerprint(),
        tile_len=tg.tile_len,
        queues=emit_queues(sched.placed, config),
        constants={k: v.copy() for k, v in graph.constants.items()},
        inputs=input_layouts(graph, tg, mem),
        outputs=output_layouts(graph, tg, mem),
        report=report,
    )
