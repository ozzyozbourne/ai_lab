"""Pass 3 (plan 5.2): placement of leaf planes, and the memory bookkeeping that the
scheduler reuses when it parks intermediates.

Runs after chain formation and the ideal timetable in code, because the
self-conflict check below needs each chain's read offsets (the plan lists the
passes in the order of the brief; 5.3 likewise runs before 5.2).

Rules (plan 5.2):
- bank 0 holds leaves, bank 1 parked intermediates and outputs (L-M4);
- planes of one stored vector go to distinct slices of one hemisphere (L-K4);
- install rows of one weight tile (matrix columns, and leaf columns of a
  matvec_cols) go round-robin over the min(M, iw_max_streams) slices nearest the
  MXM plane of the MATVEC that uses them (L-K5);
- other leaf vectors go to the hemisphere of their first consumer's unit (West
  for the VXM, for a leaf with no consumer, and for SHIFT operands, see assign.py),
  on slices from a per-hemisphere rotating cursor;
- co-read rule: slices of two memory-sourced operands of one operation are disjoint;
- addresses are bump-allocated per (slice, bank); running out is a CompileError.

Policy choices where the plan is open:
- Round-robin: plane j of install row r of a weight tile goes to the
  `(r * nbytes + j) mod S`-th nearest slice (S = min(M, iw_max_streams)); the count
  restarts at 0 for every weight tile. Matrices that no live MATVEC uses go
  round-robin next to MXM_W.
- Cursor: one per hemisphere, an index into MEM_h0, MEM_h1, ... (MEM_h0 is next
  to the VXM). Each plane takes the first acceptable slice at or after the cursor
  (wrapping), and the cursor moves one past it. Leaf vectors are placed in node
  order, tiles in order, planes in order.
- Self-conflict avoidance (generalises the co-read rule): within one chain, no two
  memory Reads may be in the same slice at the same offset from the anchor. Every
  read of a placed plane is recorded as a mark (slice, read-sample offset) on the
  reading chain; a candidate slice whose read would hit an existing mark is
  skipped. Two operands of one VXM operation in one slice would always hit, so
  this includes the co-read rule, which is also checked explicitly. If no slice
  is acceptable the result is an immediate CompileError.
"""
from __future__ import annotations

from dataclasses import dataclass, field

from ..config import ChipConfig
from ..program import PlaneLoc
from .assign import VXM, unit_pos
from .chains import Chain
from .errors import CompileError
from .timetable import ChainTime, hemisphere_slices, read_sample_offset
from .tiling import MATVEC, Tiled

LEAF_BANK = 0
PARK_BANK = 1


@dataclass
class Memory:
    """Address bump pointers and the location of every stored plane."""
    config: ChipConfig
    loc: dict[int, tuple[PlaneLoc, ...]] = field(default_factory=dict)   # vid -> planes
    next_addr: dict[tuple[str, int], int] = field(default_factory=dict)  # (slice, bank) -> next free

    def peek(self, slice_name: str, bank: int) -> int | None:
        a = self.next_addr.get((slice_name, bank), 0)
        return a if a < self.config.words_per_bank else None

    def alloc(self, slice_name: str, bank: int) -> int:
        a = self.peek(slice_name, bank)
        if a is None:
            raise CompileError(f"{slice_name} bank {bank} is full ({self.config.words_per_bank} words, L-M2)")
        self.next_addr[(slice_name, bank)] = a + 1
        return a


@dataclass
class ReadMarks:
    """For each chain: (slice, read-sample offset) -> (vid, bank) of every known memory read."""
    tg: Tiled
    chains: list[Chain]
    times: list[ChainTime]
    config: ChipConfig
    marks: list[dict[tuple[str, int], tuple[int, int]]] = field(default_factory=list)
    readers: dict[int, list[tuple[int, int]]] = field(default_factory=dict)   # vid -> (cid, member)

    def __post_init__(self):
        self.marks = [{} for _ in self.chains]
        for c in self.chains:
            for (i, v) in c.mem_reads:
                self.readers.setdefault(v, []).append((c.cid, i))

    def new_marks(self, vid: int, slice_name: str) -> list[tuple[int, tuple[str, int]]]:
        x = self.config.pos(slice_name)
        return [(cid, (slice_name, read_sample_offset(self.times[cid], i, x, self.config)))
                for (cid, i) in self.readers.get(vid, [])]

    def blocked(self, vid: int, slice_name: str, mem: Memory) -> str | None:
        """Why a plane of `vid` may not live in `slice_name`, or None."""
        # co-read rule: another memory operand of the same operation already in this slice
        for (cid, i) in self.readers.get(vid, []):
            for (j, u) in self.chains[cid].mem_reads:
                if j == i and u != vid and u in mem.loc and any(p.slice == slice_name for p in mem.loc[u]):
                    return f"co-read with {self.tg.vals[u].prefix}"
        # self-conflict: two reads of one chain in one slice at one cycle
        seen: dict[tuple[int, tuple[str, int]], bool] = {}
        for cid, key in self.new_marks(vid, slice_name):
            if key in self.marks[cid] or (cid, key) in seen:
                return f"same-cycle read in chain {cid}"
            seen[(cid, key)] = True
        return None

    def record(self, vid: int, planes: tuple[PlaneLoc, ...]) -> None:
        for p in planes:
            for cid, key in self.new_marks(vid, p.slice):
                self.marks[cid][key] = (vid, p.bank)


