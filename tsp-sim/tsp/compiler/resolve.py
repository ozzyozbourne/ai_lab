"""Pass 6 (plan 5.6): conflict resolution — reservation tables and the scheduling loop.

Reservation tables (`Tables`):
- queue slots  (unit, issue cycle) -> kinds issued ("R"/"W" on MEM, "X" elsewhere);
  at most `issue_width(unit)` entries, and on MEM at most one Read and one Write;
- memory ports (slice, sample cycle) -> [read bank, write bank]; one Read and one
  Write per slice per sample cycle, on different banks (L-M4, L-M5);
- stream cells (dir, stream, diagonal) -> live position intervals [lo, hi],
  diagonal = t - x eastward, t + x westward. A flight is live from the position
  where it is driven to the position of its last sampler, inclusive; two flights
  conflict iff they share a key and their intervals overlap. Dead tails are free;
- MXM planes: `lock_end[unit]` = MATVEC sample cycle of the last matvec scheduled
  on the plane; the next install starts strictly after it. Chains are scheduled
  one at a time, so a plane's lock intervals never interleave. F16 work only ever
  goes to plane .0 (assign.py), so plane .1 of a hemisphere stays idle (L-X9);
- memory words: bump pointers in placement.Memory.

Every reservation is logged; a failed attempt is rolled back to its mark.

Scheduling loop: among chains whose predecessors are scheduled, take the one with
the greatest height (ties: lowest head node id, then lowest chain id). Then
1. MATVEC head: install rows packed greedily in row order into waves (at most
   iw_max_streams streams, no two planes in one slice); each wave goes at the
   earliest sample cycle after the previous wave, after the plane's lock end,
   after every computed row's Write + d_func(WRITE), where all its cells, ports
   and queue slots are free;
2. anchors t0 = lb, lb+1, ...; per anchor the reservations are made in the fixed
   order units -> parking slices -> streams (operand reads, links, final value);
   any failure releases the attempt and tries t0+1 (the conflict ladder);
3. every search is bounded by config.max_schedule_cycles -> CompileError naming
   the chain and the resource that failed last.

Before searching, the chain is tried once at its lower bound against EMPTY tables
(the "no self-conflict" assertion). If that fails, no later anchor can succeed,
so it is a CompileError, not a search. Otherwise a late enough anchor finds every
earlier reservation drained and succeeds in the same way, so the search ends.
Policy where the plan is open: a parking candidate is statically excluded (for
every anchor) when it breaks the co-read / same-cycle-read rule of placement.py,
when its bank 1 is full, or when the chain itself reads bank 1 of that slice in
the Write's sample cycle.
"""
from __future__ import annotations

from dataclasses import dataclass, field

from ..config import EAST, ChipConfig
from ..isa import IW, Instr, MatVec, Read, Shift, SRef, VOp, Write, plane_tags
from ..program import PlaneLoc
from .assign import VXM
from .chains import Chain
from .errors import CompileError
from .placement import PARK_BANK, Memory, ReadMarks
from .timetable import ChainTime, flow_dir, read_sample_offset, timing, write_sample_offset
from .tiling import MATVEC, TOp, Tiled


@dataclass(frozen=True)
class Placed:
    unit: str
    issue: int
    sample: int
    instr: Instr


