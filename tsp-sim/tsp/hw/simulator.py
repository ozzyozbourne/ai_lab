"""The cycle loop of the whole chip (plan 2.3).

Every cycle runs four steps in a fixed order:

1. Shift: every value moves one position in its direction (ledger T1, B1).
2. Emit: results due this cycle are written into SR[dir][s][x] at the
   producing unit's own position, replacing what shifted in (ledger T3).
   Two results due in one register on one cycle is a StreamCollisionError.
3. Dispatch: units are visited in canonical order (config.units()); each
   queue yields at most one data instruction (ledger T16).  The unit samples
   its stream operands at its own position as they stand after step 2
   (ledger T4, B2), computes the result and files it as due at
   cycle + d_func, with d_func = config.latency[isa.kind_of(instr)].
4. Commit: a Write or Iw dispatched at t takes effect at the end of cycle
   t + d_func - 1 (ledger T7, T11).

So a result dispatched at cycle t on a unit at position x with latency d is
in SR[dir][s][x] at cycle t + d and then moves one position per cycle.

The run stops after the first cycle in which every queue is done and no
result or commit is pending (ledger B21).
"""

import numpy as np

from .. import isa
from ..errors import EmptyOperandError, OperandTagError, ProgramError, StreamCollisionError
from ..trace import Trace
from . import mxm, sxm, vxm
from .mem import Memory
from .streams import StreamFile, StreamVal

SXM_INSTRS = (isa.Distribute, isa.Permute, isa.Shift)


