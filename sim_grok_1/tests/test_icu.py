"""Instruction queue timing (plan 2.6, ledger T14, T15, T16, T18, B14)."""

import pytest

from tsp import isa
from tsp.asm import dispatch_times
from tsp.errors import ProgramError
from tsp.icu import InstructionQueue
from tsp.params import ChipConfig

CFG = ChipConfig.toy()
T15 = CFG.barrier_cycles

READ = isa.Read(3, isa.StreamRef("E", 5), "x@0#0")
READ2 = isa.Read(4, isa.StreamRef("E", 6), "x@0#1")
VXM = isa.Vxm("add", "int32", isa.StreamRef("E", 0), isa.StreamRef("E", 4), isa.StreamRef("E", 8), 16, tag="y@1")


def run_queue(instrs, config=CFG, notify_at=None, n_cycles=None, unit="MEM_W0"):
    """Step one queue like the simulator would.

    notify_at: cycle at which some (other) queue issued Notify; None if never
    (but a queue's own Notify also counts).  Returns (dispatches, done_cycle,
    notify_cycles), done_cycle = first cycle after whose step done() is True.
    """
    q = InstructionQueue(unit, instrs, config)
    n_cycles = n_cycles if n_cycles is not None else T15 + 200
    out, notify_cycles, done_cycle = [], [], None
    release = None
    for c in range(n_cycles):
        if release is None and notify_at is not None and c > notify_at:
            release = notify_at + config.barrier_cycles
        r = q.step(c, release)
        if q.notify_issued():
            notify_cycles.append(c)
            if notify_at is None:
                notify_at = c
        if r is not None:
            out.append((c, r))
        if done_cycle is None and q.done():
            done_cycle = c
    return out, done_cycle, notify_cycles


def test_worked_example():
    q = [isa.Sync(), isa.Nop(3), READ, isa.Repeat(2, 4), VXM]
    out, done, _ = run_queue(q, notify_at=0)
    assert out == [(T15 + 3, READ), (T15 + 7, READ), (T15 + 11, READ), (T15 + 12, VXM)]
    if T15 == 35:  # the literal example of plan 2.6
        assert [c for c, _ in out] == [38, 42, 46, 47]
    assert done == T15 + 12


def test_data_instructions_back_to_back():
    out, done, _ = run_queue([isa.Sync(), READ, READ2, READ], notify_at=0)
    assert out == [(T15, READ), (T15 + 1, READ2), (T15 + 2, READ)]
    assert done == T15 + 2


def test_nop_occupies_n_cycles():
    out, done, _ = run_queue([isa.Sync(), READ, isa.Nop(1), READ2, isa.Nop(5), READ], notify_at=0)
    assert out == [(T15, READ), (T15 + 2, READ2), (T15 + 8, READ)]
    assert done == T15 + 8


def test_trailing_nop_counts_toward_done():
    out, done, _ = run_queue([isa.Sync(), READ, isa.Nop(4)], notify_at=0)
    assert out == [(T15, READ)]
    assert done == T15 + 4


def test_repeat_d1():
    out, done, _ = run_queue([isa.Sync(), READ, isa.Repeat(3, 1), READ2], notify_at=0)
    assert out == [(T15 + k, READ) for k in range(4)] + [(T15 + 4, READ2)]
    assert done == T15 + 4


def test_chained_repeats():
    q = [isa.Sync(), READ, isa.Repeat(2, 3), isa.Repeat(1, 5), READ2]
    out, done, _ = run_queue(q, notify_at=0)
    assert out == [(T15, READ), (T15 + 3, READ), (T15 + 6, READ), (T15 + 11, READ), (T15 + 12, READ2)]
    assert done == T15 + 12


def test_done_false_while_repeat_pending():
    q = InstructionQueue("MEM_W0", [isa.Sync(), READ, isa.Repeat(2, 10)], CFG)
    seen = []
    for c in range(T15 + 25):
        r = q.step(c, T15 if c > 0 else None)
        if r is not None:
            seen.append(c)
        if c < T15 + 20:
            assert not q.done(), c
    assert seen == [T15, T15 + 10, T15 + 20]
    assert q.done()