class Tables:
    def __init__(self, config: ChipConfig):
        self.config = config
        self.slots: dict[tuple[str, int], list[str]] = {}
        self.ports: dict[tuple[str, int], list] = {}
        self.cells: dict[tuple[str, int, int], list[tuple[int, int]]] = {}
        self.log: list[tuple[str, tuple]] = []

    # -- undo log ---------------------------------------------------------------
    def mark(self) -> int:
        return len(self.log)

    def rollback(self, m: int) -> None:
        while len(self.log) > m:
            table, key = self.log.pop()
            if table == "slot":
                self.slots[key].pop()
            elif table == "cell":
                self.cells[key].pop()
            else:                      # ("read" | "write", key)
                self.ports[key][0 if table == "read" else 1] = None

    # -- queue slots ------------------------------------------------------------
    def slot_free(self, unit: str, cycle: int, kind: str) -> bool:
        used = self.slots.get((unit, cycle), [])
        if len(used) >= self.config.issue_width(unit):
            return False
        return not (self.config.kind(unit) == "MEM" and kind in used)

    def take_slot(self, unit: str, cycle: int, kind: str) -> None:
        self.slots.setdefault((unit, cycle), []).append(kind)
        self.log.append(("slot", (unit, cycle)))

    # -- memory ports -------------------------------------------------------------
    def read_free(self, slice_name: str, cycle: int, bank: int) -> bool:
        p = self.ports.get((slice_name, cycle))
        return p is None or (p[0] is None and p[1] != bank)

    def write_free(self, slice_name: str, cycle: int, bank: int) -> bool:
        p = self.ports.get((slice_name, cycle))
        return p is None or (p[1] is None and p[0] != bank)

    def take_port(self, which: str, slice_name: str, cycle: int, bank: int) -> None:
        p = self.ports.setdefault((slice_name, cycle), [None, None])
        p[0 if which == "read" else 1] = bank
        self.log.append((which, (slice_name, cycle)))

    # -- stream cells -------------------------------------------------------------
    @staticmethod
    def flight_key(d: str, stream: int, x_drive: int, t_vis: int) -> tuple[str, int, int]:
        return (d, stream, t_vis - x_drive if d == EAST else t_vis + x_drive)

    def flight_free(self, d: str, stream: int, flight: tuple[int, int, int]) -> bool:
        x_drive, t_vis, x_last = flight
        lo, hi = min(x_drive, x_last), max(x_drive, x_last)
        for a, b in self.cells.get(self.flight_key(d, stream, x_drive, t_vis), []):
            if a <= hi and lo <= b:
                return False
        return True

    def take_flight(self, d: str, stream: int, flight: tuple[int, int, int]) -> None:
        x_drive, t_vis, x_last = flight
        key = self.flight_key(d, stream, x_drive, t_vis)
        self.cells.setdefault(key, []).append((min(x_drive, x_last), max(x_drive, x_last)))
        self.log.append(("cell", key))

    def find_group(self, d: str, flights: list[tuple[int, int, int]], counter: dict) -> int | None:
        """Lowest aligned base stream whose plane j can carry flights[j]; reserves it."""
        nb = len(flights)
        for base in range(0, self.config.streams_per_dir - nb + 1, nb):   # alignment == width (L-G8)
            if all(self.flight_free(d, base + j, f) for j, f in enumerate(flights)):
                for j, f in enumerate(flights):
                    self.take_flight(d, base + j, f)
                return base
            counter["streams"] += 1
        return None


class Fail(Exception):
    """One attempt failed; `args[0]` names the resource."""


