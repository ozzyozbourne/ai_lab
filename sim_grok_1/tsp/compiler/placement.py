"""Stage 2 (plan 4.2): place every stored tensor in MEM.

Each stored tensor (constant, input, or a tile's final result) gets one
(MEM unit, address) per byte plane.  The rules:

* All planes of a tensor are on distinct slices of one hemisphere, so every
  plane reaches any consumer from the same direction and the reads or writes
  of one tensor never need the same slice twice.
* Addresses come from a per-slice counter starting at 0 and are never reused.
* **Matrix rows first.**  A row of any matrix is placed by the rule of the first
  matrix (in creation order) that contains it.  Matrix i goes to hemisphere W
  if i is even, E if odd.  Row r takes the window of w consecutive slices that
  starts at the slice farthest from the VXM (nearest the MXM) and moves inward
  by w slices per row, wrapping round.  Plane j of row r is on slice index
  (k - 1 - (r*w + j)) mod k, where k is the number of slices per hemisphere.
* **Other tensors**, in tensor-id order, try windows of w consecutive slices:
  hemisphere E then W for an even tensor id, W then E for an odd one; within a
  hemisphere, windows starting at slice 0, 1, 2, ...  The first window that
  shares no slice with an already placed *interfering* tensor is taken.  Two
  tensors interfere if both are read from MEM as operands of one operation.
  (Two matrix rows are never kept apart this way: their place is fixed.)
* If no window works, or a slice runs out of words, CompileError.

Fused intermediates never touch memory and get no place.
"""

from .. import isa
from ..errors import CompileError

HEMIS = ("W", "E")


def hemi_of(unit):
    """Hemisphere letter of a MEM, SXM or MXM unit name ("MEM_E3" -> "E")."""
    return unit.split("_")[1][0]


def interference(chains):
    """tensor id -> list of tensor ids it interferes with (both read by one operation)."""
    pairs = {}
    for chain in chains:
        for step in chain:
            ops = step.mem_operands
            for a in ops:
                for b in ops:
                    if a != b:
                        lst = pairs.setdefault(a, [])
                        if b not in lst:
                            lst.append(b)
    return pairs


class _Allocator:
    """Per-slice bump allocator of MEM addresses."""

    def __init__(self, config):
        self.config = config
        self.next = {}

    def alloc(self, unit, what):
        addr = self.next.get(unit, 0)
        if addr >= self.config.mem_words:
            raise CompileError(f"{unit} is full ({self.config.mem_words} words) while placing {what}")
        self.next[unit] = addr + 1
        return addr


def place(graph, chains, stored, config):
    """Return a dict: tensor id -> tuple of (MEM unit, address), one per plane."""
    k = config.mem_slices_per_hemi
    alloc = _Allocator(config)
    planes = {}

    # 1. Matrix rows.
    for m in graph.matrices:
        hemi = HEMIS[m.id % len(HEMIS)]          # W for an even matrix, E for an odd one
        w = isa.width(m.dtype)
        if w > k:
            raise CompileError(f"matrix {m.name}: a row needs {w} slices, a hemisphere has {k}")
        for r, row in enumerate(m.rows):
            if row in planes:
                continue
            idx = [(k - 1 - (r * w + j)) % k for j in range(w)]
            units = [f"MEM_{hemi}{i}" for i in idx]
            name = graph.t(row).name
            planes[row] = tuple((u, alloc.alloc(u, name)) for u in units)

    # 2. Everything else, in tensor-id order.
    inter = interference(chains)
    for tid in stored:
        if tid in planes:
            continue
        t = graph.t(tid)
        w = isa.width(t.dtype)
        if w > k:
            raise CompileError(f"{t.name}: needs {w} slices, a hemisphere has {k}")
        blocked = []
        for other in inter.get(tid, []):
            if other in planes:
                blocked.extend(u for u, _ in planes[other])
        order = ("E", "W") if tid % len(HEMIS) == 0 else ("W", "E")
        chosen = None
        for hemi in order:
            for start in range(k - w + 1):
                units = [f"MEM_{hemi}{i}" for i in range(start, start + w)]
                if not any(u in blocked for u in units):
                    chosen = units
                    break
            if chosen is not None:
                break
        if chosen is None:
            raise CompileError(f"{t.name}: no window of {w} slices avoids the tensors it is read with")
        planes[tid] = tuple((u, alloc.alloc(u, t.name)) for u in chosen)

    return planes
