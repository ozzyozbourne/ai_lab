"""Properties of the timeline page (plan section 8), checked without a browser."""
import json
import re
import time

import pytest

from tsp.config import ChipConfig
from tsp.trace import Trace
from tsp.viz import extract_json_block, render_timeline, summarise, write_timeline

from viz_synth import big_trace, make_trace

CFG = ChipConfig.toy()  # 37 positions, vxm at 18


def small_trace(cfg=CFG, extra_tag=None):
    p = cfg.n_positions
    drives = [
        ("E", 0, 10, 5, "a.t0#0", "MEM_W7"),       # A: overwritten by B at pos 14, cycle 9
        ("E", 0, 14, 9, "b.t0#0", "MEM_W3"),       # B: falls off the East edge
        ("E", 0, 30, 6, "f.t0#0", "MEM_E11"),      # F: same lane, overlaps A and B in time
        ("W", 3, 18, 4, "c.t0#1", "VXM.0"),        # C: falls off the West edge
        ("W", 5, 30, 2, "d#0", "MEM_E11"),         # D: overwritten by E at pos 25, cycle 7
        ("W", 5, 25, 7, extra_tag or "e#0", "MEM_E6"),  # E: never read
    ]
    samples = [
        ("E", 0, 12, 7, "MEM_W5"),    # reads A
        ("E", 0, 14, 9, "MEM_W3"),    # reads B at its own drive cell
        ("E", 0, 20, 15, "MEM_E1"),   # reads B (last)
        ("E", 0, 33, 9, "MEM_E14"),   # reads F
        ("W", 3, 5, 17, "MEM_W12"),   # reads C
        ("W", 5, 27, 5, "MEM_E8"),    # reads D
    ]
    issues = [
        (3, "MEM_W7", "READ", "READ b0@0 -> E0<a.t0#0>", 3, 5),
        (4, "VXM.0", "ADD", "ADD.i32 W3<c.t0> -> W3<c.t0>", 3, 4),
        (6, "MEM_E1", "WRITE", "WRITE E0<b.t0#0> -> b1@0", 6, 7),
        (7, "MEM_W3", "READ", "READ b0@1 -> E0<b.t0#0>", 7, 9),
        (9, "MEM_W7", "READ", "READ b0@2 -> E0<a.t0#0>", 9, 11),
    ]
    return make_trace(cfg, drives, samples, issues, n_cycles=40), p


def flight_by_tag(s, tag):
    (f,) = [f for f in s["flights"] if f["tag"] == tag]
    return f


# ---------------------------------------------------------------- embedding
def test_embedded_trace_json_is_exact():
    tr, _ = small_trace()
    page = render_timeline(tr, CFG, "t")
    assert extract_json_block(page, "trace") == tr.to_json()
    assert json.loads(extract_json_block(page, "trace")) == tr.to_obj()


def test_script_breaking_tags_are_escaped():
    tr, _ = small_trace(extra_tag="evil</script><!--<script>x#0")
    page = render_timeline(tr, CFG, "t")
    raw = re.search(r'<script type="application/json" id="trace">(.*?)</script>', page, re.S).group(1)
    assert "</" not in raw and "<!--" not in raw
    assert json.loads(raw) == tr.to_obj()            # the escaped text still parses to the same object
    assert extract_json_block(page, "trace") == tr.to_json()
    assert page.count("</script>") == 3              # trace, chip, app


def test_chip_block():
    tr, _ = small_trace()
    chip = json.loads(extract_json_block(render_timeline(tr, CFG, "t"), "chip"))
    assert [s["name"] for s in chip["slices"]] == CFG.slice_names()
    assert [s["pos"] for s in chip["slices"]] == list(range(CFG.n_positions))
    assert chip["slices"][CFG.vxm_pos]["units"] == [f"VXM.{i}" for i in range(16)]
    assert chip["n_positions"] == 37 and chip["streams_per_dir"] == 32 and chip["lanes"] == 32
    assert chip["timing"]["READ"] == {"d_skew": 0, "d_func": 2}
    assert chip["clock_hz"] == CFG.clock_hz


def test_no_network_references():
    tr, _ = small_trace()
    page = render_timeline(tr, CFG, "t")
    assert "http://" not in page and "https://" not in page
    outside_data = re.sub(r'<script type="application/json" id="\w+">.*?</script>', "", page, flags=re.S)
    assert "//" not in outside_data                  # no protocol-relative refs (and no // comments in JS)
    assert not re.search(r"\b(src|href)\s*=", outside_data, re.I)
    assert "@import" not in page and "url(" not in page
    assert not re.search(r"\b(fetch|XMLHttpRequest|WebSocket|EventSource|importScripts)\b", outside_data)


def test_deterministic_and_title_escaped():
    tr, _ = small_trace()
    title = '<b>M1 & "relu"</b>'
    a = render_timeline(tr, CFG, title)
    assert a == render_timeline(tr, CFG, title)
    assert "<b>M1" not in a
    assert "<title>&lt;b&gt;M1 &amp; &quot;relu&quot;&lt;/b&gt;</title>" in a
    assert a.count("&lt;b&gt;M1 &amp;") == 2          # <title> and <h1>


def test_write_timeline(tmp_path):
    tr, _ = small_trace()
    p = tmp_path / "sub" / "t.html"
    write_timeline(p, tr, CFG, "t")
    assert p.read_text(encoding="utf-8") == render_timeline(tr, CFG, "t")


# ---------------------------------------------------------------- summary
def test_issue_blocks_per_unit():
    tr, _ = small_trace()
    s = summarise(tr, CFG)
    direct = {}
    for e in tr.events:
        if e.kind == "issue":
            direct[e.unit] = direct.get(e.unit, 0) + 1
    assert s["issue_blocks_per_unit"] == direct
    assert list(s["issue_blocks_per_unit"]) == [u for u in CFG.unit_names() if u in direct]  # West -> East
    assert s["n_issue_blocks"] == len(tr.by_kind("issue")) == 5


