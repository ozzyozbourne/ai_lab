"""The compiler's one exception type."""


class CompileError(Exception):
    """The graph cannot be compiled for this chip: a graph restriction (plan 3.3),
    a capacity limit, an unavoidable placement conflict (plan 5.2) or a schedule
    search that passed `config.max_schedule_cycles` (plan 5.6, L-K6, L-K7)."""
