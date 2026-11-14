"""Exception types shared by all modules."""


class TspError(Exception):
    """Base class for every error raised by this package."""


class GraphError(TspError):
    """The compute graph is malformed (bad dtype, length or operand)."""


class CompileError(TspError):
    """The compiler could not place or schedule the graph."""


class ProgramError(TspError):
    """A Program is structurally invalid (found by asm.check_program)."""


class SimulationError(TspError):
    """Base class for errors raised while simulating."""


class StreamCollisionError(SimulationError):
    """Two results were due in the same stream register on the same cycle."""


class EmptyOperandError(SimulationError):
    """An instruction sampled an empty stream register or unwritten memory."""


class OperandTagError(SimulationError):
    """An instruction sampled a value whose debug tag was not the expected one."""
