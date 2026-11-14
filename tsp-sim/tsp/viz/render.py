"""Build the self-contained timeline HTML page (plan section 8).

The page is template.html with style.css and app.js inlined, plus two JSON
blocks: the trace (exactly trace.to_json()) and the chip geometry.
"""
from __future__ import annotations

import html
import json
import re
from pathlib import Path

from ..config import ChipConfig
from ..trace import Trace

_HERE = Path(__file__).parent

# Inside a <script> element the HTML parser only cares about "</" (end tag)
# and "<!--" (escaped state). Both can only occur inside JSON strings, where
# "\/" and "!" are valid escapes for "/" and "!", so JSON.parse yields the
# same object. json.dumps never emits "\/" or "!" itself, so the mapping
# is reversible exactly (see unescape_script_json).
_ESCAPES = (("</", "<\\/"), ("<!--", "<\\u0021--"))


def escape_script_json(s: str) -> str:
    for raw, esc in _ESCAPES:
        s = s.replace(raw, esc)
    return s


def unescape_script_json(s: str) -> str:
    for raw, esc in reversed(_ESCAPES):
        s = s.replace(esc, raw)
    return s


def extract_json_block(page: str, element_id: str) -> str:
    """Return the exact JSON text embedded in <script type="application/json" id=...>."""
    m = re.search(r'<script type="application/json" id="' + re.escape(element_id) + r'">(.*?)</script>',
                  page, re.S)
    if m is None:
        raise ValueError(f"no JSON block {element_id!r}")
    return unescape_script_json(m.group(1))


def chip_info(config: ChipConfig) -> dict:
    """What the page needs from the config."""
    return {
        "name": config.name,
        "slices": [{"name": s, "pos": i, "units": config.units_of(s)}
                   for i, s in enumerate(config.slice_names())],
        "n_positions": config.n_positions,
        "vxm_pos": config.vxm_pos,
        "streams_per_dir": config.streams_per_dir,
        "lanes": config.lanes,
        "timing": {k: {"d_skew": t.d_skew, "d_func": t.d_func} for k, t in sorted(config.timing.items())},
        "clock_hz": config.clock_hz,
    }


def _read(name: str) -> str:
    return (_HERE / name).read_text(encoding="utf-8")


def render_timeline(trace: Trace, config: ChipConfig, title: str) -> str:
    """One self-contained HTML document showing the trace (plan section 8)."""
    chip_json = json.dumps(chip_info(config), sort_keys=True, separators=(",", ":"))
    parts = {
        "TITLE": html.escape(title, quote=True),
        "STYLE": _read("style.css"),
        "SCRIPT": _read("app.js"),
        "TRACE_JSON": escape_script_json(trace.to_json()),
        "CHIP_JSON": escape_script_json(chip_json),
    }
    # One pass, so placeholder-like text inside the data is never substituted.
    return re.sub(r"\{\{([A-Z_]+)\}\}", lambda m: parts[m.group(1)], _read("template.html"))


def write_timeline(path, trace: Trace, config: ChipConfig, title: str) -> None:
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(render_timeline(trace, config, title), encoding="utf-8")
