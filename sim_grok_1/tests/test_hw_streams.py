"""Stream registers and MEM words, tested directly."""

import numpy as np
import pytest

from tsp.errors import EmptyOperandError
from tsp.hw.mem import Memory
from tsp.hw.streams import StreamFile, StreamVal


def val(vid):
    return StreamVal(np.zeros(4, dtype=np.uint8), vid, f"v{vid}")


def test_shift_east_and_west_one_position_per_cycle():
    sf = StreamFile(2, 5)
    sf.put("E", 0, 1, val(0))
    sf.put("W", 1, 3, val(1))
    sf.shift()
    assert sf.get("E", 0, 2).vid == 0 and sf.get("E", 0, 1) is None
    assert sf.get("W", 1, 2).vid == 1 and sf.get("W", 1, 3) is None


def test_values_fall_off_the_edges():
    sf = StreamFile(1, 3)
    sf.put("E", 0, 2, val(0))
    sf.put("W", 0, 0, val(1))
    sf.shift()
    assert not sf.any_occupied()


def test_put_returns_overwritten_value():
    sf = StreamFile(1, 3)
    assert sf.put("E", 0, 1, val(0)) is None
    assert sf.put("E", 0, 1, val(1)).vid == 0
    assert sf.get("E", 0, 1).vid == 1


def test_occupied_order_dir_stream_position():
    sf = StreamFile(2, 3)
    sf.put("W", 0, 0, val(0))
    sf.put("E", 1, 0, val(1))
    sf.put("E", 0, 2, val(2))
    sf.put("E", 0, 1, val(3))
    order = [(d, s, x) for d, s, x, _ in sf.occupied()]
    assert order == [("E", 0, 1), ("E", 0, 2), ("E", 1, 0), ("W", 0, 0)]


def test_memory_read_write_and_unwritten():
    m = Memory(4, 8)
    with pytest.raises(EmptyOperandError):
        m.read("MEM_W0", 3)
    m.write("MEM_W0", 3, bytes([1, 2, 3, 4]))
    got = m.read("MEM_W0", 3)
    assert got.tolist() == [1, 2, 3, 4]
    got[0] = 9  # a read returns a copy
    assert m.read("MEM_W0", 3).tolist() == [1, 2, 3, 4]
    with pytest.raises(EmptyOperandError):
        m.read("MEM_W0", 8)
