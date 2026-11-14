"""Stage 4 (plan 4.4): the relative timetable of each tile.

Inside a tile every instruction's time is fixed relative to the first
operation (time 0), using only the arrival rule of plan 2.3 (ledger T2, T3):

    a result dispatched at t on a unit at x_p with latency d is readable at
    x_c, in its direction of flow, at exactly t + d + |x_c - x_p|.

From it:

* next operation of the chain: t_next = t_prev + d_prev + |x_next - x_prev|
* read of a plane on a slice at x_s for a consumer at x_c firing at t_c:
  t_read = t_c - d_read - |x_c - x_s|, flowing toward x_c
* write of plane j on the slice at x_j of a result emitted at x_l by an
  operation dispatched at t_l: t_write = t_l + d_l + |x_j - x_l|
* the Iw of an install slot fires at 0; its reads are timed as above.

All latencies come from config.latency.

The plan for a tile lists its instructions (`PInstr`), the values they put on
streams (`PValue`, one per operand or result, with one `PPlane` per byte
plane), and the fixed order in which the scheduler claims resources.

**Self-check and restart.**  Inside a tile no MEM slice may be used twice on
the same relative cycle.  If two operations' reads clash, the fusion pair
(A, B), B being the later operation and A its spine predecessor, is added to
`no_fuse` and the whole pipeline restarts from tiling, placement included.
This compiler adds one more reason for the same restart: a stored tensor read
from MEM by two operations of one tile (the two reads would carry the same
tag `tensor@tile`, and tags must be unique per emission).

(By the triangle inequality, a timing clash between reads of two different
operations of one chain cannot actually happen: the later consumer fires at
least |x2 - x1| + 1 cycles after the earlier one, while equal read times on one
slice would need a gap of at most |x2 - x1|.  The check is kept as a guard.)
"""

from dataclasses import dataclass, field

from .. import isa
from ..errors import CompileError
from . import binding as binding_mod
from . import placement as placement_mod
from . import tiling as tiling_mod


@dataclass
class PInstr:
    key: int                # index in TilePlan.instrs
    kind: str               # latency key: read, write, iw, abc, distribute, or a VXM op
    t: int                  # dispatch time relative to the tile start
    unit: str               # unit name, or "VXM" (any ALU)
    x: int                  # position
    operands: tuple = ()    # value ids read, in operand order (Vxm: a, b; Iw: one per entry)
    result: int = -1        # value id produced, or -1
    plane: int = -1         # Read / Write: plane index
    addr: int = -1          # Read / Write: MEM address
    tid: int = -1           # graph tensor: result of an op, tensor of a Read/Write, matvec of an Iw
    rows: tuple = ()        # Iw: row indices
    step: int = -1          # op tile: chain position of the operation this instruction serves


@dataclass
class PPlane:
    producer: int           # instr key of the instruction that emits this plane
    x_from: int
    t_emit: int             # relative time the plane appears at x_from
    readers: list = field(default_factory=list)     # (instr key, x, t)


@dataclass
class PValue:
    vid: int
    name: str               # tag without plane suffix: "tensor@tile"
    tid: int
    width: int
    dir: str
    planes: list = field(default_factory=list)      # PPlane per plane


@dataclass
class TilePlan:
    tile: int
    instrs: list = field(default_factory=list)
    values: list = field(default_factory=list)
    claims: list = field(default_factory=list)      # ("d", instr key) or ("v", value id), in claim order


class _Builder:
    def __init__(self, tile_index):
        self.plan = TilePlan(tile_index)

    def instr(self, **kw):
        ins = PInstr(key=len(self.plan.instrs), **kw)
        self.plan.instrs.append(ins)
        self.plan.claims.append(("d", ins.key))
        return ins

    def value(self, name, tid, width, dir):
        v = PValue(len(self.plan.values), name, tid, width, dir)
        self.plan.values.append(v)
        return v

    def claim_value(self, v):
        self.plan.claims.append(("v", v.vid))


def _read_operand(b, graph, placement, config, tensor, tile_index, x_c, t_c, step, consumer_dir=None):
    """Add the reads of every plane of a stored tensor for a consumer at (x_c, t_c).

    Returns the PValue; the consumer is added as a reader later.
    """
    t = graph.t(tensor)
    lat = config.latency["read"]
    locs = placement[tensor]
    dirs = [binding_mod.toward(config.pos(u), x_c) for u, _ in locs]
    d = consumer_dir or dirs[0]
    if any(dd != d for dd in dirs):
        raise CompileError(f"{t.name}: cannot reach the consumer at position {x_c} flowing {d}")
    v = b.value(f"{t.name}@{tile_index}", tensor, isa.width(t.dtype), d)
    for j, (unit, addr) in enumerate(locs):
        x_s = config.pos(unit)
        tr = t_c - lat - abs(x_c - x_s)
        ins = b.instr(kind="read", t=tr, unit=unit, x=x_s, result=v.vid, plane=j, addr=addr,
                      tid=tensor, step=step)
        v.planes.append(PPlane(ins.key, x_s, tr + lat))
    b.claim_value(v)
    return v


def _plan_install(graph, tile, placement, planes_of, config):
    b = _Builder(tile.index)
    mv = graph.t(tile.matvec)
    m = graph.matrices[mv.matrix]
    unit = planes_of[mv.id]
    x = config.pos(unit)
    vals = []
    for r in tile.rows:
        v = _read_operand(b, graph, placement, config, m.rows[r], tile.index, x, 0, -1,
                          consumer_dir=binding_mod.operand_dir(unit))
        vals.append(v)
    ins = b.instr(kind="iw", t=0, unit=unit, x=x, operands=tuple(v.vid for v in vals),
                  tid=mv.id, rows=tile.rows)
    for v in vals:
        for p in v.planes:
            p.readers.append((ins.key, x, 0))
    return b.plan


