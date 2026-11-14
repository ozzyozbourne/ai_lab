"""check_program, the text format and dispatch_times (plan 3.7)."""

from dataclasses import replace

import pytest

from tsp import asm, isa, params
from tsp.errors import ProgramError
from tsp.params import ChipConfig
from tsp.program import Program

CFG = ChipConfig.toy()
L = CFG.lanes
LPS = CFG.lanes_per_superlane


def E(s):
    return isa.StreamRef("E", s)


def W(s):
    return isa.StreamRef("W", s)


def valid_queues():
    """A hand-written program that uses every instruction class."""
    dist_map = tuple([-1] + list(range(LPS - 1)))
    perm_map = tuple(reversed(range(L)))
    return {
        "MXM_W0": [
            isa.Sync(),
            isa.Iw("int8", ((0, W(0)), (5, W(1))), expect=("W.0@0", "W.5@0")),
            isa.Abc("int8", W(2), E(4), 8, tag="mv@1", expect=("x@1",)),
            isa.Repeat(1, 2),
        ],
        "SXM_W": [
            isa.Sync(),
            isa.Nop(4),
            isa.Distribute(1, W(3), E(3), dist_map, L, tag="d@2", expect=("q@2",)),
            isa.Permute(2, W(2), E(6), perm_map, 10, tag="p [x]@2", expect=("r@2",)),
            isa.Shift(4, E(4), W(8), -2, 10, tag="s@2", expect=("t@2",)),
        ],
        "MEM_W0": [
            isa.Sync(),
            isa.Read(3, E(5), tag="x@0#0"),
            isa.Repeat(2, 4),
            isa.Repeat(1, 1),
            isa.Write(CFG.mem_words - 1, W(2), expect=('y "q"@1#2',)),
        ],
        "VXM_A0": [
            isa.Notify(),
            isa.Nop(2),
            isa.Vxm("add", "int32", E(0), E(4), E(8), L, tag="y@3", expect=("a@3", "b@2")),
            isa.Vxm("mul", "fp32", E(0), E(0), W(8), 4, tag="sq@3", expect=("a@3", "a@3")),
            isa.Vxm("relu", "int32", E(8), None, E(12), L, tag="r@3", expect=("y@3",)),
            isa.Vxm("tanh", "fp32", E(8), None, E(12), L),
            isa.Vxm("cast", "fp32", E(8), None, E(14), L, out_dtype="fp16", tag="h@3"),
            isa.Vxm("cast", "fp16", E(14), None, E(16), L, out_dtype="fp32"),
            isa.Vxm("cast", "int32", E(16), None, E(20), L, out_dtype="fp32"),
            isa.Vxm("requant", "int32", E(20), None, E(1), L, out_dtype="int8", imm=7),
        ],
        "MXM_E0": [
            isa.Sync(),
            isa.Iw("fp16", tuple((r, E(2 * r)) for r in range(CFG.iw_max_streams // 2))),
            isa.Abc("fp16", E(30), W(28), L, tag="z@4"),
        ],
    }


def prog(queues=None):
    return Program(CFG, valid_queues() if queues is None else queues)


def with_instr(unit, index, instr):
    q = valid_queues()
    q[unit][index] = instr
    return prog(q)


def rejects(program, match):
    with pytest.raises(ProgramError, match=match):
        asm.check_program(program)


# --- accepting -----------------------------------------------------------------
def test_valid_program_accepted():
    asm.check_program(prog())


def test_minimal_program_accepted():
    asm.check_program(prog({"VXM_A0": [isa.Notify()]}))


# --- one test per rule ------------------------------------------------------------
def test_unknown_unit():
    q = valid_queues()
    q["MEM_W99"] = [isa.Sync()]
    rejects(prog(q), "unknown unit")


def test_instruction_not_allowed_on_unit():
    rejects(with_instr("MEM_W0", 1, isa.Abc("int8", W(2), E(4), 8)), "not allowed on a MEM unit")


def test_vxm_instruction_on_mxm():
    rejects(with_instr("MXM_W0", 1, isa.Vxm("neg", "int32", W(0), None, E(4), L)), "not allowed on a MXM unit")


def test_stream_out_of_range():
    rejects(with_instr("MEM_W0", 1, isa.Read(3, E(CFG.streams_per_dir))), "outside")


def test_negative_stream():
    rejects(with_instr("MEM_W0", 1, isa.Read(3, E(-1))), "outside")


def test_wide_value_past_last_stream():
    s = CFG.streams_per_dir - isa.width("int32") + 1
    rejects(with_instr("VXM_A0", 4, isa.Vxm("relu", "int32", E(8), None, E(s), L)), "outside|multiple")


def test_unaligned_base_stream():
    rejects(with_instr("VXM_A0", 4, isa.Vxm("relu", "int32", E(8), None, E(2), L)), "not a multiple")


def test_bad_direction():
    rejects(with_instr("MEM_W0", 1, isa.Read(3, isa.StreamRef("N", 0))), "direction")


def test_bad_dtype():
    rejects(with_instr("VXM_A0", 4, isa.Vxm("relu", "int64", E(8), None, E(12), L)), "dtype")


def test_iw_too_many_streams():
    n = CFG.iw_max_streams + 1
    rejects(with_instr("MXM_W0", 1, isa.Iw("int8", tuple((r % L, W(r)) for r in range(n)))), "more than")


def test_iw_fp16_too_many_streams():
    n = CFG.iw_max_streams // isa.width("fp16") + 1
    rejects(with_instr("MXM_E0", 1, isa.Iw("fp16", tuple((r, E(2 * r)) for r in range(n)))), "more than")


def test_iw_row_out_of_range():
    rejects(with_instr("MXM_W0", 1, isa.Iw("int8", ((L, W(0)),))), "row")


def test_abc_n_rows_out_of_range():
    rejects(with_instr("MXM_W0", 2, isa.Abc("int8", W(2), E(4), L + 1)), "n_rows")
    rejects(with_instr("MXM_W0", 2, isa.Abc("int8", W(2), E(4), 0)), "n_rows")


def test_nop_out_of_range():
    rejects(with_instr("SXM_W", 1, isa.Nop(0)), "Nop")
    rejects(with_instr("SXM_W", 1, isa.Nop(CFG.nop_max + 1)), "Nop")


def test_nop_max_accepted():
    asm.check_program(with_instr("SXM_W", 1, isa.Nop(CFG.nop_max)))


def test_repeat_n_below_1():
    rejects(with_instr("MEM_W0", 2, isa.Repeat(0, 4)), "n=0")


def test_repeat_d_below_1():
    rejects(with_instr("MEM_W0", 2, isa.Repeat(2, 0)), "d=0")


def test_repeat_after_nop():
    q = valid_queues()
    q["SXM_W"].insert(2, isa.Repeat(1, 1))   # directly after Nop(4)
    rejects(prog(q), "not preceded")


def test_repeat_after_sync():
    q = valid_queues()
    q["MEM_W0"].insert(1, isa.Repeat(1, 1))
    rejects(prog(q), "not preceded")


def test_address_out_of_range():
    rejects(with_instr("MEM_W0", 1, isa.Read(CFG.mem_words, E(5))), "addr")
    rejects(with_instr("MEM_W0", 4, isa.Write(-1, W(2))), "addr")


def test_length_out_of_range():
    rejects(with_instr("VXM_A0", 4, isa.Vxm("relu", "int32", E(8), None, E(12), 0)), "n=0")
    rejects(with_instr("SXM_W", 4, isa.Shift(4, E(4), W(8), 1, L + 1)), "outside")


def test_distribute_map_length():
    rejects(with_instr("SXM_W", 2, isa.Distribute(1, W(3), E(3), tuple(range(LPS - 1)), L)), "entries")


def test_distribute_map_entry():
    m = tuple([LPS] + [0] * (LPS - 1))
    rejects(with_instr("SXM_W", 2, isa.Distribute(1, W(3), E(3), m, L)), "map entry")
    m = tuple([-2] + [0] * (LPS - 1))
    rejects(with_instr("SXM_W", 2, isa.Distribute(1, W(3), E(3), m, L)), "map entry")


def test_permute_not_bijection():
    m = tuple([0] * L)
    rejects(with_instr("SXM_W", 3, isa.Permute(2, W(2), E(6), m, L)), "bijection")


def test_sxm_bad_width():
    rejects(with_instr("SXM_W", 4, isa.Shift(3, E(3), W(3), 1, L)), "width")


def test_empty_queue():
    q = valid_queues()
    q["SXM_E"] = []
    rejects(prog(q), "empty")


def test_queue_not_starting_with_sync():
    q = valid_queues()
    q["MEM_W0"].pop(0)
    rejects(prog(q), "not Sync or Notify")


def test_sync_not_first():
    q = valid_queues()
    q["MEM_W0"].append(isa.Sync())
    rejects(prog(q), "only allowed as the first")


def test_notify_not_first():
    q = valid_queues()
    q["MEM_W0"].append(isa.Notify())
    rejects(prog(q), "only allowed as the first")


def test_no_notify():
    q = valid_queues()
    q["VXM_A0"][0] = isa.Sync()
    rejects(prog(q), "0 Notify")


def test_two_notifies():
    q = valid_queues()
    q["MEM_W0"][0] = isa.Notify()
    rejects(prog(q), "2 Notify")


def test_vxm_unknown_op():
    rejects(with_instr("VXM_A0", 4, isa.Vxm("mask", "int32", E(8), None, E(12), L)), "unknown op")


def test_vxm_binary_without_b():
    rejects(with_instr("VXM_A0", 2, isa.Vxm("add", "int32", E(0), None, E(8), L)), "without operand b")


def test_vxm_unary_with_b():
    rejects(with_instr("VXM_A0", 4, isa.Vxm("neg", "int32", E(8), E(8), E(12), L)), "with operand b")


@pytest.mark.parametrize("op,dt,out_dt", [
    ("add", "int8", ""), ("mul", "fp16", ""), ("relu", "int32", "fp32"),
    ("exp", "int32", ""), ("rsqrt", "fp16", ""), ("tanh", "fp32", "fp16"),
    ("cast", "fp32", ""), ("cast", "fp16", "int32"), ("cast", "fp32", "int32"), ("cast", "int8", "fp32"),
    ("requant", "fp32", "int8"), ("requant", "int32", ""),
])
def test_vxm_illegal_dtype_combination(op, dt, out_dt):
    b = E(0) if op in params.VXM_BINARY_OPS else None
    instr = isa.Vxm(op, dt, E(0), b, E(4), L, out_dtype=out_dt)
    rejects(with_instr("VXM_A0", 4, instr), "not defined")


@pytest.mark.parametrize("op", params.VXM_UNARY_OPS + params.VXM_BINARY_OPS)
def test_vxm_every_op_has_a_legal_form(op):
    dt, out_dt = {"cast": ("int32", "fp32"), "requant": ("int32", "int8")}.get(op, ("fp32", ""))
    b = E(0) if op in params.VXM_BINARY_OPS else None
    asm.check_program(with_instr("VXM_A0", 4, isa.Vxm(op, dt, E(0), b, E(4), L, out_dtype=out_dt)))


def test_mxm_w_iw_must_read_west():
    rejects(with_instr("MXM_W0", 1, isa.Iw("int8", ((0, E(0)),))), "B10")


def test_mxm_w_abc_src_must_read_west():
    rejects(with_instr("MXM_W0", 2, isa.Abc("int8", E(2), E(4), 8)), "B10")


def test_mxm_w_abc_out_must_flow_east():
    rejects(with_instr("MXM_W0", 2, isa.Abc("int8", W(2), W(4), 8)), "B10")


def test_mxm_e_directions_mirrored():
    rejects(with_instr("MXM_E0", 1, isa.Iw("fp16", ((0, W(0)),))), "B10")
    rejects(with_instr("MXM_E0", 2, isa.Abc("fp16", W(30), W(28), L)), "B10")
    rejects(with_instr("MXM_E0", 2, isa.Abc("fp16", E(30), E(28), L)), "B10")


def test_mxm_bad_dtype():
    rejects(with_instr("MXM_W0", 2, isa.Abc("int32", W(0), E(4), 8)), "dtype")


def test_list_instead_of_tuple_rejected():
    rejects(with_instr("SXM_W", 3, isa.Permute(2, W(2), E(6), list(range(L)), L)), "tuple")


def test_not_an_instruction():
    q = valid_queues()
    q["MEM_W0"].append("Read")
    rejects(prog(q), "not an instruction")


def test_isca2020_config():
    cfg = ChipConfig.isca2020()
    perm = tuple(reversed(range(cfg.lanes)))
    q = {"VXM_A0": [isa.Notify()],
         "SXM_E": [isa.Sync(), isa.Permute(1, E(0), W(0), perm, cfg.lanes)],
         "MEM_E43": [isa.Sync(), isa.Read(cfg.mem_words - 1, W(31))]}
    asm.check_program(Program(cfg, q))
    with pytest.raises(ProgramError):
        asm.check_program(Program(CFG, q))


# --- text form ----------------------------------------------------------------------
def test_format_instr_examples():
    assert asm.format_instr(isa.Read(3, E(5), "x@0#0")) == 'Read addr=3 out=E5 tag="x@0#0"'
    assert asm.format_instr(isa.Sync()) == "Sync"
    assert asm.format_instr(isa.Nop(7)) == "Nop n=7"
    assert asm.format_instr(isa.Repeat(2, 4)) == "Repeat n=2 d=4"
    assert asm.format_instr(isa.Iw("int8", ((0, W(0)), (5, W(1))))) == 'Iw dtype="int8" entries=[0:W0,5:W1]'
    assert (asm.format_instr(isa.Vxm("relu", "int32", E(8), None, E(12), 3, expect=("y@3",)))
            == 'Vxm op="relu" dtype="int32" a=E8 b=- out=E12 n=3 expect=["y@3"]')


def test_format_instr_deterministic():
    p = prog()
    assert asm.disassemble(p) == asm.disassemble(prog())


def test_disassemble_canonical_order():
    text = asm.disassemble(prog())
    order = [line.split()[1] for line in text.splitlines() if line.startswith("unit ")]
    assert order == [u for u in CFG.units() if u in valid_queues()]
    assert order[0] == "MXM_W0" and order[-1] == "MXM_E0"


def test_round_trip_every_class():
    p = prog()
    classes = {type(i).__name__ for q in p.queues.values() for i in q}
    assert classes == {c.__name__ for c in isa.QUEUE_CONTROL + isa.MEM_INSTRS + isa.VXM_INSTRS
                       + isa.MXM_INSTRS + isa.SXM_INSTRS}
    back = asm.assemble(asm.disassemble(p), p.config)
    assert back == {u: p.queues[u] for u in CFG.units() if u in p.queues}
    assert list(back) == [u for u in CFG.units() if u in p.queues]
    # And the text is a fixed point.
    assert asm.disassemble(Program(CFG, back)) == asm.disassemble(p)


def test_round_trip_awkward_tags():
    tags = ["x@0#0", "a b", 'q"uote', "back\\slash", "[1,2]", "E5", "-", "unit X", "k=v", "é", ""]
    q = {"VXM_A0": [isa.Notify()], "MEM_E0": [isa.Sync()]}
    for k, t in enumerate(tags):
        q["MEM_E0"].append(isa.Read(k, E(k), tag=t))
        q["MEM_E0"].append(isa.Write(k, W(k), expect=(t, t + "#1")))
    p = prog(q)
    asm.check_program(p)
    assert asm.assemble(asm.disassemble(p), CFG) == q


def test_assemble_errors():
    with pytest.raises(ProgramError):
        asm.assemble("unit NOPE\n  Sync\n", CFG)
    with pytest.raises(ProgramError):
        asm.assemble("  Sync\n", CFG)
    with pytest.raises(ProgramError):
        asm.assemble("unit VXM_A0\n  Frob n=1\n", CFG)
    with pytest.raises(ProgramError):
        asm.assemble("unit VXM_A0\n  Nop m=1\n", CFG)
    with pytest.raises(ProgramError):
        asm.assemble('unit VXM_A0\n  Read addr=1 out=E5 tag="x\n', CFG)


def test_assemble_ignores_blank_and_comment_lines():
    text = "; a comment\n\nunit VXM_A0\n  Notify\n\n  ; another\n  Nop n=3\n"
    assert asm.assemble(text, CFG) == {"VXM_A0": [isa.Notify(), isa.Nop(3)]}


# --- dispatch_times -------------------------------------------------------------------
def test_dispatch_times_worked_example():
    read = isa.Read(0, E(0))
    vxm = isa.Vxm("neg", "int32", E(0), None, E(4), L)
    q = [isa.Sync(), isa.Nop(3), read, isa.Repeat(2, 4), vxm]
    T15 = CFG.barrier_cycles
    assert asm.dispatch_times(q, CFG) == [(T15 + 3, read), (T15 + 7, read), (T15 + 11, read), (T15 + 12, vxm)]


def test_dispatch_times_notify_queue():
    v = isa.Vxm("neg", "int32", E(0), None, E(4), L)
    assert asm.dispatch_times([isa.Notify(), v, v], CFG) == [(CFG.barrier_cycles, v), (CFG.barrier_cycles + 1, v)]


def test_dispatch_times_agrees_with_icu_on_valid_program():
    from tsp.icu import InstructionQueue
    p = prog()
    queues = {u: InstructionQueue(u, p.queues[u], CFG) for u in CFG.units() if u in p.queues}
    got = {u: [] for u in queues}
    release = None
    for c in range(CFG.barrier_cycles + 100):
        notified = False
        for u, q in queues.items():
            r = q.step(c, release)
            notified = notified or q.notify_issued()
            if r is not None:
                got[u].append((c, r))
        if notified:
            release = c + CFG.barrier_cycles
    assert all(q.done() for q in queues.values())
    for u in queues:
        assert got[u] == asm.dispatch_times(p.queues[u], CFG), u
