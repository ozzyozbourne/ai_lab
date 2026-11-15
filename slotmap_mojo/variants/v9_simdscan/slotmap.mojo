"""v9: v8 + the 64-slot occupancy mask is built with explicit AVX-512-width
SIMD for 16-byte slots (4 slots per 64-byte load, version bits picked out
with a multiply), and a branch-free scalar loop otherwise.

v8: v7 + bitmask-scanning iterators and likely() hints.

Iteration reads the occupancy bit of 64 slots at a time into a UInt64 mask
(branch-free), then walks the set bits with count-trailing-zeros. A sparse map
costs one hard-to-predict branch per 64 slots instead of one per slot.

v7: v6 + leaner hot paths: internal counters are Int (no zero-extension
moves), the bounds check is a predictable branch that redirects to the
sentinel slot, and `pop(key) raises` gives a removal path that does not
materialize an Optional.

v6: v5 + the free-index stack lives inside the slot array, in a 4-byte cell
per slot placed after the version (for 8-byte-aligned values this is the
slot's padding, so it costs no memory). Stack entry j is in the cell of slot
j. One allocation, one realloc on growth, and the stack's store stream has
the same stride and page offsets as the slot stream, which removes the 4K
store/load aliasing stalls a separate stack array showed.

v5 (locals): v4 + remove() copies the key fields into locals before any
store so they are not reloaded.

v4: v3 + no element counter: len() == slots_in_use - 1 - free_count, so
insert/remove each do one fewer read-modify-write; the free stack is
re-allocated without copying on growth (growth only happens when it is
empty).

v3: v2 + the free list is a separate LIFO stack of slot indices instead of
being threaded through the vacant slots. Reuse order is identical (LIFO), but
an insert no longer has to read the vacant slot to find the next free index,
so consecutive inserts into scattered free slots do not form a pointer-chasing
chain of cache misses. The stack has the same capacity as the slot array, so
it never needs its own capacity check.

v2: v1 + branchless bounds check (out-of-range index is clamped to the
sentinel slot 0, whose even version can never equal a key version, which is
always odd), so a lookup has one data-dependent branch instead of two.

v1: v0 + hot-path field/pointer hoisting into locals.

v0: straight port of Rust `slotmap::SlotMap` (basic.rs) to Mojo.

Array-of-structs slots: [ value-or-next_free | version:u32 ], free list
threaded through vacant slots, sentinel at index 0, libc realloc growth.
"""
from std.bit import count_trailing_zeros
from std.ffi import external_call
from std.memory import pack_bits
from std.iter import downcast
from std.sys import size_of, align_of
from std.sys.intrinsics import likely, unlikely
from std.traits import IsTriviallyDeinitable

comptime BytePtr = MutPointer[Byte, MutUntrackedOrigin]


struct Key(Equatable, ImplicitlyCopyable, Movable):
    var idx: UInt32
    var version: UInt32  # always odd

    @inline(.always)
    def __init__(out self, idx: UInt32, version: UInt32):
        self.idx = idx
        self.version = version | 1

    @inline(.always)
    def as_ffi(self) -> UInt64:
        return (UInt64(self.version) << 32) | UInt64(self.idx)


struct InvalidKey(ImplicitlyCopyable, Movable):
    """Raised by `SlotMap.pop` when the key does not refer to a live element."""

    def __init__(out self):
        pass


