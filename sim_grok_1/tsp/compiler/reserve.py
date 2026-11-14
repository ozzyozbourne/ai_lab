"""The reservation table used by the scheduler (plan 4.5).

It records, in absolute program time (tau, cycle 0 = first cycle after the
start-up barrier), everything already promised to placed tiles:

* `(unit, cycle)`: a unit dispatches an instruction on that cycle (ledger T16:
  one instruction per queue per cycle).
* `(dir, s, x, cycle)`: stream register SR[dir][s][x] holds a value that is
  still needed on that cycle.  A value reserves the cells from its emission
  to its last reader and nothing after that: past its last reader it may be
  overwritten (ledger B1).  Because a stream value moves one position per
  cycle (T1), its cells lie on one diagonal of the space-time plane
  (t - x constant eastward, t + x constant westward).
* `busy_until[plane]`: the cycle of the last Abc scheduled on an MXM plane.

Claims made while trying one start time are journalled so that they can be
released in one go when the tile does not fit (the "delay" step).
"""


def path_cells(dir, x_from, t_from, x_to):
    """The (x, cycle) cells a value occupies from (x_from, t_from) up to x_to, in its direction."""
    step = 1 if dir == "E" else -1
    n = (x_to - x_from) * step
    if n < 0:
        raise ValueError(f"position {x_to} is not downstream of {x_from} flowing {dir}")
    return [(x_from + i * step, t_from + i) for i in range(n + 1)]


class ReservationTable:
    def __init__(self):
        self.units = {}         # (unit, cycle) -> owner description
        self.cells = {}         # (dir, s, x, cycle) -> owner description
        self.busy_until = {}    # MXM unit -> cycle of its last Abc
        self._journal = None

    # -- transactions -----------------------------------------------------
    def begin(self):
        self._journal = []

    def rollback(self):
        for table, key in reversed(self._journal):
            del table[key]
        self._journal = None

    def commit(self):
        self._journal = None

    def _put(self, table, key, owner):
        table[key] = owner
        if self._journal is not None:
            self._journal.append((table, key))

    # -- units ------------------------------------------------------------
    def unit_free(self, unit, cycle):
        return (unit, cycle) not in self.units

    def claim_unit(self, unit, cycle, owner):
        if not self.unit_free(unit, cycle):
            raise ValueError(f"{unit} already dispatches at cycle {cycle}")
        self._put(self.units, (unit, cycle), owner)

    # -- stream cells -----------------------------------------------------
    def cells_free(self, dir, s, cells):
        return all((dir, s, x, c) not in self.cells for x, c in cells)

    def claim_cells(self, dir, s, cells, owner):
        for x, c in cells:
            key = (dir, s, x, c)
            if key in self.cells:
                raise ValueError(f"stream cell {key} already reserved by {self.cells[key]}")
            self._put(self.cells, key, owner)

    # -- MXM planes -------------------------------------------------------
    def plane_busy_until(self, unit):
        """Cycle of the last Abc on this plane, or None."""
        return self.busy_until.get(unit)

    def set_busy_until(self, unit, cycle):
        self.busy_until[unit] = cycle
