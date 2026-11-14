"""Pass 5 (plan 5.5): ideal timetable.

Every offset is relative to the chain's anchor t0 = the sample cycle of the
chain's first operation, and is computed from `config.timing` and position
distances alone (L-T1):

- member i samples at `sample[i]`; its result is visible at its own position at
  `vis[i] = sample[i] + d_func`; member i+1 samples it `|x[i+1] - x[i]|` cycles
  later (`link_dir[i]` is the direction of that stream; two VXM members are
  linked eastward at distance 0);
- a Read of a plane stored at x_m that feeds member i samples at
  `sample[i] - |x[i] - x_m| - d_func(READ)` (`read_sample_offset`);
- a parking Write at x_m samples at `vis[-1] + |x_m - x[-1]|`.

Output data structure (`ChainTime`, one per chain) plus the parking plan
(hemisphere, direction of flow and candidate slices in flow order).

ASAP and heights are computed here as well (`ideal_anchors`, `heights`).
Policy where the plan is open: heights are a placement-independent estimate,
`span = vis[-1] - min(issue) + d_func(WRITE)` plus, for a MATVEC chain,
`waves + d_func(IW)` with `waves = ceil(streams / iw_max_streams)`; the height
is the span plus the greatest successor height. The ideal (ASAP) anchor assumes
each parked plane j lands on the j-th nearest parking candidate and that install
waves run on consecutive cycles; it is informational (Program.report).
"""
from __future__ import annotations

from dataclasses import dataclass

from ..config import EAST, WEST, ChipConfig, OpTiming
from ..graph import ELEMENTWISE_BINARY
from .assign import VXM, unit_pos
from .chains import Chain
from .tiling import MATVEC, TOp, Tiled

TRANSCENDENTAL = ("exp", "rsqrt", "tanh")


def op_timing_key(op: TOp) -> str:
    if op.kind == MATVEC:
        return "MATVEC"
    if op.kind == "shift":
        return "SXM"
    return "VTRANS" if op.kind in TRANSCENDENTAL else "VARITH"


def flow_dir(x_from: int, x_to: int) -> str:
    """Direction a value must flow from x_from to reach x_to (East at distance 0)."""
    return WEST if x_to < x_from else EAST


@dataclass
class ChainTime:
    units: list[str]          # unit per member ("VXM" until an ALU is chosen)
    pos: list[int]
    keys: list[str]           # timing key per member
    sample: list[int]
    issue: list[int]
    vis: list[int]
    link_dir: list[str]       # link i -> i+1
    park_hemi: str
    park_dir: str
    park_slices: list[str]    # parking candidates in flow order from the producer


def timing(config: ChipConfig, key: str) -> OpTiming:
    return config.timing[key]


def hemisphere_slices(hemi: str, config: ChipConfig) -> list[str]:
    return [f"MEM_{hemi}{i}" for i in range(config.mem_slices_per_hemi)]


def park_plan(tg: Tiled, chain: Chain, units: list[str], config: ChipConfig) -> tuple[str, str, list[str]]:
    """Parking direction (plan 5.6): from the VXM toward the hemisphere of the value's
    first consumer (West if that consumer is at the VXM or the value is only an
    output); from an MXM or SXM, inward. All planes in one hemisphere."""
    last = chain.ops[-1]
    final = tg.ops[last].out
    x_prod = unit_pos(units[last], config)
    if units[last] == VXM:
        users = sorted(tg.consumers.get(final, []) + tg.row_users.get(final, []))
        hemi = WEST
        if users and units[users[0]] != VXM:
            hemi = config.hemi(units[users[0]])
        direction = hemi
    else:
        hemi = config.hemi(units[last])
        direction = EAST if hemi == WEST else WEST
    cands = sorted(hemisphere_slices(hemi, config), key=lambda s: abs(config.pos(s) - x_prod))
    return hemi, direction, cands