struct SlotMap[V: Movable & Deinitable](Movable, Sized):
    comptime VER_OFF = (size_of[Self.V]() + 3) & ~3
    comptime CELL_OFF = Self.VER_OFF + 4
    comptime ALIGN = max(align_of[Self.V](), 4)
    comptime STRIDE = (Self.CELL_OFF + 4 + Self.ALIGN - 1) & ~(Self.ALIGN - 1)

    var _data: BytePtr
    var _len: Int  # slots in use (incl. sentinel + vacant)
    var _cap: Int  # slots allocated
    var _nfree: Int  # entries on the free-index stack

    def __init__(out self, *, capacity: Int = 0):
        comptime assert Self.ALIGN <= 16, "over-aligned values unsupported"
        self._cap = capacity + 1
        self._data = external_call["malloc", BytePtr](self._cap * Self.STRIDE)
        self._len = 1
        self._nfree = 0
        self._data.unsafe_offset(Self.VER_OFF).unsafe_bitcast[UInt32]()[] = 0

    def __deinit__(deinit self):
        comptime if not IsTriviallyDeinitable[Self.V]:
            var i = 1
            while i < self._len:
                var sp = self._data.unsafe_offset(i * Self.STRIDE)
                if (
                    sp.unsafe_offset(Self.VER_OFF).unsafe_bitcast[UInt32]()[]
                    & 1
                    != 0
                ):
                    sp.unsafe_bitcast[Self.V]().unsafe_deinit_pointee()
                i += 1
        external_call["free", NoneType](self._data)

    @inline(.always)
    def __len__(self) -> Int:
        return self._len - 1 - self._nfree

    @inline(.always)
    def capacity(self) -> Int:
        return self._cap - 1

    @inline(.never)
    def _grow(mut self):
        var new_cap = max(self._cap * 2, 4)
        self._data = external_call["realloc", BytePtr](
            self._data, new_cap * Self.STRIDE
        )
        self._cap = new_cap

    @inline(.always)
    def insert(mut self, var value: Self.V) -> Key:
        var nfree = self._nfree
        var data = self._data
        if nfree != 0:
            nfree -= 1
            var idx = data.unsafe_offset(
                nfree * Self.STRIDE + Self.CELL_OFF
            ).unsafe_bitcast[UInt32]()[]
            self._nfree = nfree
            var sp = data.unsafe_offset(Int(idx) * Self.STRIDE)
            var vp = sp.unsafe_offset(Self.VER_OFF).unsafe_bitcast[UInt32]()
            var occ = vp[] | 1
            sp.unsafe_bitcast[Self.V]().unsafe_write(value^)
            vp[] = occ
            return Key(idx, occ)
        var len = self._len
        if unlikely(len == self._cap):
            self._grow()
            data = self._data
        var sp = data.unsafe_offset(len * Self.STRIDE)
        sp.unsafe_bitcast[Self.V]().unsafe_write(value^)
        sp.unsafe_offset(Self.VER_OFF).unsafe_bitcast[UInt32]()[] = 1
        self._len = len + 1
        return Key(UInt32(len), 1)

    @inline(.always)
    def _slot(self, idx: UInt32) -> BytePtr:
        """Pointer to slot `idx`, or to the sentinel slot (whose even version
        never matches a key) if `idx` is out of range."""
        var i = Int(idx)
        if unlikely(i >= self._len):
            i = 0
        return self._data.unsafe_offset(i * Self.STRIDE)

    @inline(.always)
    def contains_key(self, key: Key) -> Bool:
        return (
            self._slot(key.idx)
            .unsafe_offset(Self.VER_OFF)
            .unsafe_bitcast[UInt32]()[]
            == key.version
        )

    @inline(.always)
    def _release(mut self, sp: BytePtr, idx: UInt32, kver: UInt32):
        """Marks an occupied slot vacant and pushes it on the free stack."""
        var n1 = self._nfree + 1
        var data = self._data
        sp.unsafe_offset(Self.VER_OFF).unsafe_bitcast[UInt32]()[] = kver + 1
        self._nfree = n1
        data.unsafe_offset(
            n1 * Self.STRIDE + (Self.CELL_OFF - Self.STRIDE)
        ).unsafe_bitcast[UInt32]()[] = idx

    @inline(.always)
    def remove(mut self, key: Key) -> Optional[Self.V]:
        """Removes `key`, returning its value, or None if it is not live."""
        var idx = key.idx
        var kver = key.version
        var sp = self._slot(idx)
        if unlikely(
            sp.unsafe_offset(Self.VER_OFF).unsafe_bitcast[UInt32]()[] != kver
        ):
            return None
        var value = sp.unsafe_bitcast[Self.V]().unsafe_take_pointee()
        self._release(sp, idx, kver)
        return Optional[Self.V](value^)

    @inline(.always)
    def pop(mut self, key: Key) raises InvalidKey -> Self.V:
        """Removes `key` and returns its value; raises if it is not live."""
        var idx = key.idx
        var kver = key.version
        var sp = self._slot(idx)
        if unlikely(
            sp.unsafe_offset(Self.VER_OFF).unsafe_bitcast[UInt32]()[] != kver
        ):
            raise InvalidKey()
        var value = sp.unsafe_bitcast[Self.V]().unsafe_take_pointee()
        self._release(sp, idx, kver)
        return value^

    @inline(.always)
    def get(
        ref self, key: Key
    ) -> Optional[Pointer[Self.V, origin_of(self)]]:
        var sp = self._slot(key.idx)
        if unlikely(
            sp.unsafe_offset(Self.VER_OFF).unsafe_bitcast[UInt32]()[]
            != key.version
        ):
            return None
        return Optional(
            Pointer[Self.V, origin_of(self)](unsafe_from_address=Int(sp))
        )

    @inline(.always)
    def values(
        ref self,
    ) -> _Values[downcast[Self.V, Copyable], origin_of(self)] where conforms_to(
        Self.V, Copyable
    ):
        return _Values[downcast[Self.V, Copyable], origin_of(self)](
            _Scan[Self.STRIDE, Self.VER_OFF](Int(self._data), self._len)
        )

    @inline(.always)
    def items(ref self) -> _Items[Self.V, origin_of(self)]:
        return _Items[Self.V, origin_of(self)](
            _Scan[Self.STRIDE, Self.VER_OFF](Int(self._data), self._len)
        )