@dataclass
class Scheduler:
    tg: Tiled
    chains: list[Chain]
    times: list[ChainTime]
    mem: Memory
    marks: ReadMarks
    config: ChipConfig
    tables: Tables = None
    lock_end: dict[str, int] = field(default_factory=dict)
    write_sample: dict[int, list[int]] = field(default_factory=dict)
    placed: list[Placed] = field(default_factory=list)

    def __post_init__(self):
        self.tables = Tables(self.config)
        self.t_read = timing(self.config, "READ")
        self.t_write = timing(self.config, "WRITE")
        self.t_iw = timing(self.config, "IW")
        if self.config.iw_max_streams > self.config.streams_per_dir:
            raise CompileError("iw_max_streams exceeds streams_per_dir")

    # ---- helpers ------------------------------------------------------------------
    def name(self, cid: int) -> str:
        c = self.chains[cid]
        return f"chain {cid} ({', '.join(self.tg.vals[self.tg.ops[o].out].prefix for o in c.ops)})"

    def parked_ok(self, vid: int, j: int, read_sample: int) -> bool:
        ws = self.write_sample.get(vid)
        return ws is None or read_sample >= ws[j] + self.t_write.d_func

    # ---- step 1: weight install -------------------------------------------------------
    def pack_waves(self, op: TOp) -> list[list[tuple[int, int]]]:
        nb = op.in_dtype.nbytes
        if nb > self.config.iw_max_streams:
            raise CompileError(f"a {op.in_dtype.value} row needs more than iw_max_streams streams")
        waves, cur, used, streams = [], [], {}, 0
        for r, v in enumerate(op.rows):
            slices = [p.slice for p in self.mem.loc[v]]
            if cur and (streams + nb > self.config.iw_max_streams or any(s in used for s in slices)):
                waves.append(cur)
                cur, used, streams = [], {}, 0
            cur.append((r, v))
            streams += nb
            for s in slices:
                used[s] = True
        waves.append(cur)
        return waves

    def install(self, cid: int, rec: dict) -> int:
        """Schedules every install wave of the chain's MATVEC; returns the last wave's sample cycle."""
        op = self.tg.ops[self.chains[cid].head]
        unit = self.times[cid].units[0]
        x_p = self.config.pos(unit)
        dtype = op.in_dtype
        prev = self.lock_end.get(unit, -1)
        for wave in self.pack_waves(op):
            lb = max(prev + 1, self.t_iw.d_skew)
            for (r, v) in wave:
                for j, p in enumerate(self.mem.loc[v]):
                    lead = abs(x_p - self.config.pos(p.slice)) + self.t_read.d_func
                    lb = max(lb, lead + self.t_read.d_skew)
                    if v in self.write_sample:
                        lb = max(lb, self.write_sample[v][j] + self.t_write.d_func + lead)
            last = "nothing"
            for w in range(lb, self.config.max_schedule_cycles + 1):
                m = self.tables.mark()
                try:
                    out = self.try_wave(op, unit, x_p, wave, w, rec["rejected"])
                except Fail as e:
                    self.tables.rollback(m)
                    rec["rejected"]["install_cycles"] += 1
                    last = e.args[0]
                    continue
                self.placed.extend(out)
                rec["install_waves"].append(w)
                prev = w
                break
            else:
                raise CompileError(f"{self.name(cid)}: no install wave sample cycle <= "
                                   f"max_schedule_cycles (L-K7); last conflict: {last}")
        return prev

    def try_wave(self, op: TOp, unit: str, x_p: int, wave, w: int, counter: dict) -> list[Placed]:
        tb, cfg = self.tables, self.config
        iw_issue = w - self.t_iw.d_skew
        if not tb.slot_free(unit, iw_issue, "X"):
            raise Fail(f"{unit} queue at {iw_issue}")
        tb.take_slot(unit, iw_issue, "X")
        rows, out = [], []
        for (r, v) in wave:
            val = self.tg.vals[v]
            planes = self.mem.loc[v]
            d = flow_dir(cfg.pos(planes[0].slice), x_p)
            flights, reads = [], []
            for j, p in enumerate(planes):
                xm = cfg.pos(p.slice)
                rs = w - abs(x_p - xm) - self.t_read.d_func
                self.reserve_read(p, rs, v, j)
                flights.append((xm, rs + self.t_read.d_func, x_p))
                reads.append((p, rs))
            base = tb.find_group(d, flights, counter)
            if base is None:
                raise Fail(f"stream group for install row {r} ({val.prefix})")
            rows.append((r, SRef(d, base, plane_tags(val.prefix, val.dtype))))
            for j, (p, rs) in enumerate(reads):
                out.append(Placed(p.slice, rs - self.t_read.d_skew, rs,
                                  Read(p.bank, p.addr, SRef(d, base + j, (f"{val.prefix}#{j}",)))))
        out.append(Placed(unit, iw_issue, w, IW(op.in_dtype, tuple(rows))))
        return out

    def reserve_read(self, p: PlaneLoc, rs: int, vid: int, j: int) -> None:
        tb = self.tables
        ri = rs - self.t_read.d_skew
        if ri < 0:
            raise Fail("read issue cycle < 0")
        if not self.parked_ok(vid, j, rs):
            raise Fail(f"{self.tg.vals[vid].prefix} not yet written")
        if not tb.read_free(p.slice, rs, p.bank):
            raise Fail(f"{p.slice} read port at {rs}")
        if not tb.slot_free(p.slice, ri, "R"):
            raise Fail(f"{p.slice} queue at {ri}")
        tb.take_port("read", p.slice, rs, p.bank)
        tb.take_slot(p.slice, ri, "R")

    # ---- step 2: anchor search -------------------------------------------------------------
    def park_candidates(self, cid: int) -> list[str]:
        """Parking slices allowed at every anchor, in flow order (see module docstring)."""
        ct = self.times[cid]
        final = self.tg.ops[self.chains[cid].ops[-1]].out
        nb = self.tg.vals[final].dtype.nbytes
        own = self.marks.marks[cid]
        ok, why = [], []
        for s in ct.park_slices:
            wo = write_sample_offset(ct, self.config.pos(s))
            reason = self.marks.blocked(final, s, self.mem)
            if reason is None and self.mem.peek(s, PARK_BANK) is None:
                reason = "bank 1 full"
            if reason is None and own.get((s, wo), (None, None))[1] == PARK_BANK:
                reason = "chain reads bank 1 there in the same cycle"
            if reason is None:
                ok.append(s)
            else:
                why.append(f"{s}: {reason}")
        if len(ok) < nb:
            raise CompileError(f"{self.name(cid)}: cannot park {nb} planes in hemisphere {ct.park_hemi}: "
                               + "; ".join(why))
        return ok

    def lower_bound(self, cid: int, cands: list[str], last_wave: int | None) -> int:
        c, ct, cfg = self.chains[cid], self.times[cid], self.config
        lb = -min(ct.issue)
        for (i, v) in c.mem_reads:
            for j, p in enumerate(self.mem.loc[v]):
                rs = read_sample_offset(ct, i, cfg.pos(p.slice), cfg)
                lb = max(lb, self.t_read.d_skew - rs)
                if v in self.write_sample:
                    lb = max(lb, self.write_sample[v][j] + self.t_write.d_func - rs)
        for s in cands:
            lb = max(lb, self.t_write.d_skew - write_sample_offset(ct, cfg.pos(s)))
        if last_wave is not None:
            lb = max(lb, last_wave + self.t_iw.d_func)
        return lb

    def attempt(self, cid: int, t0: int, cands: list[str], counter: dict) -> tuple[list[Placed], list]:
        """Reserves everything the chain needs at anchor t0, or raises Fail."""
        c, ct, cfg, tb, tg = self.chains[cid], self.times[cid], self.config, self.tables, self.tg
        n = len(c.ops)
        # units
        units = []
        for i in range(n):
            iss = t0 + ct.issue[i]
            if iss < 0:
                raise Fail("issue cycle < 0")
            if ct.units[i] == VXM:
                for a in range(cfg.n_alus):
                    u = f"VXM.{a}"
                    if tb.slot_free(u, iss, "X"):
                        break
                    counter["alus"] += 1
                else:
                    raise Fail(f"no VXM ALU free at {iss}")
            else:
                u = ct.units[i]
                if not tb.slot_free(u, iss, "X"):
                    raise Fail(f"{u} queue at {iss}")
            tb.take_slot(u, iss, "X")
            units.append(u)
        # parking slices
        final = tg.vals[tg.ops[c.ops[-1]].out]
        nb = final.dtype.nbytes
        park, nxt = [], 0
        for j in range(nb):
            while nxt < len(cands):
                s = cands[nxt]
                nxt += 1
                ws = t0 + write_sample_offset(ct, cfg.pos(s))
                wi = ws - self.t_write.d_skew
                if wi >= 0 and tb.write_free(s, ws, PARK_BANK) and tb.slot_free(s, wi, "W"):
                    tb.take_port("write", s, ws, PARK_BANK)
                    tb.take_slot(s, wi, "W")
                    park.append((s, ws))
                    break
                counter["slices"] += 1
            else:
                raise Fail(f"parking slice for plane {j} of {final.prefix}")
        # streams: operand reads
        groups: dict[tuple[int, int], tuple[str, int]] = {}
        reads = []
        for (i, v) in c.mem_reads:
            val = tg.vals[v]
            planes = self.mem.loc[v]
            d = flow_dir(cfg.pos(planes[0].slice), ct.pos[i])
            flights, mine = [], []
            for j, p in enumerate(planes):
                xm = cfg.pos(p.slice)
                if flow_dir(xm, ct.pos[i]) != d:
                    raise CompileError(f"planes of {val.prefix} lie on both sides of {ct.units[i]}")
                rs = t0 + read_sample_offset(ct, i, xm, cfg)
                self.reserve_read(p, rs, v, j)
                flights.append((xm, rs + self.t_read.d_func, ct.pos[i]))
                mine.append((p, rs))
            base = tb.find_group(d, flights, counter)
            if base is None:
                raise Fail(f"stream group for operand {val.prefix}")
            groups[(i, v)] = (d, base)
            for j, (p, rs) in enumerate(mine):
                reads.append(Placed(p.slice, rs - self.t_read.d_skew, rs,
                                    Read(p.bank, p.addr, SRef(d, base + j, (f"{val.prefix}#{j}",)))))
        # streams: links
        links = []
        for i in range(n - 1):
            nbi = tg.ops[c.ops[i]].dtype.nbytes
            f = (ct.pos[i], t0 + ct.vis[i], ct.pos[i + 1])
            base = tb.find_group(ct.link_dir[i], [f] * nbi, counter)
            if base is None:
                raise Fail(f"stream group for link {tg.vals[tg.ops[c.ops[i]].out].prefix}")
            links.append((ct.link_dir[i], base))
        # streams: final value
        flights = [(ct.pos[-1], t0 + ct.vis[-1], cfg.pos(s)) for s, _ in park]
        fbase = tb.find_group(ct.park_dir, flights, counter)
        if fbase is None:
            raise Fail(f"stream group for final value {final.prefix}")

        # build the instructions
        out = list(reads)
        for i, oid in enumerate(c.ops):
            op = tg.ops[oid]
            srefs = []
            for slot, v in enumerate(op.operands):
                val = tg.vals[v]
                d, base = links[i - 1] if c.linked[i][slot] else groups[(i, v)]
                srefs.append(SRef(d, base, plane_tags(val.prefix, val.dtype)))
            d, base = links[i] if i < n - 1 else (ct.park_dir, fbase)
            res = SRef(d, base, plane_tags(tg.vals[op.out].prefix, op.dtype))
            out.append(Placed(units[i], t0 + ct.issue[i], t0 + ct.sample[i], make_instr(tg, op, srefs, res)))
        writes = []
        for j, (s, ws) in enumerate(park):
            writes.append((s, ws))
            out.append(Placed(s, ws - self.t_write.d_skew, ws,
                              Write(PARK_BANK, self.mem.peek(s, PARK_BANK),
                                    SRef(ct.park_dir, fbase + j, (f"{final.prefix}#{j}",)))))
        return out, writes

    def schedule_chain(self, cid: int, ideal: int) -> dict:
        c, ct = self.chains[cid], self.times[cid]
        rec = {"chain": cid,
               "nodes": list(dict.fromkeys(self.tg.node_names[self.tg.ops[o].node] for o in c.ops)),
               "ops": [self.tg.vals[self.tg.ops[o].out].prefix for o in c.ops],
               "ideal_anchor": ideal, "anchor": None, "install_waves": [],
               "rejected": {"alus": 0, "slices": 0, "streams": 0, "anchors": 0, "install_cycles": 0}}
        head = self.tg.ops[c.head]
        last_wave = self.install(cid, rec) if head.kind == MATVEC else None
        cands = self.park_candidates(cid)
        lb = self.lower_bound(cid, cands, last_wave)

        # no-self-conflict assertion: the chain alone, on empty tables
        real = self.tables
        self.tables = Tables(self.config)
        try:
            self.attempt(cid, lb, cands, {"alus": 0, "slices": 0, "streams": 0})
        except Fail as e:
            raise CompileError(f"{self.name(cid)} conflicts with itself ({e.args[0]}); "
                               "a later anchor cannot help") from None
        finally:
            self.tables = real

        last = "nothing"
        for t0 in range(lb, self.config.max_schedule_cycles + 1):
            m = self.tables.mark()
            try:
                out, writes = self.attempt(cid, t0, cands, rec["rejected"])
            except Fail as e:
                self.tables.rollback(m)
                rec["rejected"]["anchors"] += 1
                last = e.args[0]
                continue
            break
        else:
            raise CompileError(f"{self.name(cid)}: no anchor <= max_schedule_cycles (L-K7); "
                               f"last conflict: {last}")
        # commit
        self.placed.extend(out)
        final = self.tg.ops[c.ops[-1]].out
        planes = tuple(PlaneLoc(s, PARK_BANK, self.mem.alloc(s, PARK_BANK)) for s, _ in writes)
        assert [p.addr for p in planes] == [w.instr.addr for w in out if isinstance(w.instr, Write)]
        self.mem.loc[final] = planes
        self.marks.record(final, planes)
        self.write_sample[final] = [ws for _, ws in writes]
        if head.kind == MATVEC:
            self.lock_end[ct.units[0]] = t0
        rec["anchor"] = t0
        rec["units"] = [p.unit for p in out if not isinstance(p.instr, (Read, Write))]
        rec["park"] = [p.slice for p in planes]
        return rec