def chain_timing(tg: Tiled, chain: Chain, units: list[str], config: ChipConfig) -> ChainTime:
    us = [units[o] for o in chain.ops]
    pos = [unit_pos(u, config) for u in us]
    keys = [op_timing_key(tg.ops[o]) for o in chain.ops]
    sample, vis, link_dir = [0], [], []
    for i in range(len(chain.ops)):
        vis.append(sample[i] + timing(config, keys[i]).d_func)
        if i + 1 < len(chain.ops):
            link_dir.append(flow_dir(pos[i], pos[i + 1]))
            sample.append(vis[i] + abs(pos[i + 1] - pos[i]))
    issue = [s - timing(config, k).d_skew for s, k in zip(sample, keys)]
    hemi, pdir, cands = park_plan(tg, chain, units, config)
    return ChainTime(us, pos, keys, sample, issue, vis, link_dir, hemi, pdir, cands)


def read_sample_offset(ct: ChainTime, member: int, x_mem: int, config: ChipConfig) -> int:
    return ct.sample[member] - abs(ct.pos[member] - x_mem) - timing(config, "READ").d_func


def write_sample_offset(ct: ChainTime, x_mem: int) -> int:
    return ct.vis[-1] + abs(x_mem - ct.pos[-1])


def install_waves_estimate(tg: Tiled, op: TOp, config: ChipConfig) -> int:
    streams = len(op.rows) * op.in_dtype.nbytes
    return -(-streams // config.iw_max_streams)


def heights(tg: Tiled, chains: list[Chain], times: list[ChainTime], succ: list[list[int]],
            order: list[int], config: ChipConfig) -> list[int]:
    h = [0] * len(chains)
    for cid in reversed(order):
        ct = times[cid]
        span = ct.vis[-1] - min(ct.issue) + timing(config, "WRITE").d_func
        head = tg.ops[chains[cid].head]
        if head.kind == MATVEC:
            span += install_waves_estimate(tg, head, config) + timing(config, "IW").d_func
        h[cid] = span + max((h[s] for s in succ[cid]), default=0)
    return h


def ideal_anchors(tg: Tiled, chains: list[Chain], times: list[ChainTime], order: list[int],
                  chain_of: list[int], leaf_pos: dict[int, tuple[int, ...]], config: ChipConfig) -> list[int]:
    """ASAP anchors ignoring resources (see module docstring for the assumptions)."""
    t_r = timing(config, "READ")
    d_w = timing(config, "WRITE").d_func
    t_iw = timing(config, "IW")
    anchor = [0] * len(chains)
    write_abs: dict[int, list[int]] = {}      # vid -> ideal write sample per plane
    park_pos: dict[int, list[int]] = {}

    def plane_pos(v: int) -> list[int]:
        return list(leaf_pos[v]) if v in leaf_pos else park_pos[v]

    for cid in order:
        c, ct = chains[cid], times[cid]
        lb = -min(ct.issue)
        for (i, v) in c.mem_reads:
            for j, xm in enumerate(plane_pos(v)):
                rs = read_sample_offset(ct, i, xm, config)
                lb = max(lb, t_r.d_skew - rs)
                if v in write_abs:
                    lb = max(lb, write_abs[v][j] + d_w - rs)
        head = tg.ops[c.head]
        if head.kind == MATVEC:
            x_p = ct.pos[0]
            w0 = t_iw.d_skew
            for v in head.rows:
                for j, xm in enumerate(plane_pos(v)):
                    lead = abs(x_p - xm) + t_r.d_func
                    w0 = max(w0, lead + t_r.d_skew)
                    if v in write_abs:
                        w0 = max(w0, write_abs[v][j] + d_w + lead)
            waves = install_waves_estimate(tg, head, config)
            lb = max(lb, w0 + waves - 1 + t_iw.d_func)
        anchor[cid] = lb
        final = tg.ops[c.ops[-1]].out
        nb = tg.vals[final].dtype.nbytes
        park_pos[final] = [config.pos(s) for s in ct.park_slices[:nb]]
        write_abs[final] = [lb + write_sample_offset(ct, x) for x in park_pos[final]]
    return anchor


__all__ = ["ChainTime", "chain_timing", "read_sample_offset", "write_sample_offset", "heights",
           "ideal_anchors", "flow_dir", "park_plan", "op_timing_key", "ELEMENTWISE_BINARY"]
