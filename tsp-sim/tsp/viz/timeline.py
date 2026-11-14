"""Cycle-by-cycle timeline of one run, written as one self-contained HTML file.

See plan.md, section "Visualisation".  Python only gathers the data and fills
template.html; all drawing is done by the JavaScript in the template, so
the page works offline and the embedded JSON is the single source of what
is shown.  The output is deterministic: the same program and trace always
give a byte-identical file.
"""

import html
import json
import re
from pathlib import Path

_TEMPLATE = Path(__file__).with_name("template.html")
_FIELD = re.compile(r"\{\{([A-Z_]+)\}\}")


def _script_json(obj):
    """Canonical JSON that is safe inside a <script> element.

    '<', '>' and '&' only occur inside JSON strings, where the \\u escapes
    decode to the same characters, so JSON.parse gives back the same object.
    """
    text = json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    return text.replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026")


def _band_end(trace):
    """First cycle drawn as its own column.

    The Sync/Notify barrier occupies cycles 0 .. barrier_cycles - 1 (ledger
    T15) and nothing is dispatched or emitted in it, so it is collapsed into
    one band.  If a trace ever shows activity inside it, the band is cut
    short so that no dispatch or register is hidden.
    """
    starts = [trace.config["barrier_cycles"], trace.n_cycles]
    starts += [d["cycle"] for d in trace.dispatches]
    starts += [c[0] for c in trace.cells]
    return max(0, min(starts))


def timeline_data(program, trace, title):
    """The object embedded in the page: everything the JavaScript draws."""
    config = program.config
    queued = set(program.queues)
    dispatching = {d["unit"] for d in trace.dispatches}
    units = [[u, config.pos(u)] for u in config.units() if u in queued or u in dispatching]
    positions = [[] for _ in range(config.n_positions)]
    for u in config.units():
        positions[config.pos(u)].append(u)
    return {
        "title": title,
        "digest": trace.digest(),
        "band_end": _band_end(trace),
        "units": units,
        "positions": positions,
        "schedule": program.schedule,
        "trace": trace.to_obj(),
    }


def render_timeline(program, trace, title, path):
    """Write the timeline of `trace` (a run of `program`) to `path` as HTML."""
    data = timeline_data(program, trace, title)
    fields = {
        "TITLE": html.escape(title),
        "DIGEST": html.escape(data["digest"]),
        "DATA_JSON": _script_json(data),
    }
    template = _TEMPLATE.read_text(encoding="utf-8")
    page = _FIELD.sub(lambda m: fields[m.group(1)], template)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(page)
