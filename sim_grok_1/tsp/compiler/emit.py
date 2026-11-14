"""Stage 6 (plan 4.6): turn the schedule into a Program.

* Every planned instruction becomes an ISA instruction with its chosen unit,
  streams and tags.  Tags are unique per emission: the value name is
  "tensor@tile", plane j of it is isa.plane_tag(name, j).  Read and Write
  carry the plane suffix; every other instruction names whole values.
* Queues: for every unit with at least one instruction (and always VXM_A0, the
  notifier, ledger B14), in config.units() order, sort its dispatches by time
  and emit `Sync` (`Notify` for VXM_A0), then each instruction preceded by a
  `Nop(gap)` for any idle cycles.  The element after Sync/Notify starts at
  cycle config.barrier_cycles, which is program time 0, so an instruction at
  program time tau > 0 at the head of a queue sits after Nop(tau).  A gap
  longer than config.nop_max is split into several Nops (ledger T14).  No
  Repeat is emitted: every instruction carries a unique tag.
* mem_image holds every constant plane, each exactly config.lanes bytes,
  zero-padded (ledger B22).  inputs / outputs map names to TensorLocs.
* schedule lists every emitted plane with its producer, stream, emission
  cycle and readers, all in simulator cycles (program time + barrier).
"""

import numpy as np

from .. import isa
from ..errors import CompileError
from ..program import Program, TensorLoc


def _nops(gap, config):
    out = []
    while gap > 0:
        n = min(gap, config.nop_max)
        out.append(isa.Nop(n))
        gap -= n
    return out


def _ref(v, base):
    return isa.StreamRef(v.dir, base)


def build_instr(graph, config, plan, placed, ins):
    """The ISA instruction for one planned instruction."""
    vals = plan.values
    bases = placed.bases
    if ins.kind == "read":
        v = vals[ins.result]
        return isa.Read(ins.addr, isa.StreamRef(v.dir, bases[v.vid] + ins.plane),
                        tag=isa.plane_tag(v.name, ins.plane))
    if ins.kind == "write":
        v = vals[ins.operands[0]]
        return isa.Write(ins.addr, isa.StreamRef(v.dir, bases[v.vid] + ins.plane),
                         expect=(isa.plane_tag(v.name, ins.plane),))
    if ins.kind == "iw":
        m = graph.matrices[graph.t(ins.tid).matrix]
        entries = tuple((r, _ref(vals[vid], bases[vid])) for r, vid in zip(ins.rows, ins.operands))
        return isa.Iw(m.dtype, entries, expect=tuple(vals[vid].name for vid in ins.operands))
    t = graph.t(ins.tid)
    res = vals[ins.result]
    out = _ref(res, bases[res.vid])
    ops = [vals[vid] for vid in ins.operands]
    srcs = [_ref(v, bases[v.vid]) for v in ops]
    expect = tuple(v.name for v in ops)
    if ins.kind == "abc":
        m = graph.matrices[t.matrix]
        return isa.Abc(m.dtype, srcs[0], out, len(m.rows), tag=res.name, expect=expect)
    if ins.kind == "distribute":
        src_t = graph.t(t.args[0])
        lane_map = (t.attr,) * config.lanes_per_superlane
        return isa.Distribute(isa.width(src_t.dtype), srcs[0], out, lane_map, t.n,
                              tag=res.name, expect=expect)
    # VXM
    a_t = graph.t(t.args[0])
    out_dtype = t.dtype if t.dtype != a_t.dtype else ""
    b = srcs[1] if len(srcs) > 1 else None
    return isa.Vxm(t.op, a_t.dtype, srcs[0], b, out, t.n, out_dtype=out_dtype,
                   imm=t.attr if t.op == "requant" else 0, tag=res.name, expect=expect)


def _loc(name, graph, tid, placement):
    t = graph.t(tid)
    return TensorLoc(name, t.dtype, t.n, tuple(placement[tid]))


def emit(graph, config, planned, placed_tiles):
    """Build the Program."""
    plans = planned.plans
    bar = config.barrier_cycles
    unit_index = {u: i for i, u in enumerate(config.units())}

    dispatches = {}         # unit -> list of (tau, instr)
    entries = []
    for placed in placed_tiles:
        plan = plans[placed.tile]
        S = placed.start
        for ins in plan.instrs:
            unit = placed.units[ins.key]
            dispatches.setdefault(unit, []).append((S + ins.t, build_instr(graph, config, plan, placed, ins)))
        for v in plan.values:
            base = placed.bases[v.vid]
            for j, p in enumerate(v.planes):
                readers = sorted(((S + t + bar, unit_index[placed.units[k]], placed.units[k], x)
                                  for k, x, t in p.readers))
                entries.append({
                    "tag": isa.plane_tag(v.name, j),
                    "tile": placed.tile,
                    "unit": placed.units[p.producer],
                    "dir": v.dir,
                    "s": base + j,
                    "x_from": p.x_from,
                    "t_emit": S + p.t_emit + bar,
                    "readers": [{"unit": u, "x": x, "t": t} for t, _, u, x in readers],
                })
    entries.sort(key=lambda e: (e["t_emit"], unit_index[e["unit"]], e["s"], e["dir"]))

    queues = {}
    notifier = "VXM_A0"     # ledger: B14
    for unit in config.units():
        items = sorted(dispatches.get(unit, []), key=lambda d: d[0])
        if not items and unit != notifier:
            continue
        q = [isa.Notify() if unit == notifier else isa.Sync()]
        prev = -1
        for tau, instr in items:
            if tau <= prev:
                raise CompileError(f"internal: {unit} has two dispatches at program time {tau}")
            q.extend(_nops(tau - prev - 1, config))
            q.append(instr)
            prev = tau
        queues[unit] = q

    mem_image = {}
    for t in graph.tensors:
        if t.kind != "const":
            continue
        padded = np.zeros(config.lanes, dtype=isa.np_dtype(t.dtype))
        padded[:t.n] = t.data
        for (unit, addr), plane in zip(planned.placement[t.id], isa.to_planes(padded, t.dtype)):
            mem_image[(unit, addr)] = bytes(plane.tobytes())

    mem_names = {}
    for t in graph.tensors:
        for j, (unit, addr) in enumerate(planned.placement.get(t.id, ())):
            mem_names[(unit, addr)] = isa.plane_tag(t.name, j)

    inputs = {}
    for t in graph.tensors:
        if t.kind == "input":
            inputs[t.name] = _loc(t.name, graph, t.id, planned.placement)
    outputs = {}
    for name in sorted(graph.outputs):
        outputs[name] = _loc(name, graph, graph.outputs[name], planned.placement)

    return Program(config=config, queues=queues, mem_image=mem_image, inputs=inputs,
                   outputs=outputs, schedule=entries, mem_names=mem_names)
