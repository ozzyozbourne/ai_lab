"""All simulator parameters, each tied to the ASSUMPTIONS LEDGER.

The ledger is section 7 of research/dossier.md.  A comment "# ledger: ID"
names the entry that says whether the value is SOURCED or ASSUMED and why.
No other module may introduce a numeric parameter.
"""

from dataclasses import dataclass, field

# --- Geometry ---------------------------------------------------------------
LANES_PER_SUPERLANE = 16          # ledger: G1
TILES_TOY = 1                     # ledger: G2
TILES_ISCA2020 = 20               # ledger: G2
STREAMS_PER_DIR = 32              # ledger: G3
STREAM_ELEMENT_BYTES = 1          # ledger: G4
WIDTH_INT8 = 1                    # ledger: G5
WIDTH_FP16 = 2                    # ledger: G5
WIDTH_INT32 = 4                   # ledger: G5
WIDTH_FP32 = 4                    # ledger: G5
MEM_SLICES_PER_HEMI_TOY = 8       # ledger: G7
MEM_SLICES_PER_HEMI_ISCA2020 = 44  # ledger: G7
NON_MEM_POSITIONS = 5             # ledger: G8
MEM_WORDS = 8192                  # ledger: G9
MXM_PLANES_PER_HEMI_TOY = 1       # ledger: G10
MXM_PLANES_PER_HEMI_ISCA2020 = 2  # ledger: G10
VXM_ALUS = 16                     # ledger: G12

# --- Timing -----------------------------------------------------------------
D_MEM_READ = 2                    # ledger: T6
D_MEM_WRITE = 1                   # ledger: T7
D_VXM_SIMPLE = 1                  # ledger: T8
D_VXM_MUL = 2                     # ledger: T9
D_VXM_TRANSCENDENTAL = 4          # ledger: T10
D_MXM_IW = 1                      # ledger: T11
D_MXM_ABC = 3                     # ledger: T12
D_SXM = 2                         # ledger: T13
NOP_MAX = 65535                   # ledger: T14
BARRIER_CYCLES = 35               # ledger: T15
CLOCK_HZ = 900_000_000            # ledger: T17

# --- Behaviour --------------------------------------------------------------
IW_MAX_STREAMS = 16               # ledger: B8
INT8_MIN = -128                   # ledger: B20
INT8_MAX = 127                    # ledger: B20

# --- Compiler policy --------------------------------------------------------
MAX_SCHEDULE_CYCLES = 100_000     # ledger: C4

# VXM operations grouped by latency class (ledger: B11, T8, T9, T10).
VXM_SIMPLE_OPS = ("add", "sub", "neg", "relu", "cast", "requant")
VXM_MUL_OPS = ("mul",)
VXM_TRANSCENDENTAL_OPS = ("tanh", "exp", "rsqrt")
VXM_UNARY_OPS = ("neg", "relu", "tanh", "exp", "rsqrt", "cast", "requant")
VXM_BINARY_OPS = ("add", "sub", "mul")


def default_latency():
    """Latency in cycles (d_func) for each instruction kind."""
    lat = {
        "read": D_MEM_READ,
        "write": D_MEM_WRITE,
        "iw": D_MXM_IW,
        "abc": D_MXM_ABC,
        "distribute": D_SXM,
        "permute": D_SXM,
        "shift": D_SXM,
    }
    for op in VXM_SIMPLE_OPS:
        lat[op] = D_VXM_SIMPLE
    for op in VXM_MUL_OPS:
        lat[op] = D_VXM_MUL
    for op in VXM_TRANSCENDENTAL_OPS:
        lat[op] = D_VXM_TRANSCENDENTAL
    return lat