def nearest_slices(unit: str, config: ChipConfig) -> list[str]:
    """Slices of the unit's hemisphere, nearest first."""
    x = config.pos(unit)
    return sorted(hemisphere_slices(config.hemi(unit), config), key=lambda s: abs(config.pos(s) - x))


def place_round_robin(vid: int, r: int, near: list[str], tg: Tiled, mem: Memory, marks: ReadMarks) -> None:
    nb = tg.vals[vid].dtype.nbytes
    if nb > len(near):
        raise CompileError(f"{tg.vals[vid].prefix}: {nb} planes but only {len(near)} slices")
    planes = []
    for j in range(nb):
        s = near[(r * nb + j) % len(near)]
        planes.append(PlaneLoc(s, LEAF_BANK, mem.alloc(s, LEAF_BANK)))
    mem.loc[vid] = tuple(planes)
    marks.record(vid, mem.loc[vid])


def place_leaves(tg: Tiled, chains: list[Chain], times: list[ChainTime], units: list[str],
                 config: ChipConfig) -> tuple[Memory, ReadMarks]:
    mem = Memory(config)
    marks = ReadMarks(tg, chains, times, config)
    S = min(config.mem_slices_per_hemi, config.iw_max_streams)

    # 1. install rows, per MATVEC in op order
    for op in tg.ops:
        if op.kind != MATVEC:
            continue
        near = nearest_slices(units[op.oid], config)[:S]
        for r, v in enumerate(op.rows):
            if tg.vals[v].leaf is not None and v not in mem.loc:
                place_round_robin(v, r, near, tg, mem, marks)

    # 2. other leaf vectors: rotating cursor per hemisphere
    cursor: dict[str, int] = {}
    m = config.mem_slices_per_hemi
    by_name = {tg.vals[v].leaf: [] for v in range(len(tg.vals)) if tg.vals[v].node is not None}
    for v in tg.vals:
        if v.leaf is not None and v.node is not None:
            by_name[v.leaf].append(v.vid)
    for name in tg.leaf_vectors:
        for vid in by_name[name]:
            if vid in mem.loc:
                continue
            users = sorted(tg.consumers.get(vid, []) + tg.row_users.get(vid, []))
            hemi = "W"
            if users and units[users[0]] != VXM:
                hemi = config.hemi(units[users[0]])
            slices = hemisphere_slices(hemi, config)
            planes: list[PlaneLoc] = []
            for j in range(tg.vals[vid].dtype.nbytes):
                start = cursor.get(hemi, 0)
                reasons = []
                for step in range(m):
                    idx = (start + step) % m
                    s = slices[idx]
                    why = None
                    if any(p.slice == s for p in planes):
                        why = "holds a lower plane"
                    elif mem.peek(s, LEAF_BANK) is None:
                        why = "bank 0 full"
                    else:
                        why = marks.blocked(vid, s, mem)
                    if why is None:
                        planes.append(PlaneLoc(s, LEAF_BANK, mem.alloc(s, LEAF_BANK)))
                        cursor[hemi] = (idx + 1) % m
                        break
                    reasons.append(f"{s}: {why}")
                else:
                    raise CompileError(f"cannot place plane {j} of {tg.vals[vid].prefix}: " + "; ".join(reasons))
            mem.loc[vid] = tuple(planes)
            marks.record(vid, mem.loc[vid])

    # 3. matrices no live MATVEC installs
    near_w = nearest_slices("MXM_W", config)[:S]
    for name, cols in tg.matrix_cols.items():
        for v in cols:
            if v not in mem.loc:
                place_round_robin(v, tg.vals[v].index[2], near_w, tg, mem, marks)
    return mem, marks


def leaf_positions(tg: Tiled, mem: Memory, config: ChipConfig) -> dict[int, tuple[int, ...]]:
    return {v: tuple(config.pos(p.slice) for p in planes) for v, planes in mem.loc.items()}


__all__ = ["Memory", "ReadMarks", "place_leaves", "LEAF_BANK", "PARK_BANK", "unit_pos", "leaf_positions"]
