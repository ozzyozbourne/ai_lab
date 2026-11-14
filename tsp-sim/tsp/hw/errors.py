"""The one exception the hardware model raises for a broken program (plan.md 2.5)."""
from __future__ import annotations

# Fault codes: the numbered list in plan.md section 2.5.
EMPTY_SAMPLE = 1      # an instruction samples an empty cell
DOUBLE_DRIVE = 2      # two drives of one cell with one visible cycle
MEM_PORT = 3          # MEM port rules (L-M4, L-M5)
UNWRITTEN_READ = 4    # not a machine parameter: rule number. Read of a word never written
WEIGHT_ROW = 5        # not a machine parameter: rule number. MATVEC row missing / wrong dtype / bad expect_rows
FP16_UNIT = 6         # fp16 MXM unit rule (L-X9)
QUEUE_ENTRY = 7       # entry too wide for its unit (L-I2) or wrong kind of unit
OPERAND_RULE = 8      # alignment, range, width or direction (L-G8, L-X6)
BAD_NOP = 9           # Nop(n) with n outside 1..nop_max (L-T10)


class SimFault(Exception):
    """Raised when a program breaks a machine rule.

    Attributes: `cycle`, `unit`, `message`, `trace` (the partial Trace up to the
    fault) and `code` (the number of the rule in plan.md 2.5).
    """

    def __init__(self, cycle: int, unit: str, message: str, trace=None, code: int | None = None):
        super().__init__(f"cycle {cycle}, {unit}: {message}")
        self.cycle = cycle
        self.unit = unit
        self.message = message
        self.trace = trace
        self.code = code


class Violation(Exception):
    """Internal: a rule was broken; the cycle loop turns it into a SimFault."""

    def __init__(self, code: int, message: str):
        super().__init__(message)
        self.code = code
        self.message = message
