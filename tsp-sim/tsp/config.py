"""Machine parameters. This is the only file that may contain them.

Every literal carries the ID of its entry in the ASSUMPTIONS LEDGER
(research/dossier.md, section 7). SOURCED / INFERRED / ASSUMED status is
recorded there, not here.
"""
from __future__ import annotations

from dataclasses import dataclass, replace
from types import MappingProxyType
from typing import Mapping

EAST = "E"
WEST = "W"
DIRS = (EAST, WEST)

# Keys of ChipConfig.timing. Which instruction uses which key: isa.timing_key().
TIMING_KEYS = ("READ", "WRITE", "VARITH", "VTRANS", "IW", "MATVEC", "SXM")

SXM_UNITS = ("shift", "permute", "distribute")  # L-S2


@dataclass(frozen=True)
class OpTiming:
    d_skew: int  # cycles from issue to operand sampling (L-T2)
    d_func: int  # cycles from sampling to the result being on the stream


def _default_timing() -> Mapping[str, OpTiming]:
    return MappingProxyType({
        "READ":   OpTiming(d_skew=0, d_func=2),  # L-T2, L-T3
        "WRITE":  OpTiming(d_skew=0, d_func=1),  # L-T2, L-T4 (stored word readable one cycle later)
        "VARITH": OpTiming(d_skew=0, d_func=1),  # L-T2, L-T5
        "VTRANS": OpTiming(d_skew=0, d_func=3),  # L-T2, L-T6
        "IW":     OpTiming(d_skew=0, d_func=1),  # L-T2, L-T7 (rows usable one cycle later)
        "MATVEC": OpTiming(d_skew=0, d_func=3),  # L-T2, L-T8
        "SXM":    OpTiming(d_skew=0, d_func=1),  # L-T2, L-T9
    })


@dataclass(frozen=True)
class ChipConfig:
    name: str
    lanes_per_superlane: int        # L-G1
    superlanes: int                 # L-G2
    streams_per_dir: int            # L-G5
    mem_slices_per_hemi: int        # L-G10
    banks_per_slice: int            # L-M1
    words_per_bank: int             # L-M2
    n_alus: int                     # L-V1
    planes_per_mxm: int             # L-X1
    iw_max_streams: int             # L-X3
    nop_max: int                    # L-T10
    clock_hz: float                 # L-C1 (display only)
    timing: Mapping[str, OpTiming]  # L-T2 .. L-T9
    max_schedule_cycles: int        # L-K6: the compiler gives up beyond this

    # ---- derived geometry -------------------------------------------------
    @property
    def lanes(self) -> int:  # L-G3
        return self.lanes_per_superlane * self.superlanes

    @property
    def n_positions(self) -> int:  # L-G11: one stream-register position per slice
        return 2 * self.mem_slices_per_hemi + 5

    @property
    def vxm_pos(self) -> int:
        return self.mem_slices_per_hemi + 2

    def slice_names(self) -> list[str]:
        """Slices West to East (L-G9). Index in this list == position."""
        m = self.mem_slices_per_hemi
        return (["MXM_W", "SXM_W"]
                + [f"MEM_W{i}" for i in range(m - 1, -1, -1)]
                + ["VXM"]
                + [f"MEM_E{i}" for i in range(m)]
                + ["SXM_E", "MXM_E"])

    def units_of(self, slice_name: str) -> list[str]:
        """Instruction queues of one slice (L-I1)."""
        if slice_name.startswith("MEM"):
            return [slice_name]
        if slice_name == "VXM":
            return [f"VXM.{i}" for i in range(self.n_alus)]
        if slice_name.startswith("MXM"):
            return [f"{slice_name}.{i}" for i in range(self.planes_per_mxm)]
        if slice_name.startswith("SXM"):
            return [f"{slice_name}.{u}" for u in SXM_UNITS]
        raise KeyError(slice_name)

    def unit_names(self) -> list[str]:
        """Every instruction queue, West to East. This order is the canonical unit order."""
        return [u for s in self.slice_names() for u in self.units_of(s)]

    def slice_of(self, unit: str) -> str:
        return unit.split(".")[0]

    def kind(self, unit: str) -> str:
        """'MEM' | 'VXM' | 'MXM' | 'SXM' for a unit or slice name."""
        return unit[:3]

    def pos(self, unit: str) -> int:
        """Position of a unit or slice name."""
        s = self.slice_of(unit)
        m = self.mem_slices_per_hemi
        if s == "MXM_W":
            return 0
        if s == "SXM_W":
            return 1
        if s.startswith("MEM_W"):
            return m + 1 - int(s[5:])
        if s == "VXM":
            return m + 2
        if s.startswith("MEM_E"):
            return m + 3 + int(s[5:])
        if s == "SXM_E":
            return 2 * m + 3
        if s == "MXM_E":
            return 2 * m + 4
        raise KeyError(unit)

    def hemi(self, unit: str) -> str | None:
        """'W' or 'E' for units off-centre, None for the VXM."""
        p = self.pos(unit)
        if p == self.vxm_pos:
            return None
        return WEST if p < self.vxm_pos else EAST

    def issue_width(self, unit: str) -> int:
        """Instructions one queue may issue in one cycle (L-I2)."""
        return 2 if self.kind(unit) == "MEM" else 1  # L-I2

    def cycles_to_seconds(self, cycles: int) -> float:
        return cycles / self.clock_hz

    def with_timing(self, **overrides: OpTiming) -> "ChipConfig":
        """Copy with some latencies replaced (used by tests)."""
        t = dict(self.timing)
        for k, v in overrides.items():
            if k not in t:
                raise KeyError(k)
            t[k] = v
        return replace(self, timing=MappingProxyType(t))

    # ---- presets -----------------------------------------------------------
    @staticmethod
    def toy() -> "ChipConfig":
        return ChipConfig(
            name="toy",
            lanes_per_superlane=16,     # L-G1
            superlanes=2,               # L-G2 (toy)
            streams_per_dir=32,         # L-G5
            mem_slices_per_hemi=16,     # L-G10 (toy)
            banks_per_slice=2,          # L-M1
            words_per_bank=64,          # L-M2 (toy)
            n_alus=16,                  # L-V1
            planes_per_mxm=2,           # L-X1
            iw_max_streams=16,          # L-X3
            nop_max=65535,              # L-T10
            clock_hz=900e6,             # L-C1
            timing=_default_timing(),
            max_schedule_cycles=100000,  # L-K6
        )

    @staticmethod
    def paper() -> "ChipConfig":
        return ChipConfig(
            name="paper",
            lanes_per_superlane=16,     # L-G1
            superlanes=20,              # L-G2
            streams_per_dir=32,         # L-G5
            mem_slices_per_hemi=44,     # L-G10
            banks_per_slice=2,          # L-M1
            words_per_bank=4096,        # L-M2
            n_alus=16,                  # L-V1
            planes_per_mxm=2,           # L-X1
            iw_max_streams=16,          # L-X3
            nop_max=65535,              # L-T10
            clock_hz=900e6,             # L-C1
            timing=_default_timing(),
            max_schedule_cycles=100000,  # L-K6
        )