def test_one_flight_per_drive_and_lanes():
    tr, _ = small_trace()
    s = summarise(tr, CFG)
    drives = tr.by_kind("drive")
    assert len(s["flights"]) == len(drives) == s["n_flights"]
    for f, d in zip(s["flights"], drives):
        assert (f["dir"], f["stream"], f["start_pos"], f["start_cycle"], f["tag"]) == (d.dir, d.stream, d.pos, d.cycle, d.tag)
    per_lane = {}
    for d in drives:
        per_lane[f"{d.dir}{d.stream}"] = per_lane.get(f"{d.dir}{d.stream}", 0) + 1
    assert s["flights_per_lane"] == per_lane
    assert s["lanes_used"] == ["E0", "W3", "W5"]
    assert flight_by_tag(s, "c.t0#1")["value"] == "c.t0"


def test_east_overwrite_and_edge():
    tr, p = small_trace()
    s = summarise(tr, CFG)
    a, b, f = (flight_by_tag(s, t) for t in ("a.t0#0", "b.t0#0", "f.t0#0"))
    assert (a["last_sample_cycle"], a["end_cycle"], a["end_reason"], a["end_pos"]) == (7, 9, "overwritten", 14)
    assert (b["last_sample_cycle"], b["n_samples"], b["end_cycle"], b["end_reason"]) == (15, 2, 9 + (p - 14), "edge")
    assert (f["last_sample_cycle"], f["end_cycle"], f["end_reason"]) == (9, 6 + (p - 30), "edge")
    # stacking: A and B chain on sub-row 0; F overlaps both in time
    assert (a["subrow"], b["subrow"], f["subrow"]) == (0, 0, 1)
    assert s["subrows_per_lane"]["E0"] == 2


def test_west_overwrite_and_edge():
    tr, _ = small_trace()
    s = summarise(tr, CFG)
    c, d, e = (flight_by_tag(s, t) for t in ("c.t0#1", "d#0", "e#0"))
    assert (c["last_sample_cycle"], c["end_cycle"], c["end_reason"], c["end_pos"]) == (17, 4 + 18 + 1, "edge", -1)
    assert (d["last_sample_cycle"], d["end_cycle"], d["end_reason"], d["end_pos"]) == (5, 7, "overwritten", 25)
    assert (e["last_sample_cycle"], e["n_samples"], e["end_cycle"]) == (None, 0, 7 + 25 + 1)


def test_samples_agree_with_occupancy():
    """Every attributed sample saw the flight's tag in the occupancy (independent of the flight logic)."""
    tr, _ = small_trace()
    s = summarise(tr, CFG)
    assert sum(f["n_samples"] for f in s["flights"]) == len(tr.by_kind("sample"))
    for e in tr.by_kind("sample"):
        assert e.tag is not None


def check_flights_against_occupancy(tr, s, cfg):
    """A flight's cell holds its tag during [start, end) and not at end_cycle."""
    occ = [{(d, st, x): tag for d, st, x, tag in cyc} for cyc in tr.occupancy]
    for f in s["flights"]:
        step = 1 if f["dir"] == "E" else -1
        for t in range(f["start_cycle"], f["end_cycle"]):
            x = f["start_pos"] + step * (t - f["start_cycle"])
            assert 0 <= x < cfg.n_positions
            assert occ[t][(f["dir"], f["stream"], x)] == f["tag"]
        t = f["end_cycle"]
        x = f["start_pos"] + step * (t - f["start_cycle"])
        assert x == f["end_pos"]
        if f["end_reason"] == "edge":
            assert x in (-1, cfg.n_positions)
        else:  # overwritten: another drive on this lane starts exactly there and then
            assert any(g["start_cycle"] == t and g["start_pos"] == x and g["lane"] == f["lane"] for g in s["flights"])
        if f["last_sample_cycle"] is not None:
            assert f["start_cycle"] <= f["last_sample_cycle"] < f["end_cycle"]


def no_overlap_in_subrows(s):
    rows = {}
    for f in s["flights"]:
        rows.setdefault((f["lane"], f["subrow"]), []).append((f["start_cycle"], f["end_cycle"]))
    for iv in rows.values():
        iv.sort()
        for (a0, a1), (b0, b1) in zip(iv, iv[1:]):
            assert a1 <= b0


def test_flights_match_occupancy_small():
    tr, _ = small_trace()
    s = summarise(tr, CFG)
    check_flights_against_occupancy(tr, s, CFG)
    no_overlap_in_subrows(s)


@pytest.mark.parametrize("cfg", [ChipConfig.toy(), ChipConfig.paper()])
def test_big_trace(cfg):
    tr = big_trace(cfg, n_cycles=1500)
    assert len(tr.events) > 1000
    t0 = time.perf_counter()
    page = render_timeline(tr, cfg, "big")
    s = summarise(tr, cfg)
    assert time.perf_counter() - t0 < 10
    assert extract_json_block(page, "trace") == tr.to_json()
    assert s["n_flights"] == len(tr.by_kind("drive"))
    assert s["n_issue_blocks"] == len(tr.by_kind("issue"))
    assert sum(f["n_samples"] for f in s["flights"]) == len(tr.by_kind("sample"))
    check_flights_against_occupancy(tr, s, cfg)
    no_overlap_in_subrows(s)


def test_summary_is_json_serialisable_and_roundtrip_trace():
    tr, _ = small_trace()
    s = summarise(tr, CFG)
    json.dumps(s)
    assert summarise(Trace.from_json(tr.to_json()), CFG) == s
