"""Stage 1 (plan 4.1): cut the graph into tiles.

A *tile* is a rigid group of instructions whose relative timing is fixed:
MEM reads of the operands, a chain of one or more operations, and MEM writes
of the chain's final result.  It mirrors the sourced pattern
"Read -> Conv2D -> Requantize -> ReLU -> Write" (ledger C2).

How operations are grouped:

* Every graph node is one operation.  Constants, inputs and matrices are not.
* Operation B is *fused* after operation A (A's result goes straight from A to
  B on a stream, never touching memory) when
    - A's result has exactly one use in the whole graph (each operand slot and
      each matrix-row slot counts separately, so `mul(r, r)` uses r twice),
      and that use is an operand slot of B;
    - A's result is not a graph output;
    - B is not a matvec (a matvec always starts a tile);
    - the pair (A, B) is not in the `no_fuse` list (see timetable.py).
  If both operands of B qualify, the first one is fused.
* The fused operand is the tile's *spine*.  Every other operand is read from
  memory.  An operand used twice by one operation is read once.
* The final result of every tile is written to memory.

For every matvec the weight rows are grouped into *install slots*: rows are
taken in order and put in the earliest slot where they fit, a slot holding at
most `config.iw_max_streams` streams (ledger B8) and using each MEM slice at
most once.  Each slot is a small tile of its own: reads of the row planes,
then one `Iw`.  Install slots need to know where the rows live, so they are
built after placement (placement of matrix rows does not depend on tiling).

Tiles are numbered: operation tiles in order of their first operation, each
matvec tile directly preceded by its install-slot tiles.  The number is the
tile index used in tags (`tensor@tile`).
"""

from dataclasses import dataclass

from .. import isa
from ..errors import CompileError


@dataclass(frozen=True)
class Step:
    """One operation of a tile's chain."""

    tid: int                # graph tensor id of the operation's result
    spine_slot: int         # operand slot that holds the fused value, or -1
    mem_operands: tuple     # distinct tensor ids read from MEM, in operand order


@dataclass(frozen=True)
class Tile:
    index: int
    kind: str               # "op" (a chain of operations) or "install" (one Iw)
    steps: tuple = ()       # op tile: the chain of Steps
    matvec: int = -1        # install tile: tensor id of the matvec it serves
    rows: tuple = ()        # install tile: the row indices installed by this slot
    deps: tuple = ()        # tile indices this tile depends on, ascending

    @property
    def result(self):
        """Tensor id of the op tile's stored final result."""
        return self.steps[-1].tid


@dataclass(frozen=True)
class Tiling:
    tiles: tuple            # all tiles, in index order
    stored: tuple           # tensor ids that need a place in MEM, ascending
    producer: dict          # computed stored tensor id -> index of the op tile writing it
    slots: dict             # matvec tensor id -> tuple of its install-tile indices


# --------------------------------------------------------------------------
# Fusion
# --------------------------------------------------------------------------
def count_uses(graph):
    """tensor id -> list of uses.  A use is ("op", consumer id, slot) or ("row", matrix id, row)."""
    uses = {t.id: [] for t in graph.tensors}
    for t in graph.ops():
        for slot, a in enumerate(t.args):
            uses[a].append(("op", t.id, slot))
    for m in graph.matrices:
        for r, row in enumerate(m.rows):
            uses[row].append(("row", m.id, r))
    return uses


def _is_output(graph, tid):
    return any(v == tid for v in graph.outputs.values())


def fuse(graph, no_fuse=()):
    """Group the graph's operations into chains.  Returns a list of lists of Steps.

    no_fuse is a sequence of (producer tensor id, consumer tensor id) pairs
    that must not be fused.
    """
    uses = count_uses(graph)
    chain_of = {}           # op tensor id -> index into chains
    chains = []
    for t in graph.ops():
        spine_slot = -1
        if t.op != "matvec":
            for slot, a in enumerate(t.args):
                src = graph.t(a)
                if (src.kind == "op"
                        and uses[a] == [("op", t.id, slot)]
                        and not _is_output(graph, a)
                        and (a, t.id) not in no_fuse):
                    spine_slot = slot
                    break
        mem = []
        for slot, a in enumerate(t.args):
            if slot != spine_slot and a not in mem:
                mem.append(a)
        step = Step(t.id, spine_slot, tuple(mem))
        if spine_slot >= 0:
            c = chain_of[t.args[spine_slot]]
            chains[c].append(step)
        else:
            c = len(chains)
            chains.append([step])
        chain_of[t.id] = c
    return chains


