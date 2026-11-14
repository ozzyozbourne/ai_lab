"""Compiled program: the compiler's output and the simulator's input.

Also holds the host side of the memory layout (plan.md 3.4): building the initial
memory image from tensors and reading results back. Nothing here knows about
scheduling.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Protocol

import numpy as np

from .config import ChipConfig
from .isa import DType, Entry, Issue, Nop, from_bytes, issue_cycles, text, to_bytes

VECTOR = "vector"
MATRIX_COLS = "matrix_cols"


@dataclass(frozen=True)
class PlaneLoc:
    """Where one byte plane of one stored vector lives."""
    slice: str
    bank: int
    addr: int


@dataclass(frozen=True)
class TileLayout:
    # vector: (i,) -> elements i*tile_len ...
    # matrix_cols: (out_tile, in_tile, r) -> column in_tile*tile_len + r, rows of output tile out_tile
    index: tuple[int, ...]
    tag: str                       # plane j carries tag f"{tag}#{j}"
    planes: tuple[PlaneLoc, ...]   # one per byte of the dtype, low byte first


@dataclass(frozen=True)
class TensorLayout:
    name: str
    dtype: DType
    shape: tuple[int, ...]         # (n,) or (m, n)
    kind: str                      # VECTOR | MATRIX_COLS
    tiles: tuple[TileLayout, ...]


@dataclass(frozen=True)
class MemInit:
    slice: str
    bank: int
    addr: int
    data: np.ndarray               # uint8[lanes]
    tag: str


class MemoryLike(Protocol):
    def read(self, slice: str, bank: int, addr: int) -> tuple[np.ndarray, str]: ...


@dataclass
class Program:
    name: str
    config_name: str
    tile_len: int
    queues: dict[str, list[Entry]]                                  # every unit, in config.unit_names() order
    constants: dict[str, np.ndarray] = field(default_factory=dict)  # values of constant leaves
    inputs: dict[str, TensorLayout] = field(default_factory=dict)   # every leaf: constants and runtime inputs
    outputs: dict[str, TensorLayout] = field(default_factory=dict)
    report: list[dict] = field(default_factory=list)                # per-chain scheduling record; informational

    # ---- host side ----------------------------------------------------------
    def feed_names(self) -> list[str]:
        return [n for n in self.inputs if n not in self.constants]

    def memory_image(self, feeds: dict[str, np.ndarray], config: ChipConfig) -> list[MemInit]:
        """Initial memory contents for the given runtime inputs (L-M6)."""
        missing = [n for n in self.feed_names() if n not in feeds]
        extra = [n for n in feeds if n not in self.inputs or n in self.constants]
        if missing or extra:
            raise ValueError(f"feeds: missing {missing}, unexpected {extra}")
        image: list[MemInit] = []
        for name, lay in self.inputs.items():
            arr = np.asarray(self.constants[name] if name in self.constants else feeds[name])
            if arr.shape != lay.shape:
                raise ValueError(f"{name}: shape {arr.shape} != {lay.shape}")
            arr = arr.astype(lay.dtype.np)
            for tile in lay.tiles:
                vec = _tile_elements(arr, lay.kind, tile.index, self.tile_len)
                planes = to_bytes(vec, lay.dtype, config.lanes)
                for j, loc in enumerate(tile.planes):
                    image.append(MemInit(loc.slice, loc.bank, loc.addr, planes[j], f"{tile.tag}#{j}"))
        return image

    def read_outputs(self, memory: MemoryLike, config: ChipConfig) -> dict[str, np.ndarray]:
        """Collect every output tensor from memory after a run."""
        out: dict[str, np.ndarray] = {}
        for name, lay in self.outputs.items():
            (n,) = lay.shape
            res = np.zeros(n, dtype=lay.dtype.np)
            for tile in lay.tiles:
                planes = np.stack([memory.read(p.slice, p.bank, p.addr)[0] for p in tile.planes])
                vec = from_bytes(planes, lay.dtype)
                lo = tile.index[0] * self.tile_len
                hi = min(n, lo + self.tile_len)
                res[lo:hi] = vec[: hi - lo]
            out[name] = res
        return out

    # ---- listing ------------------------------------------------------------
    def listing(self) -> str:
        """Per-queue program text with issue cycles."""
        lines = [f"; program {self.name} for chip '{self.config_name}'"]
        for unit, q in self.queues.items():
            if not q:
                continue
            lines.append(f"{unit}:")
            t = 0
            for e in q:
                if isinstance(e, Nop):
                    lines.append(f"  {t:6d}  NOP {e.n}")
                    t += e.n
                else:
                    lines.append(f"  {t:6d}  " + " | ".join(text(i) for i in e.instrs))
                    t += 1
        return "\n".join(lines) + "\n"

    def n_instructions(self) -> int:
        return sum(len(issue_cycles(q)) for q in self.queues.values())


def _tile_elements(arr: np.ndarray, kind: str, index: tuple[int, ...], tile_len: int) -> np.ndarray:
    if kind == VECTOR:
        (i,) = index
        return arr[i * tile_len:(i + 1) * tile_len]
    if kind == MATRIX_COLS:
        out_tile, in_tile, r = index
        return arr[out_tile * tile_len:(out_tile + 1) * tile_len, in_tile * tile_len + r]
    raise ValueError(kind)
