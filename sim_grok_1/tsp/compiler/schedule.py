"""Stage 5 (plan 4.5): place the rigid tiles in absolute time.

This is list scheduling over one reservation table (ledger C1; dossier 4.2,
4.6).  Tiles are placed one at a time:

* **Order.**  Among the eligible operation tiles (every tile they depend on is
  already scheduled), take the one with the largest priority, then the lowest
  tile index.  The priority is the longest path, counted in edges, from the
  tile to a sink of the tile dependency graph.  A matvec tile's install-slot
  tiles are scheduled immediately before it, in slot order.
* **Lower bound** on the start time S of a tile, from tiles already placed:
  every read of a computed tensor comes at least latency['write'] cycles after
  the Write of that plane; every Iw comes after its plane's busy_until (the
  last Abc there); an Abc comes at least latency['iw'] cycles after the last
  Iw of its matrix; and no instruction is before program time 0.
* **Search.**  For S = lower bound, lower bound + 1, ... claim the tile's
  resources in its fixed claim order (operations in chain order; for each, its
  operand reads, then the operation, then its result):
    1. re-colour: a value takes the lowest base stream, aligned to its width,
       whose cells are free along the whole path of every plane;
    2. re-bind: a VXM operation takes the lowest-numbered ALU free that cycle;
    3. delay: if anything fails, release the tile's claims and try S + 1.
  Past config.max_schedule_cycles (ledger C4) this is a CompileError.

Every candidate list is built in ascending order and no set is iterated, so
the result is deterministic (ledger C3).
"""

from dataclasses import dataclass, field

from ..errors import CompileError
from .reserve import ReservationTable, path_cells


@dataclass
class PlacedTile:
    tile: int
    start: int                                  # S, in program time
    units: dict = field(default_factory=dict)   # instr key -> unit name actually used
    bases: dict = field(default_factory=dict)   # value id -> base stream


def priorities(tiling):
    """tile index -> longest path (in edges) to a sink of the dependency graph."""
    succ = {t.index: [] for t in tiling.tiles}
    for t in tiling.tiles:
        for d in t.deps:
            succ[d].append(t.index)
    height = {}

    def h(i):
        if i not in height:
            height[i] = 0 if not succ[i] else 1 + max(h(s) for s in succ[i])
        return height[i]

    for t in tiling.tiles:
        h(t.index)
    return height


def tile_order(graph, tiling):
    """Indices of all tiles in the order they are scheduled."""
    prio = priorities(tiling)
    done = {t.index: False for t in tiling.tiles}
    order = []
    op_tiles = [t for t in tiling.tiles if t.kind == "op"]

    def slots_of(tile):
        first = graph.t(tile.steps[0].tid)
        return tiling.slots.get(first.id, ()) if first.op == "matvec" else ()

    def ready(tile):
        own = slots_of(tile)
        for d in tile.deps:
            if d in own:
                if not all(done[x] for x in tiling.tiles[d].deps):
                    return False
            elif not done[d]:
                return False
        return True

    while len(order) < len(tiling.tiles):
        eligible = [t for t in op_tiles if not done[t.index] and ready(t)]
        if not eligible:
            raise CompileError("internal: no eligible tile (cyclic tile dependencies?)")
        best = max(eligible, key=lambda t: (prio[t.index], -t.index))
        for s in slots_of(best):
            order.append(s)
            done[s] = True
        order.append(best.index)
        done[best.index] = True
    return order


class Scheduler:
    def __init__(self, graph, planned, config):
        self.graph = graph
        self.planned = planned
        self.config = config
        self.table = ReservationTable()
        self.write_tau = {}     # (tensor id, plane) -> program time of its Write
        self.iw_tau = {}        # matvec tensor id -> program time of its last Iw
        self.alus = [u for u in config.units() if config.kind(u) == "VXM"]

    # -- lower bound ------------------------------------------------------
    def lower_bound(self, plan):
        lb = -min(ins.t for ins in plan.instrs)
        for ins in plan.instrs:
            if ins.kind == "read" and self.graph.t(ins.tid).kind == "op":
                w = self.write_tau.get((ins.tid, ins.plane))
                if w is None:
                    raise CompileError(f"internal: {self.graph.t(ins.tid).name} read before it is scheduled")
                lb = max(lb, w + self.config.latency["write"] - ins.t)
            elif ins.kind == "iw":
                busy = self.table.plane_busy_until(ins.unit)
                if busy is not None:
                    lb = max(lb, busy + 1 - ins.t)
            elif ins.kind == "abc":
                last = self.iw_tau.get(ins.tid)
                if last is None:
                    raise CompileError(f"internal: {self.graph.t(ins.tid).name} has no installed weights")
                lb = max(lb, last + self.config.latency["iw"] - ins.t)
        return lb

    # -- claiming ---------------------------------------------------------
    def try_place(self, plan, S):
        """Claim everything for the tile at start S.  Returns a PlacedTile, or None."""
        table = self.table
        placed = PlacedTile(plan.tile, S)
        table.begin()
        for what, key in plan.claims:
            if what == "d":
                ins = plan.instrs[key]
                c = S + ins.t
                owner = f"tile {plan.tile} instr {key}"
                if ins.unit == "VXM":
                    unit = next((a for a in self.alus if table.unit_free(a, c)), None)
                    if unit is None:
                        table.rollback()
                        return None
                else:
                    unit = ins.unit
                    if not table.unit_free(unit, c):
                        table.rollback()
                        return None
                table.claim_unit(unit, c, owner)
                placed.units[key] = unit
            else:
                v = plan.values[key]
                paths = []
                for p in v.planes:
                    x_last = max((r[1] for r in p.readers), key=lambda x: abs(x - p.x_from))
                    paths.append(path_cells(v.dir, p.x_from, S + p.t_emit, x_last))
                base = None
                for b in range(0, self.config.streams_per_dir - v.width + 1, v.width):
                    if all(table.cells_free(v.dir, b + j, cells) for j, cells in enumerate(paths)):
                        base = b
                        break
                if base is None:
                    table.rollback()
                    return None
                for j, cells in enumerate(paths):
                    table.claim_cells(v.dir, base + j, cells, v.name)
                placed.bases[key] = base
        table.commit()
        return placed

    def place(self, plan):
        S = self.lower_bound(plan)
        while True:
            if S > self.config.max_schedule_cycles:
                raise CompileError(f"tile {plan.tile} does not fit before cycle "
                                   f"{self.config.max_schedule_cycles} (ledger C4)")
            placed = self.try_place(plan, S)
            if placed is not None:
                break
            S += 1
        for ins in plan.instrs:
            tau = S + ins.t
            if ins.kind == "write":
                self.write_tau[(ins.tid, ins.plane)] = tau
            elif ins.kind == "iw":
                self.iw_tau[ins.tid] = max(tau, self.iw_tau.get(ins.tid, tau))
            elif ins.kind == "abc":
                self.table.set_busy_until(ins.unit, tau)
        return placed


def schedule(graph, planned, config):
    """Place every tile.  Returns the PlacedTiles in scheduling order."""
    sched = Scheduler(graph, planned, config)
    out = []
    for index in tile_order(graph, planned.tiling):
        out.append(sched.place(planned.plans[index]))
    return out