def stored_tensors(graph, chains):
    """Constants, inputs and every chain's final result, in tensor-id order."""
    tails = [chain[-1].tid for chain in chains]
    out = []
    for t in graph.tensors:
        if t.kind in ("const", "input") or t.id in tails:
            out.append(t.id)
    return tuple(out)


# --------------------------------------------------------------------------
# Install slots
# --------------------------------------------------------------------------
def install_slots(graph, matrix_id, placement, config):
    """Group the rows of one matrix into install slots (first fit).

    Returns a list of tuples of row indices.  placement maps tensor id to its
    tuple of (MEM unit, address) planes.
    """
    m = graph.matrices[matrix_id]
    w = isa.width(m.dtype)
    if w > config.iw_max_streams:
        raise CompileError(f"matrix {m.name}: a {m.dtype} row needs {w} streams, more than one Iw takes")
    slots = []              # each: {"rows": [...], "streams": count, "slices": [...]}
    for r, row in enumerate(m.rows):
        slices = [unit for unit, _ in placement[row]]
        chosen = None
        for slot in slots:
            if (slot["streams"] + w <= config.iw_max_streams
                    and not any(s in slot["slices"] for s in slices)):
                chosen = slot
                break
        if chosen is None:
            chosen = {"rows": [], "streams": 0, "slices": []}
            slots.append(chosen)
        chosen["rows"].append(r)
        chosen["streams"] += w
        chosen["slices"].extend(slices)
    return [tuple(slot["rows"]) for slot in slots]


# --------------------------------------------------------------------------
# Tile list
# --------------------------------------------------------------------------
def build_tiles(graph, chains, placement, config):
    """Number the tiles, build install slots and dependencies.  Returns a Tiling."""
    chains = sorted(chains, key=lambda ch: ch[0].tid)
    producer = {}
    for ch in chains:
        producer[ch[-1].tid] = None     # filled below once indices are known

    # First pass: indices.
    layout = []                          # (kind, payload) in index order
    for ch in chains:
        first = graph.t(ch[0].tid)
        if first.op == "matvec":
            for rows in install_slots(graph, first.matrix, placement, config):
                layout.append(("install", (first.id, rows)))
        layout.append(("op", ch))
    for index, (kind, payload) in enumerate(layout):
        if kind == "op":
            producer[payload[-1].tid] = index

    slots = {}
    for index, (kind, payload) in enumerate(layout):
        if kind == "install":
            mv = payload[0]
            slots[mv] = slots.get(mv, ()) + (index,)

    def dep_of(tid):
        """Index of the tile that writes a computed tensor, or None for a leaf."""
        if graph.t(tid).kind != "op":
            return None
        return producer[tid]

    tiles = []
    for index, (kind, payload) in enumerate(layout):
        deps = []
        if kind == "install":
            mv, rows = payload
            m = graph.matrices[graph.t(mv).matrix]
            for r in rows:
                d = dep_of(m.rows[r])
                if d is not None and d not in deps:
                    deps.append(d)
            tiles.append(Tile(index, "install", matvec=mv, rows=rows, deps=tuple(sorted(deps))))
        else:
            ch = payload
            for step in ch:
                for u in step.mem_operands:
                    d = dep_of(u)
                    if d is not None and d not in deps:
                        deps.append(d)
            first = graph.t(ch[0].tid)
            if first.op == "matvec":
                for d in slots[first.id]:
                    deps.append(d)
            tiles.append(Tile(index, "op", steps=tuple(ch), deps=tuple(sorted(deps))))

    return Tiling(tuple(tiles), stored_tensors(graph, chains), producer, slots)
