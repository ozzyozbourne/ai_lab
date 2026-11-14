"""MEM slices (plan.md 2.6, L-M1..L-M6).

`Memory` is the word store of every MEM slice; one address holds one byte plane
(`lanes` bytes) and its tag. Words are kept in a dict, so the paper preset's
large banks cost nothing until written. The MEM unit's instruction rules (port
limits, widths, ranges) are in this module too.
"""
from __future__ import annotations

import numpy as np

from ..config import ChipConfig
from ..isa import Read, Write
from ..program import MemInit
from .errors import MEM_PORT, OPERAND_RULE, QUEUE_ENTRY, Violation
from .operands import check_sref


class Memory:
    def __init__(self, config: ChipConfig):
        self._cfg = config
        self._slices = {s: True for s in config.slice_names() if config.kind(s) == "MEM"}
        self._words: dict[tuple[str, int, int], tuple[np.ndarray, str]] = {}

    def _check(self, slice: str, bank: int, addr: int) -> None:
        if slice not in self._slices:
            raise ValueError(f"{slice!r} is not a MEM slice")
        if not 0 <= bank < self._cfg.banks_per_slice:
            raise ValueError(f"bank {bank} out of range")
        if not 0 <= addr < self._cfg.words_per_bank:
            raise ValueError(f"address {addr} out of range")

    def has(self, slice: str, bank: int, addr: int) -> bool:
        return (slice, bank, addr) in self._words

    def read(self, slice: str, bank: int, addr: int) -> tuple[np.ndarray, str]:
        """(uint8[lanes] copy, tag). KeyError if the word was never written."""
        self._check(slice, bank, addr)
        data, tag = self._words[(slice, bank, addr)]
        return data.copy(), tag

    def write(self, slice: str, bank: int, addr: int, data: np.ndarray, tag: str) -> None:
        self._check(slice, bank, addr)
        arr = np.asarray(data)
        if arr.shape != (self._cfg.lanes,) or arr.dtype != np.uint8:
            raise ValueError(f"a word is uint8[{self._cfg.lanes}], got {arr.dtype}{list(arr.shape)}")
        self._words[(slice, bank, addr)] = (arr.copy(), tag)

    def load(self, image: list[MemInit]) -> None:
        """Host writes before cycle 0 (L-M6)."""
        for m in image:
            self.write(m.slice, m.bank, m.addr, m.data, m.tag)

    def addresses(self) -> list[tuple[str, int, int]]:
        """Every written (slice, bank, addr), sorted."""
        return sorted(self._words)


# ---- MEM unit rules -------------------------------------------------------------
def check_entry(instrs) -> None:
    """A MEM queue entry holds at most one Read and one Write (L-I2)."""
    n_read = sum(isinstance(i, Read) for i in instrs)
    n_write = sum(isinstance(i, Write) for i in instrs)
    if n_read > 1 or n_write > 1:
        raise Violation(QUEUE_ENTRY, f"a MEM entry holds at most one Read and one Write, got {n_read} and {n_write}")


def check_instr(config: ChipConfig, instr) -> None:
    ref = instr.out if isinstance(instr, Read) else instr.src
    check_sref(config, ref, 1, "Read out" if isinstance(instr, Read) else "Write src")
    if not 0 <= instr.bank < config.banks_per_slice:
        raise Violation(OPERAND_RULE, f"bank {instr.bank} out of range 0..{config.banks_per_slice - 1}")
    if not 0 <= instr.addr < config.words_per_bank:
        raise Violation(OPERAND_RULE, f"address {instr.addr} out of range 0..{config.words_per_bank - 1}")


def check_ports(instrs) -> None:
    """Instructions of one slice that sample in one cycle (L-M4, L-M5)."""
    reads = [i for i in instrs if isinstance(i, Read)]
    writes = [i for i in instrs if isinstance(i, Write)]
    if len(reads) > 1:
        raise Violation(MEM_PORT, f"{len(reads)} Reads with the same sample cycle")
    if len(writes) > 1:
        raise Violation(MEM_PORT, f"{len(writes)} Writes with the same sample cycle")
    if reads and writes and reads[0].bank == writes[0].bank:
        raise Violation(MEM_PORT, f"a Read and a Write on bank {reads[0].bank} with the same sample cycle")
