"""Instruction queue (ICU) of one unit: turns a queue into per-cycle dispatches.

Timing follows plan.md section 2.6:

| Element                               | Cycles occupied        | Dispatches                           |
|---------------------------------------|------------------------|--------------------------------------|
| Sync or Notify (first element only)   | 0 .. T15 - 1           | none                                 |
| data instruction                      | 1                      | on that cycle                        |
| Nop(n)                                | n                      | none                                 |
| Repeat(n, d)                          | n * d                  | previous data instruction, on the    |
|                                       |                        | last cycle of each block of d        |

Ledger IDs: T14 (Nop count), T15 (barrier length, config.barrier_cycles),
T16 (at most one dispatch per queue per cycle), T18 (Repeat timing),
B14 (one Notify queue, dispatched at cycle 0; every other queue starts with Sync).

asm.dispatch_times is an independent static implementation of the same table;
the tests check that the two agree cycle for cycle.
"""

from . import isa
from .errors import ProgramError


class InstructionQueue:
    """The queue of one unit, consumed strictly in order, one element at a time.

    Call step(cycle, barrier_release) exactly once per cycle with
    cycle = 0, 1, 2, ...  It returns the data instruction dispatched on that
    cycle, or None (T16: at most one per cycle).  It never returns Sync,
    Notify, Nop or Repeat.
    """

    def __init__(self, unit, instrs, config):
        self.unit = unit
        self.instrs = list(instrs)
        self.config = config
        self._idx = 0                # index of the next element to start
        self._next_start = 0         # cycle at which element _idx starts
        self._parked = False         # waiting on Sync for the barrier release
        self._pending = []           # [(cycle, instr)] dispatches of the current element, ascending
        self._last_data = None       # data instruction a Repeat would re-dispatch
        self._notified = False       # Notify dispatched on the last stepped cycle
        self._last_cycle = None      # last cycle passed to step()

    # -- per-cycle interface ---------------------------------------------------
    def step(self, cycle, barrier_release):
        """Advance to `cycle` and return the data instruction dispatched on it, or None.

        barrier_release is the cycle at which the Sync barrier opens, or None
        while no Notify has been dispatched yet (T15, B14).  A queue parked on
        Sync starts its next element at that cycle (or at the current cycle,
        if the release is reported late).
        """
        expected = 0 if self._last_cycle is None else self._last_cycle + 1
        if cycle != expected:
            raise ValueError(f"{self.unit}: step({cycle}) called, expected step({expected})")
        self._last_cycle = cycle
        self._notified = False

        if self._parked and barrier_release is not None:
            self._parked = False
            self._next_start = max(barrier_release, cycle)

        # Start every element whose first cycle is now.  Each element occupies
        # at least one cycle except a Notify with a zero-length barrier, so
        # this loop normally runs at most once.
        while not self._parked and self._idx < len(self.instrs) and self._next_start <= cycle:
            self._start_element(self.instrs[self._idx], cycle)
            self._idx += 1

        if self._pending and self._pending[0][0] == cycle:
            return self._pending.pop(0)[1]
        return None

    def _start_element(self, instr, cycle):
        first = self._idx == 0
        if isinstance(instr, (isa.Sync, isa.Notify)):
            if not first:
                raise ProgramError(f"{self.unit}: {type(instr).__name__} at position {self._idx}; only allowed first")
            if isinstance(instr, isa.Notify):
                # B14: Notify is dispatched on its first cycle; the barrier opens
                # T15 cycles later, for this queue too.
                self._notified = True
                self._next_start = cycle + self.config.barrier_cycles
            else:
                self._parked = True
            return
        if isinstance(instr, isa.Nop):
            # T14: Nop(n) occupies n cycles and dispatches nothing.  It also
            # breaks the link between a data instruction and a later Repeat.
            self._last_data = None
            self._next_start = cycle + instr.n
            return
        if isinstance(instr, isa.Repeat):
            # T18: re-dispatch on the last cycle of each block of d cycles.
            if self._last_data is None:
                raise ProgramError(f"{self.unit}: Repeat at position {self._idx} not preceded by a data instruction")
            for k in range(1, instr.n + 1):
                self._pending.append((cycle + k * instr.d - 1, self._last_data))
            self._next_start = cycle + instr.n * instr.d
            return
        # A data instruction occupies one cycle and dispatches on it.
        self._last_data = instr
        self._pending.append((cycle, instr))
        self._next_start = cycle + 1

    def notify_issued(self):
        """True only on the cycle on which this queue dispatched its Notify (B14)."""
        return self._notified

    def done(self):
        """True once the last element has used its last cycle.

        False while parked on Sync (a queue whose barrier is never released is
        never done) and while a Repeat still has dispatches left.
        """
        if self._parked or self._pending or self._idx < len(self.instrs):
            return False
        if not self.instrs:
            return True
        return self._last_cycle is not None and self._next_start <= self._last_cycle + 1