def make_instr(tg: Tiled, op: TOp, srefs: list[SRef], res: SRef) -> Instr:
    a = srefs[0]
    if op.kind == MATVEC:
        return MatVec(op.in_dtype, len(op.rows), a, res, tuple(f"{tg.vals[r].prefix}#0" for r in op.rows))
    if op.kind == "shift":
        return Shift(op.imm, a, res)
    b = srefs[1] if len(srefs) > 1 else None
    if op.kind == "requant":
        return VOp("REQUANT", op.in_dtype, a, None, res, imm=op.imm)
    if op.kind == "cast":
        return VOp("CAST", op.in_dtype, a, None, res, to=op.dtype)
    return VOp(op.kind.upper(), op.in_dtype, a, b, res)


def run_schedule(sched: Scheduler, heights: list[int], ideal: list[int]) -> list[dict]:
    """The list-scheduling loop; returns the per-chain report in scheduling order."""
    chains = sched.chains
    done = [False] * len(chains)
    report = []
    for _ in chains:
        ready = [c for c in chains if not done[c.cid] and all(done[p] for p in c.preds)]
        if not ready:
            raise CompileError("no chain is ready (predecessor cycle)")
        best = min(ready, key=lambda c: (-heights[c.cid], sched.tg.ops[c.head].node, c.cid))
        rec = sched.schedule_chain(best.cid, ideal[best.cid])
        rec["height"] = heights[best.cid]
        report.append(rec)
        done[best.cid] = True
    return report