def _plan_op(graph, tile, placement, steps_bind, config):
    b = _Builder(tile.index)
    prev = None             # (PValue of previous result, PInstr of previous op)
    t = 0
    x_prev = None
    d_prev = None
    for k, step in enumerate(tile.steps):
        sb = steps_bind[(tile.index, k)]
        tensor = graph.t(step.tid)
        if k > 0:
            t = t + d_prev + abs(sb.x - x_prev)
        consumer_dir = binding_mod.operand_dir(sb.unit) if tensor.op == "matvec" else None
        read_vals = {}
        for u in step.mem_operands:
            read_vals[u] = _read_operand(b, graph, placement, config, u, tile.index, sb.x, t, k,
                                         consumer_dir=consumer_dir)
        operands = []
        for slot, a in enumerate(tensor.args):
            if slot == step.spine_slot:
                operands.append(prev[0].vid)
            else:
                operands.append(read_vals[a].vid)
        res = b.value(f"{tensor.name}@{tile.index}", tensor.id, isa.width(tensor.dtype), sb.result_dir)
        ins = b.instr(kind=sb.kind, t=t, unit=sb.unit, x=sb.x, operands=tuple(operands),
                      result=res.vid, tid=tensor.id, step=k)
        # This operation reads its operands: record it as a reader of each (once per value).
        seen = []
        for vid in operands:
            if vid in seen:
                continue
            seen.append(vid)
            for p in b.plan.values[vid].planes:
                p.readers.append((ins.key, sb.x, t))
        d = config.latency[sb.kind]
        for _ in range(res.width):
            res.planes.append(PPlane(ins.key, sb.x, t + d))
        b.claim_value(res)
        prev = (res, ins)
        x_prev, d_prev = sb.x, d

    # Writes of the final result, one per plane.
    res, op = prev
    for j, (unit, addr) in enumerate(placement[res.tid]):
        x_j = config.pos(unit)
        tw = op.t + d_prev + abs(x_j - op.x)
        ins = b.instr(kind="write", t=tw, unit=unit, x=x_j, operands=(res.vid,), plane=j,
                      addr=addr, tid=res.tid, step=len(tile.steps) - 1)
        res.planes[j].readers.append((ins.key, x_j, tw))
    return b.plan


def plan_tiles(graph, tiling, placement, steps_bind, planes_of, config):
    """TilePlan for every tile, in tile-index order."""
    plans = []
    for tile in tiling.tiles:
        if tile.kind == "install":
            plans.append(_plan_install(graph, tile, placement, planes_of, config))
        else:
            plans.append(_plan_op(graph, tile, placement, steps_bind, config))
    return plans


def check_arrivals(plan):
    """Every reader time equals emission time plus distance, on the correct side."""
    for v in plan.values:
        for p in v.planes:
            for _, x, t in p.readers:
                ahead = x - p.x_from if v.dir == "E" else p.x_from - x
                if ahead < 0 or t != p.t_emit + ahead:
                    raise CompileError(f"internal: {v.name} reader at x={x}, t={t} misses the arrival rule")


def self_check(graph, tile, plan):
    """Return None if the tile is valid, or a (producer tid, consumer tid) pair to stop fusing."""
    if tile.kind != "op":
        return None
    # A stored tensor read by two operations of the tile.
    first_reader = {}
    for ins in plan.instrs:
        if ins.kind == "read":
            k = first_reader.setdefault(ins.tid, ins.step)
            if k != ins.step:
                later = max(k, ins.step)
                return (tile.steps[later - 1].tid, tile.steps[later].tid)
    # A MEM slice used twice on one relative cycle.
    used = {}
    for ins in plan.instrs:
        if ins.kind not in ("read", "write"):
            continue
        other = used.get((ins.unit, ins.t))
        if other is None:
            used[(ins.unit, ins.t)] = ins
            continue
        if other.kind == "write" or ins.kind == "write" or other.step == ins.step:
            raise CompileError(
                f"tile {tile.index}: {ins.unit} is needed twice at relative cycle {ins.t} by "
                f"{graph.t(other.tid).name} and {graph.t(ins.tid).name}, which fusion cannot fix "
                "(two rows of matrices placed on one slice and read by one operation?)")
        later = max(other.step, ins.step)
        return (tile.steps[later - 1].tid, tile.steps[later].tid)
    return None


@dataclass
class Planned:
    """Everything the stages before scheduling produce."""

    chains: list
    tiling: object
    placement: dict
    steps_bind: dict
    planes_of: dict
    plans: list
    no_fuse: list


def plan_graph(graph, config):
    """Run tiling, placement, binding and timetabling, restarting on a failed self-check."""
    no_fuse = []
    while True:
        chains = tiling_mod.fuse(graph, no_fuse)
        stored = tiling_mod.stored_tensors(graph, chains)
        placement = placement_mod.place(graph, chains, stored, config)
        tiling = tiling_mod.build_tiles(graph, chains, placement, config)
        steps_bind, planes_of = binding_mod.bind(graph, tiling, placement, config)
        plans = plan_tiles(graph, tiling, placement, steps_bind, planes_of, config)
        restart = None
        for tile, plan in zip(tiling.tiles, plans):
            check_arrivals(plan)
            restart = self_check(graph, tile, plan)
            if restart is not None:
                break
        if restart is None:
            return Planned(chains, tiling, placement, steps_bind, planes_of, plans, list(no_fuse))
        if restart in no_fuse:
            raise CompileError(f"internal: no_fuse pair {restart} repeated")
        no_fuse.append(restart)