@dataclass(frozen=True)
class ChipConfig:
    """Geometry and timing of one simulated chip."""

    lanes_per_superlane: int = LANES_PER_SUPERLANE
    tiles: int = TILES_TOY
    streams_per_dir: int = STREAMS_PER_DIR
    mem_slices_per_hemi: int = MEM_SLICES_PER_HEMI_TOY
    mem_words: int = MEM_WORDS
    mxm_planes_per_hemi: int = MXM_PLANES_PER_HEMI_TOY
    vxm_alus: int = VXM_ALUS
    iw_max_streams: int = IW_MAX_STREAMS
    barrier_cycles: int = BARRIER_CYCLES
    nop_max: int = NOP_MAX
    clock_hz: int = CLOCK_HZ
    max_schedule_cycles: int = MAX_SCHEDULE_CYCLES
    latency: dict = field(default_factory=default_latency, hash=False, compare=False)

    @classmethod
    def toy(cls):
        """Scaled-down chip used by the milestones."""
        return cls()

    @classmethod
    def isca2020(cls):
        """Sourced geometry of the ISCA 2020 chip, with the same assumed latencies."""
        return cls(
            tiles=TILES_ISCA2020,
            mem_slices_per_hemi=MEM_SLICES_PER_HEMI_ISCA2020,
            mxm_planes_per_hemi=MXM_PLANES_PER_HEMI_ISCA2020,
        )

    # -- derived geometry ----------------------------------------------------
    @property
    def lanes(self):
        return self.lanes_per_superlane * self.tiles

    @property
    def n_positions(self):
        return self.mem_slices_per_hemi + self.mem_slices_per_hemi + NON_MEM_POSITIONS

    @property
    def vxm_pos(self):
        return self.mem_slices_per_hemi + 2  # not-a-parameter: MXM and SXM sit west of the MEM block

    def mem_slices(self, hemi):
        """MEM unit names of one hemisphere, index 0 (nearest the VXM) first."""
        return tuple(f"MEM_{hemi}{i}" for i in range(self.mem_slices_per_hemi))

    def units(self):
        """Every unit name in canonical order: west to east, then by index."""
        k = self.mem_slices_per_hemi
        names = [f"MXM_W{p}" for p in range(self.mxm_planes_per_hemi)]
        names.append("SXM_W")
        names += [f"MEM_W{i}" for i in range(k - 1, -1, -1)]
        names += [f"VXM_A{a}" for a in range(self.vxm_alus)]
        names += [f"MEM_E{i}" for i in range(k)]
        names.append("SXM_E")
        names += [f"MXM_E{p}" for p in range(self.mxm_planes_per_hemi)]
        return tuple(names)

    def kind(self, unit):
        """Unit type: 'MXM', 'SXM', 'MEM' or 'VXM'."""
        return unit.split("_")[0]

    def pos(self, unit):
        """Stream-register position of a unit (0 = west edge)."""
        k = self.mem_slices_per_hemi
        kind, rest = unit.split("_")
        if kind == "VXM":
            return self.vxm_pos
        hemi = rest[0]
        if kind == "MXM":
            return 0 if hemi == "W" else self.n_positions - 1
        if kind == "SXM":
            return 1 if hemi == "W" else self.n_positions - 2  # not-a-parameter: SXM is one position inside the MXM
        index = int(rest[1:])
        if kind == "MEM":
            return self.vxm_pos - 1 - index if hemi == "W" else self.vxm_pos + 1 + index
        raise ValueError(f"unknown unit {unit!r}")

    def to_dict(self):
        """Plain, JSON-serialisable description (keys sorted)."""
        d = {
            "lanes_per_superlane": self.lanes_per_superlane,
            "tiles": self.tiles,
            "streams_per_dir": self.streams_per_dir,
            "mem_slices_per_hemi": self.mem_slices_per_hemi,
            "mem_words": self.mem_words,
            "mxm_planes_per_hemi": self.mxm_planes_per_hemi,
            "vxm_alus": self.vxm_alus,
            "iw_max_streams": self.iw_max_streams,
            "barrier_cycles": self.barrier_cycles,
            "nop_max": self.nop_max,
            "clock_hz": self.clock_hz,
            "max_schedule_cycles": self.max_schedule_cycles,
            "latency": dict(sorted(self.latency.items())),
        }
        return d

    @classmethod
    def from_dict(cls, d):
        return cls(**d)
