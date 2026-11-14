"""Stage 3 (plan 4.3): decide which unit runs each operation and where results go.

* VXM operations go to the VXM position.  Which of its ALUs runs the operation
  is decided later, during scheduling (re-binding); here the unit is "VXM".
* A matvec goes to MXM plane 0 of the hemisphere that holds most of its
  weight-row planes (tie: W), keeping weights close to the MXM.
  Its operands flow outward and its result flows inward (ledger B10): for
  MXM_W operands flow W and the result flows E; mirrored for MXM_E.
* A broadcast is a Distribute on an SXM, chosen by the first rule that
  applies: the SXM of the hemisphere of the previous operation in the tile if
  that is an MXM; the SXM of the hemisphere where its operand is stored if the
  operand is read from MEM; otherwise SXM_W.  Distribute cannot move data
  between superlanes, so with more than one tile per slice it is a
  CompileError.
* Result direction: toward the next operation of the chain (east if it is at
  the same position).  A tile's final result flows toward the slices where
  placement put it, so that every Write sits on its path.
"""

from dataclasses import dataclass

from ..errors import CompileError
from .placement import hemi_of


@dataclass(frozen=True)
class StepBinding:
    unit: str           # unit name, or "VXM" for any ALU
    x: int              # position
    kind: str           # latency key: "abc", "distribute" or the VXM op name
    result_dir: str     # "E" or "W"


def other_hemi(h):
    return "E" if h == "W" else "W"


def toward(x_from, x_to):
    """Direction of flow from x_from to x_to (east when equal)."""
    return "W" if x_to < x_from else "E"


def matvec_plane(graph, tensor, placement):
    """MXM plane-0 unit for a matvec: the hemisphere holding most weight-row planes."""
    m = graph.matrices[tensor.matrix]
    count = {"W": 0, "E": 0}
    for row in m.rows:
        for unit, _ in placement[row]:
            count[hemi_of(unit)] += 1
    hemi = "W" if count["W"] >= count["E"] else "E"
    return f"MXM_{hemi}0"


def bind(graph, tiling, placement, config):
    """Return dict: (tile index, step position) -> StepBinding, and dict matvec tid -> MXM unit."""
    steps = {}
    planes = {}
    for tile in tiling.tiles:
        if tile.kind != "op":
            continue
        units = []
        for k, step in enumerate(tile.steps):
            t = graph.t(step.tid)
            if t.op == "matvec":
                unit = matvec_plane(graph, t, placement)
                planes[t.id] = unit
            elif t.op == "broadcast":
                if config.tiles > 1:
                    raise CompileError(f"{t.name}: broadcast needs Distribute, which cannot move "
                                       f"data between superlanes (config has {config.tiles} tiles)")
                prev = units[k - 1] if k > 0 else None
                if prev is not None and config.kind(prev) == "MXM":
                    unit = f"SXM_{hemi_of(prev)}"
                elif step.spine_slot < 0:
                    unit = f"SXM_{hemi_of(placement[t.args[0]][0][0])}"
                else:
                    unit = "SXM_W"
            else:
                unit = "VXM"
            units.append(unit)

        xs = [config.vxm_pos if u == "VXM" else config.pos(u) for u in units]
        for k, step in enumerate(tile.steps):
            if k + 1 < len(tile.steps):
                d = toward(xs[k], xs[k + 1])
            else:
                slice_x = [config.pos(u) for u, _ in placement[step.tid]]
                dirs = [toward(xs[k], sx) for sx in slice_x]
                if any(dd != dirs[0] for dd in dirs):
                    raise CompileError(f"{graph.t(step.tid).name}: write slices on both sides of the producer")
                d = dirs[0]
            unit = units[k]
            if config.kind(unit) == "MXM":
                inward = "E" if hemi_of(unit) == "W" else "W"
                if d != inward:
                    raise CompileError(f"{graph.t(step.tid).name}: MXM result must flow inward (ledger: B10)")
            steps[(tile.index, k)] = StepBinding(unit, xs[k], kind_of_step(graph, step), d)
    return steps, planes


def kind_of_step(graph, step):
    t = graph.t(step.tid)
    if t.op == "matvec":
        return "abc"
    if t.op == "broadcast":
        return "distribute"
    return t.op


def operand_dir(mxm_unit):
    """Direction in which operands of an MXM plane flow (ledger B10: outward)."""
    return hemi_of(mxm_unit)