class Simulator:
    """Cycle-level model of one TSP chip running one Program."""

    def __init__(self, program, record_cells=True):
        self.program = program
        self.config = program.config
        self.record_cells = record_cells
        self.lanes = self.config.lanes
        self.streams = StreamFile(self.config.streams_per_dir, self.config.n_positions)
        self.mem = Memory(self.lanes, self.config.mem_words)
        for (unit, addr), data in sorted(program.mem_image.items()):  # constants (ledger B22)
            self.mem.write(unit, addr, data)
        self.planes = {
            u: mxm.MxmPlane(self.lanes, self.config.iw_max_streams)
            for u in self.config.units()
            if self.config.kind(u) == "MXM"
        }
        self._pending = {}   # cycle -> list of emissions due then
        self._commits = {}   # cycle -> list of commits due at the end of that cycle
        self._next_vid = 0
        self._ran = False
        self.trace = Trace(config=self.config.to_dict())

    # -- host interface ---------------------------------------------------------
    def poke(self, name, array):
        """Write input tensor `name` into MEM, zero-padded to `lanes` (ledger B22)."""
        if name not in self.program.inputs:
            raise KeyError(f"no input called {name!r}")
        loc = self.program.inputs[name]
        target = isa.np_dtype(loc.dtype)
        arr = np.asarray(array)
        if arr.dtype != target:
            if isinstance(array, np.ndarray):
                raise ValueError(f"input {name!r} must have dtype {target}, got {arr.dtype}")
            conv = arr.astype(target)
            if not np.array_equal(conv.astype(arr.dtype), arr):
                raise ValueError(f"input {name!r}: values are not representable as {loc.dtype}")
            arr = conv
        if arr.ndim != 1 or arr.shape[0] != loc.n:
            raise ValueError(f"input {name!r} must be a vector of length {loc.n}, got shape {arr.shape}")
        padded = np.zeros(self.lanes, dtype=target)
        padded[: loc.n] = arr
        for (unit, addr), plane in zip(loc.planes, isa.to_planes(padded, loc.dtype)):
            self.mem.write(unit, addr, plane)

    def peek(self, name):
        """Read tensor `name` (an output, or else an input) from MEM: length n, its dtype."""
        loc = self.program.outputs.get(name) or self.program.inputs.get(name)
        if loc is None:
            raise KeyError(f"no output or input called {name!r}")
        planes = [self.mem.read(unit, addr) for unit, addr in loc.planes]
        return isa.from_planes(planes, loc.dtype)[: loc.n]

    def run(self):
        """Execute the program to completion and return its Trace."""
        from .. import asm, icu  # written by the ISA agent; imported late so unit tests need not

        if self._ran:
            raise RuntimeError("a Simulator runs once; make a new one")
        self._ran = True
        asm.check_program(self.program)
        self._format = asm.format_instr
        queues = [
            (u, icu.InstructionQueue(u, self.program.queues[u], self.config))
            for u in self.config.units()
            if self.program.queues.get(u) is not None
        ]
        notify_cycle = None
        cycle = 0
        while True:
            self.streams.shift()
            self._emit(cycle)
            if self.record_cells:
                self._record_cells(cycle)
            release = None
            if notify_cycle is not None and cycle > notify_cycle:
                release = notify_cycle + self.config.barrier_cycles  # ledger: T15
            for unit, q in queues:
                instr = q.step(cycle, release)
                if q.notify_issued() and notify_cycle is None:
                    notify_cycle = cycle
                if instr is not None:
                    self._dispatch(cycle, unit, instr)
            self._commit(cycle)
            cycle += 1
            if all(q.done() for _, q in queues) and not self._pending and not self._commits:
                break
        self.trace.n_cycles = cycle
        self.trace.outputs = {name: self._output_hex(loc) for name, loc in self.program.outputs.items()}
        return self.trace

    # -- step 2: emit -------------------------------------------------------------
    def _emit(self, cycle):
        due = sorted(self._pending.pop(cycle, []), key=lambda e: (e["did"], e["s"]))
        seen = {}
        for e in due:
            key = (e["dir"], e["s"], e["pos"])
            if key in seen:
                raise StreamCollisionError(
                    f"cycle {cycle}: dispatches {seen[key]} and {e['did']} both emit into "
                    f"SR[{e['dir']}][{e['s']}][{e['pos']}]"
                )
            seen[key] = e["did"]
        for e in due:
            vid = self._next_vid
            self._next_vid += 1
            old = self.streams.put(e["dir"], e["s"], e["pos"], StreamVal(e["data"], vid, e["tag"]))
            self.trace.emissions.append({
                "cycle": cycle, "did": e["did"], "unit": e["unit"], "dir": e["dir"], "s": e["s"],
                "pos": e["pos"], "vid": vid, "tag": e["tag"], "overwrote": None if old is None else old.vid,
            })
            self.trace.values[str(vid)] = {"tag": e["tag"], "unit": e["unit"], "did": e["did"], "cycle": cycle}

    def _record_cells(self, cycle):
        for d, s, x, val in self.streams.occupied():
            self.trace.cells.append([cycle, d, s, x, val.vid])

    # -- step 3: dispatch -----------------------------------------------------------
    def _dispatch(self, cycle, unit, instr):
        """Sample operands, compute, and file the result or commit."""
        cfg = self.config
        kind = isa.kind_of(instr)
        lat = cfg.latency[kind]
        if lat < 1:
            raise ProgramError(f"latency of {kind!r} must be at least one cycle")
        did = len(self.trace.dispatches)
        pos = cfg.pos(unit)
        record = {"did": did, "cycle": cycle, "unit": unit, "pos": pos, "kind": kind,
                  "text": self._format(instr), "reads": []}
        operands = self._sample(instr, unit, pos, record["reads"])
        self.trace.dispatches.append(record)

        if isinstance(instr, isa.Read):
            data = self.mem.read(unit, instr.addr)
            self._file(cycle + lat, did, unit, pos, instr.out, [data], lambda j: instr.tag)
        elif isinstance(instr, isa.Write):
            plane = operands[0][0]
            tag = self.streams.get(instr.src.dir, instr.src.s, pos).tag
            self._file_commit(cycle + lat - 1, did, ("write", unit, instr.addr, plane, tag))
        elif isinstance(instr, isa.Vxm):
            values = [isa.from_planes(p, instr.dtype) for p in operands]
            result = vxm.compute(instr, values, self.lanes)
            self._file_result(cycle + lat, did, unit, pos, instr, isa.to_planes(result, vxm.result_dtype(instr)))
        elif isinstance(instr, isa.Iw):
            rows = [(row, isa.from_planes(p, instr.dtype)) for (row, _), p in zip(instr.entries, operands)]
            self._file_commit(cycle + lat - 1, did, ("iw", unit, instr.dtype, rows))
        elif isinstance(instr, isa.Abc):
            x = isa.from_planes(operands[0], instr.dtype)
            result = self.planes[unit].abc(instr.dtype, x, instr.n_rows)
            self._file_result(cycle + lat, did, unit, pos, instr, isa.to_planes(result, instr.result_dtype()))
        elif isinstance(instr, SXM_INSTRS):
            planes = sxm.compute(instr, operands[0], self.lanes, cfg.lanes_per_superlane)
            self._file_result(cycle + lat, did, unit, pos, instr, planes)
        else:
            raise ProgramError(f"{unit}: cannot dispatch {instr!r}")

    def _operand_specs(self, instr, unit):
        """Stream operands in operand order, as (StreamRef, number of planes)."""
        if isinstance(instr, isa.Read):
            return []
        if isinstance(instr, isa.Write):
            return [(instr.src, isa.width("int8"))]
        if isinstance(instr, isa.Vxm):
            vxm.result_dtype(instr)
            return [(ref, isa.width(instr.dtype)) for ref in vxm.operand_refs(instr)]
        if isinstance(instr, isa.Iw):
            if unit not in self.planes:
                raise ProgramError(f"{unit}: Iw needs an MXM plane")
            self.planes[unit].check_iw(instr)
            return [(ref, isa.width(instr.dtype)) for _, ref in instr.entries]
        if isinstance(instr, isa.Abc):
            return [(instr.src, isa.width(instr.dtype))]
        if isinstance(instr, SXM_INSTRS):
            return [(instr.src, instr.width)]
        raise ProgramError(f"cannot dispatch {instr!r}")

    def _expected_tag(self, instr, i, j):
        """Tag that plane j of operand i must carry, or None to skip the check."""
        if not instr.expect:
            return None
        if isinstance(instr, isa.Write):
            return instr.expect[0]
        return isa.plane_tag(instr.expect[i], j)

    def _sample(self, instr, unit, pos, reads):
        """Read the operand planes at this unit's position; check emptiness and tags.

        Returns one list of uint8 planes per operand.  Each register sampled is
        recorded once in `reads`, in operand then plane order (so op(a, a)
        records a's registers once).
        """
        specs = self._operand_specs(instr, unit)
        expect = getattr(instr, "expect", ())
        if expect and len(expect) != len(specs):
            raise ProgramError(f"{unit}: expect has {len(expect)} names for {len(specs)} operands")
        seen = []
        out = []
        for i, (ref, w) in enumerate(specs):
            planes = []
            for j in range(w):
                s = ref.s + j
                if not 0 <= s < self.config.streams_per_dir:
                    raise ProgramError(f"{unit}: stream {s} out of range")
                val = self.streams.get(ref.dir, s, pos)
                if val is None:
                    raise EmptyOperandError(f"{unit}: SR[{ref.dir}][{s}][{pos}] is empty")
                want = self._expected_tag(instr, i, j)
                if want is not None and val.tag != want:
                    raise OperandTagError(
                        f"{unit}: SR[{ref.dir}][{s}][{pos}] holds {val.tag!r}, expected {want!r}"
                    )
                if (ref.dir, s) not in seen:
                    seen.append((ref.dir, s))
                    reads.append({"dir": ref.dir, "s": s, "pos": pos, "vid": val.vid, "tag": val.tag})
                planes.append(val.data)
            out.append(planes)
        return out

    def _file_result(self, due, did, unit, pos, instr, planes):
        self._file(due, did, unit, pos, instr.out, planes, lambda j: isa.plane_tag(instr.tag, j))

    def _file(self, due, did, unit, pos, out, planes, tag_of):
        for j, data in enumerate(planes):
            s = out.s + j
            if not 0 <= s < self.config.streams_per_dir:
                raise ProgramError(f"{unit}: result stream {s} out of range")
            self._pending.setdefault(due, []).append({
                "did": did, "unit": unit, "dir": out.dir, "s": s, "pos": pos,
                "data": np.asarray(data, dtype=np.uint8).copy(), "tag": tag_of(j),
            })

    def _file_commit(self, due, did, action):
        self._commits.setdefault(due, []).append((did, action))

    # -- step 4: commit ---------------------------------------------------------------
    def _commit(self, cycle):
        for did, action in sorted(self._commits.pop(cycle, []), key=lambda c: c[0]):
            if action[0] == "write":
                _, unit, addr, plane, tag = action
                self.mem.write(unit, addr, plane)
                self.trace.mem_writes.append({"cycle": cycle, "did": did, "unit": unit, "addr": addr, "tag": tag})
            else:
                _, unit, dtype, rows = action
                self.planes[unit].install(dtype, rows)

    def _output_hex(self, loc):
        return "".join(self.mem.read(unit, addr).tobytes().hex() for unit, addr in loc.planes)