struct _Scan[STRIDE: Int, VER_OFF: Int](ImplicitlyCopyable, Movable):
    """Cursor over the occupied slots of a slot array.

    Invariant: `_mask` holds the not-yet-visited occupied slots of the 64-slot
    chunk starting at address `_base`; it is zero only when exhausted.
    """

    var _base: Int  # address of the slot for bit 0 of the current chunk
    var _mask: UInt64
    var _end: Int  # address one past the last slot in use
    var _data: Int  # address of slot 0

    @inline(.always)
    def __init__(out self, data: Int, len: Int):
        # Chunks start at slot 0 (the sentinel, whose version is even, so it
        # never shows up in a mask).
        self._data = data
        self._base = data - 64 * Self.STRIDE
        self._end = data + len * Self.STRIDE
        self._mask = 0
        self._refill()

    @inline(.always)
    def _occ(self, addr: Int) -> UInt64:
        return UInt64(
            BytePtr(unsafe_from_address=addr + Self.VER_OFF)[] & 1
        )

    @inline(.always)
    def _scan_tail(self, base: Int, end: Int) -> UInt64:
        """Branch-free occupancy mask of the (at most 64) slots in
        [base, end)."""
        var m = UInt64(0)
        var a = base
        var shift = UInt64(0)
        while a < end:
            m |= self._occ(a) << shift
            shift += 1
            a += Self.STRIDE
        return m

    @inline(.always)
    def _refill(mut self):
        """Advances to the next chunk that has an occupied slot."""
        var base = self._base
        var end = self._end
        var m = UInt64(0)
        while True:
            base += 64 * Self.STRIDE
            var left = end - base
            if left <= 0:
                m = 0
                break
            comptime if Self.STRIDE == 16 and Self.VER_OFF == 8:
                if likely(left >= 64 * Self.STRIDE):
                    # 16 loads of 4 slots each. Viewed as 16 UInt32 lanes, the
                    # versions sit in lanes 2, 6, 10 and 14.
                    var wp = MutPointer[UInt32, MutUntrackedOrigin](
                        unsafe_from_address=base
                    )
                    comptime for blk in range(16):
                        var v = wp.unsafe_offset(blk * 16).unsafe_load[
                            width=16
                        ]()
                        var k = UInt64(pack_bits[DType.uint16]((v & 1).eq(1)))
                        # Gather bits 2, 6, 10, 14 into bits 14..17.
                        m |= ((((k & 0x4444) * 0x1248) >> 14) & 0xF) << UInt64(
                            4 * blk
                        )
                else:
                    m = self._scan_tail(base, end)
            else:
                m = self._scan_tail(
                    base, min(end, base + 64 * Self.STRIDE)
                )
            if m != 0:
                break
        self._base = base
        self._mask = m

    @inline(.always)
    def done(self) -> Bool:
        return self._mask == 0

    @inline(.always)
    def take(mut self) -> Int:
        """Returns the address of the next occupied slot and advances.
        Must not be called when `done()`."""
        var m = self._mask
        var addr = self._base + Int(count_trailing_zeros(m)) * Self.STRIDE
        m &= m - 1
        self._mask = m
        if unlikely(m == 0):
            self._refill()
        return addr


@fieldwise_init
struct _Values[mut: Bool, //, V: Copyable & Deinitable, origin: Origin[mut=mut]](
    ImplicitlyCopyable, Iterable, Iterator
):
    comptime Element = Self.V
    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = Self

    var _scan: _Scan[SlotMap[Self.V].STRIDE, SlotMap[Self.V].VER_OFF]

    @inline(.always)
    def __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        return self.copy()

    @inline(.always)
    def __next__(
        mut self,
    ) raises StopIteration -> ref[Self.origin] Self.Element:
        if self._scan.done():
            raise StopIteration()
        return Pointer[Self.V, Self.origin](
            unsafe_from_address=self._scan.take()
        )[]


@fieldwise_init
struct _Item[mut: Bool, //, V: Movable & Deinitable, origin: Origin[mut=mut]](
    ImplicitlyCopyable, Movable
):
    var key: Key
    var value: Pointer[Self.V, Self.origin]


struct _Items[mut: Bool, //, V: Movable & Deinitable, origin: Origin[mut=mut]](
    ImplicitlyCopyable, Iterable, Iterator
):
    comptime Element = _Item[Self.V, Self.origin]
    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = Self

    var _scan: _Scan[SlotMap[Self.V].STRIDE, SlotMap[Self.V].VER_OFF]
    var _data: Int

    @inline(.always)
    def __init__(
        out self, scan: _Scan[SlotMap[Self.V].STRIDE, SlotMap[Self.V].VER_OFF]
    ):
        self._scan = scan
        self._data = scan._data

    @inline(.always)
    def __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        return self.copy()

    @inline(.always)
    def __next__(mut self) raises StopIteration -> Self.Element:
        if self._scan.done():
            raise StopIteration()
        var addr = self._scan.take()
        var ver = BytePtr(
            unsafe_from_address=addr + SlotMap[Self.V].VER_OFF
        ).unsafe_bitcast[UInt32]()[]
        return _Item[Self.V, Self.origin](
            Key(UInt32((addr - self._data) // SlotMap[Self.V].STRIDE), ver),
            Pointer[Self.V, Self.origin](unsafe_from_address=addr),
        )
