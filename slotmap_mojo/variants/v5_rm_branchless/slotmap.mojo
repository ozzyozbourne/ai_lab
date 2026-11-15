"""v5 (branchless): v4 + branch-free remove() for trivially copyable values.

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
from std.ffi import external_call
from std.iter import downcast
from std.sys import size_of, align_of
from std.traits import IsTriviallyCopyable, IsTriviallyDeinitable

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


struct SlotMap[V: Movable & Deinitable](Movable, Sized):
    comptime VER_OFF = (size_of[Self.V]() + 3) & ~3
    comptime ALIGN = max(align_of[Self.V](), 4)
    comptime STRIDE = (Self.VER_OFF + 4 + Self.ALIGN - 1) & ~(Self.ALIGN - 1)

    var _data: BytePtr
    var _len: UInt32  # slots in use (incl. sentinel + vacant)
    var _cap: UInt32  # slots allocated
    var _free: MutPointer[UInt32, MutUntrackedOrigin]  # stack of free idx
    var _nfree: UInt32

    def __init__(out self, *, capacity: Int = 0):
        comptime assert Self.ALIGN <= 16, "over-aligned values unsupported"
        self._cap = UInt32(capacity + 1)
        self._data = external_call["malloc", BytePtr](
            Int(self._cap) * Self.STRIDE
        )
        self._free = external_call[
            "malloc", MutPointer[UInt32, MutUntrackedOrigin]
        ](Int(self._cap) * 4)
        self._len = 1
        self._nfree = 0
        self._ver(0)[] = 0

    def __deinit__(deinit self):
        var i = UInt32(1)
        while i < self._len:
            if self._ver(i)[] & 1 != 0:
                self._val(i).unsafe_deinit_pointee()
            i += 1
        external_call["free", NoneType](self._data)
        external_call["free", NoneType](self._free)

    @inline(.always)
    def _val(self, i: UInt32) -> MutPointer[Self.V, MutUntrackedOrigin]:
        return self._data.unsafe_offset(Int(i) * Self.STRIDE).unsafe_bitcast[
            Self.V
        ]()

    @inline(.always)
    def _ver(self, i: UInt32) -> MutPointer[UInt32, MutUntrackedOrigin]:
        return self._data.unsafe_offset(
            Int(i) * Self.STRIDE + Self.VER_OFF
        ).unsafe_bitcast[UInt32]()

    @inline(.always)
    def __len__(self) -> Int:
        return Int(self._len) - 1 - Int(self._nfree)

    @inline(.always)
    def capacity(self) -> Int:
        return Int(self._cap) - 1

    @inline(.never)
    def _grow(mut self):
        var new_cap = max(self._cap * 2, 4)
        self._data = external_call["realloc", BytePtr](
            self._data, Int(new_cap) * Self.STRIDE
        )
        # Growth only happens when no slot is free, so the stack is empty
        # and can be replaced without copying.
        external_call["free", NoneType](self._free)
        self._free = external_call[
            "malloc", MutPointer[UInt32, MutUntrackedOrigin]
        ](Int(new_cap) * 4)
        self._cap = new_cap

    @inline(.always)
    def insert(mut self, var value: Self.V) -> Key:
        var nfree = self._nfree
        if nfree != 0:
            nfree -= 1
            var idx = self._free[unsafe_offset=Int(nfree)]
            self._nfree = nfree
            var sp = self._data.unsafe_offset(Int(idx) * Self.STRIDE)
            var vp = sp.unsafe_offset(Self.VER_OFF).unsafe_bitcast[UInt32]()
            var occ = vp[] | 1
            sp.unsafe_bitcast[Self.V]().unsafe_write(value^)
            vp[] = occ
            return Key(idx, occ)
        var len = self._len
        if len == self._cap:
            self._grow()
        var sp = self._data.unsafe_offset(Int(len) * Self.STRIDE)
        sp.unsafe_bitcast[Self.V]().unsafe_write(value^)
        sp.unsafe_offset(Self.VER_OFF).unsafe_bitcast[UInt32]()[] = 1
        self._len = len + 1
        return Key(len, 1)

    @inline(.always)
    def _slot(self, idx: UInt32) -> BytePtr:
        """Pointer to slot `idx`, or to the sentinel slot if out of range."""
        var i = idx if idx < self._len else UInt32(0)
        return self._data.unsafe_offset(Int(i) * Self.STRIDE)

    @inline(.always)
    def contains_key(self, key: Key) -> Bool:
        return (
            self._slot(key.idx)
            .unsafe_offset(Self.VER_OFF)
            .unsafe_bitcast[UInt32]()[]
            == key.version
        )

    @inline(.always)
    def remove(mut self, key: Key) -> Optional[Self.V]:
        var idx = key.idx
        var kver = key.version
        var sp = self._slot(idx)
        var vp = sp.unsafe_offset(Self.VER_OFF).unsafe_bitcast[UInt32]()
        var ver = vp[]
        comptime if IsTriviallyCopyable[Self.V] and IsTriviallyDeinitable[Self.V]:
            # Branch-free: every store is performed unconditionally and is a
            # no-op on a miss (the version is rewritten unchanged, the free
            # stack entry lands above the top and the top is not advanced).
            var hit = ver == kver
            var h = UInt32(Int(hit))
            var value = sp.unsafe_bitcast[Self.V]().unsafe_take_pointee()
            var nfree = self._nfree
            var free = self._free
            vp[] = ver + h
            self._nfree = nfree + h
            free[unsafe_offset=Int(nfree)] = idx
            if hit:
                return Optional[Self.V](value^)
            return None
        else:
            if ver != kver:
                return None
            var value = sp.unsafe_bitcast[Self.V]().unsafe_take_pointee()
            var nfree = self._nfree
            var free = self._free
            vp[] = kver + 1
            self._nfree = nfree + 1
            free[unsafe_offset=Int(nfree)] = idx
            return Optional[Self.V](value^)

    @inline(.always)
    def get(
        ref self, key: Key
    ) -> Optional[Pointer[Self.V, origin_of(self)]]:
        var sp = self._slot(key.idx)
        if (
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
            self._data.unsafe_offset(Self.STRIDE),
            self._data.unsafe_offset(Int(self._len) * Self.STRIDE),
        )

    @inline(.always)
    def items(ref self) -> _Items[Self.V, origin_of(self)]:
        return _Items[Self.V, origin_of(self)](self._data, 1, self._len)


@fieldwise_init
struct _Values[mut: Bool, //, V: Copyable & Deinitable, origin: Origin[mut=mut]](
    ImplicitlyCopyable, Iterable, Iterator
):
    comptime Element = Self.V
    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = Self

    var _cur: BytePtr
    var _end: BytePtr

    @inline(.always)
    def __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        return self.copy()

    @inline(.always)
    def __next__(
        mut self,
    ) raises StopIteration -> ref[Self.origin] Self.Element:
        while self._cur != self._end:
            var p = self._cur
            self._cur = p.unsafe_offset(SlotMap[Self.V].STRIDE)
            if (
                p.unsafe_offset(SlotMap[Self.V].VER_OFF).unsafe_bitcast[
                    UInt32
                ]()[]
                & 1
                != 0
            ):
                return Pointer[Self.V, Self.origin](unsafe_from_address=Int(p))[]
        raise StopIteration()


@fieldwise_init
struct _Item[mut: Bool, //, V: Movable & Deinitable, origin: Origin[mut=mut]](
    ImplicitlyCopyable, Movable
):
    var key: Key
    var value: Pointer[Self.V, Self.origin]


@fieldwise_init
struct _Items[mut: Bool, //, V: Movable & Deinitable, origin: Origin[mut=mut]](
    ImplicitlyCopyable, Iterable, Iterator
):
    comptime Element = _Item[Self.V, Self.origin]
    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = Self

    var _data: BytePtr
    var _idx: UInt32
    var _len: UInt32

    @inline(.always)
    def __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        return self.copy()

    @inline(.always)
    def __next__(mut self) raises StopIteration -> Self.Element:
        while self._idx < self._len:
            var i = self._idx
            self._idx = i + 1
            var p = self._data.unsafe_offset(Int(i) * SlotMap[Self.V].STRIDE)
            var ver = p.unsafe_offset(SlotMap[Self.V].VER_OFF).unsafe_bitcast[
                UInt32
            ]()[]
            if ver & 1 != 0:
                return _Item[Self.V, Self.origin](
                    Key(i, ver),
                    Pointer[Self.V, Self.origin](unsafe_from_address=Int(p)),
                )
        raise StopIteration()