def test_notify_queue_resumes_at_t15():
    out, done, notes = run_queue([isa.Notify(), VXM], unit="VXM_A0")
    assert notes == [0]
    assert out == [(T15, VXM)]
    assert done == T15


def test_notify_issued_only_on_cycle_0():
    q = InstructionQueue("VXM_A0", [isa.Notify(), VXM], CFG)
    flags = []
    for c in range(T15 + 3):
        q.step(c, T15 if c > 0 else None)
        flags.append(q.notify_issued())
    assert flags[0] is True
    assert not any(flags[1:])


def test_sync_waits_for_release():
    # Barrier opens at notify cycle + T15 whenever the notify happens.
    out, _, _ = run_queue([isa.Sync(), READ], notify_at=7)
    assert out == [(7 + T15, READ)]


def test_sync_without_notify_never_done():
    out, done, _ = run_queue([isa.Sync(), READ], notify_at=None, n_cycles=T15 * 3)
    assert out == []
    assert done is None


def test_sync_only_queue_done_at_release():
    _, done, _ = run_queue([isa.Sync()], notify_at=0)
    assert done == T15 - 1


def test_never_returns_control_instructions():
    q = [isa.Sync(), isa.Nop(2), READ, isa.Repeat(2, 2), isa.Nop(1), VXM]
    out, _, _ = run_queue(q, notify_at=0)
    assert all(not isinstance(i, isa.QUEUE_CONTROL) for _, i in out)


def test_one_dispatch_per_cycle():
    q = [isa.Sync(), READ, isa.Repeat(4, 1), READ2, isa.Repeat(2, 2), VXM]
    out, _, _ = run_queue(q, notify_at=0)
    cycles = [c for c, _ in out]
    assert cycles == sorted(cycles) and len(cycles) == len(dict.fromkeys(cycles))


def test_step_must_be_sequential():
    q = InstructionQueue("MEM_W0", [isa.Sync(), READ], CFG)
    q.step(0, None)
    with pytest.raises(ValueError):
        q.step(2, None)


def test_misplaced_sync_raises():
    q = InstructionQueue("MEM_W0", [isa.Sync(), READ, isa.Sync()], CFG)
    with pytest.raises(ProgramError):
        for c in range(T15 + 5):
            q.step(c, T15 if c > 0 else None)


def test_repeat_without_data_raises():
    q = InstructionQueue("MEM_W0", [isa.Sync(), isa.Nop(1), isa.Repeat(1, 1)], CFG)
    with pytest.raises(ProgramError):
        for c in range(T15 + 5):
            q.step(c, T15 if c > 0 else None)


def test_other_barrier_length():
    cfg = ChipConfig(barrier_cycles=5)
    out, done, _ = run_queue([isa.Sync(), isa.Nop(3), READ, isa.Repeat(2, 4), VXM], config=cfg, notify_at=0)
    assert [c for c, _ in out] == [8, 12, 16, 17]
    assert done == 17


AGREEMENT_QUEUES = [
    [isa.Sync(), isa.Nop(3), READ, isa.Repeat(2, 4), VXM],
    [isa.Notify(), VXM, VXM, isa.Nop(7), VXM, isa.Repeat(3, 1)],
    [isa.Sync(), READ, isa.Repeat(2, 3), isa.Repeat(3, 2), isa.Nop(1), READ2, isa.Repeat(1, 9)],
    [isa.Sync()],
    [isa.Sync(), isa.Nop(40), READ],
    [isa.Sync(), READ, READ2, READ, isa.Nop(2), isa.Nop(3), READ2],
]


@pytest.mark.parametrize("queue", AGREEMENT_QUEUES)
@pytest.mark.parametrize("barrier", [T15, 1, 4])
def test_dispatch_times_agrees_with_queue(queue, barrier):
    cfg = ChipConfig(barrier_cycles=barrier)
    unit = "VXM_A0" if isinstance(queue[0], isa.Notify) else "MEM_W0"
    out, done, _ = run_queue(queue, config=cfg, notify_at=0, n_cycles=barrier + 120, unit=unit)
    assert out == dispatch_times(queue, cfg)
    assert done is not None
