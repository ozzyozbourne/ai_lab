"""Timeline visualisation of a simulator Trace (plan.md section 8)."""
from .model import compute_flights, summarise, value_of
from .render import chip_info, extract_json_block, render_timeline, write_timeline

__all__ = ["render_timeline", "write_timeline", "summarise", "compute_flights", "value_of",
           "chip_info", "extract_json_block"]
