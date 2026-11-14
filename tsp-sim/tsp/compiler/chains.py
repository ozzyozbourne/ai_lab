"""Pass 4 (plan 5.4): chain formation.

A chain is a list of tile operations executed as one rigid pattern: the result
of each member flows on a stream straight into the next member (a "link"). Every
other operand is read from memory, and the chain's final value is parked.

Output data structure (`Chain`):
- `ops`: op ids in execution order;
- `linked[i]`: per operand slot of `ops[i]`, True when that slot takes the
  previous member's result from a stream (both slots for `r * r`);
- `mem_reads`: (member index, vid) of every memory-sourced operand, in member
  order then operand order, one entry per distinct value per member (an operation
  that uses one stored value in both slots reads it once and samples it twice);
- `rows`: (member index, row vids) of the MATVEC install, if the chain starts
  with a MATVEC;
- `preds`: chain ids that park a value this chain reads (operands or install rows).
"""
from __future__ import annotations

from dataclasses import dataclass, field

from .errors import CompileError
from .tiling import MATVEC, Tiled


@dataclass
class Chain:
    cid: int
    ops: list[int] = field(default_factory=list)
    linked: list[tuple[bool, ...]] = field(default_factory=list)
    mem_reads: list[tuple[int, int]] = field(default_factory=list)
    preds: list[int] = field(default_factory=list)

    @property
    def head(self) -> int:
        return self.ops[0]


def linkable(tg: Tiled, vid: int) -> bool:
    """Rule 2: the value has exactly one consumer operation, is not a graph output,
    and is not used as an install row."""
    return (len(tg.consumers.get(vid, [])) == 1 and not tg.is_output.get(vid, False)
            and vid not in tg.row_users)


def form_chains(tg: Tiled) -> tuple[list[Chain], list[int]]:
    """Returns the chains (ids in creation order) and chain_of_op[oid]."""
    chains: list[Chain] = []
    chain_of: list[int] = []
    for op in tg.ops:
        target, link_vid = None, None
        if op.kind != MATVEC:                     # rule 1: a MATVEC always starts a chain
            for v in dict.fromkeys(op.operands):  # rule 2: first qualifying computed operand
                p = tg.vals[v].producer
                if p is None or not linkable(tg, v):
                    continue
                c = chains[chain_of[p]]
                if c.ops[-1] == p:
                    target, link_vid = c, v
                    break
        if target is None:
            target = Chain(len(chains))
            chains.append(target)
        target.ops.append(op.oid)
        target.linked.append(tuple(v == link_vid for v in op.operands))
        chain_of.append(target.cid)

    for c in chains:
        preds: dict[int, bool] = {}
        for i, oid in enumerate(c.ops):
            op = tg.ops[oid]
            for slot, v in enumerate(op.operands):
                if c.linked[i][slot] or (i, v) in c.mem_reads:
                    continue
                c.mem_reads.append((i, v))
            for v in [v for (j, v) in c.mem_reads if j == i] + list(op.rows):
                p = tg.vals[v].producer
                if p is not None:
                    preds[chain_of[p]] = True
        c.preds = sorted(preds)
        final = tg.ops[c.ops[-1]].out
        if not tg.consumers.get(final) and not tg.is_output.get(final) and final not in tg.row_users:
            raise CompileError(f"chain {c.cid}: final value {tg.vals[final].prefix} is never used")
    return chains, chain_of


def topo_order(chains: list[Chain]) -> list[int]:
    """Chain ids in an order that respects `preds` (Kahn, lowest id first)."""
    done = [False] * len(chains)
    order: list[int] = []
    while len(order) < len(chains):
        for c in chains:
            if not done[c.cid] and all(done[p] for p in c.preds):
                done[c.cid] = True
                order.append(c.cid)
                break
        else:
            raise CompileError("chain predecessor relation has a cycle")
    return order


def successors(chains: list[Chain]) -> list[list[int]]:
    succ: list[list[int]] = [[] for _ in chains]
    for c in chains:
        for p in c.preds:
            succ[p].append(c.cid)
    return succ
