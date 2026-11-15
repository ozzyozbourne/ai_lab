"""v12: v10 + a custom allocator for the slot array.

Small maps use libc malloc/realloc. Once the slot array reaches 8 MiB it moves
(once) into its own anonymous mmap region that is
  * reserved at 16x the size needed (address space only, MAP_NORESERVE), so
    the map keeps growing in place with no realloc, no copy and no syscall;
  * 2 MiB aligned and madvise(MADV_HUGEPAGE)d, so it is backed by transparent
    huge pages, which cuts TLB misses on random access by a large factor.
Linux only; other targets keep the malloc path.

v10: v7 + likely() hints + iterators restructured so that `__next__` checks
for exhaustion first and has a single return: the cursor always rests on the
next occupied slot (or the end). This keeps the per-slot scan of Rust's
iterator but lets the compiler fold the for-loop protocol into a tight loop.

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
from std.ffi import external_call
from std.iter import downcast
from std.memory import unsafe_memcpy
from std.sys import CompilationTarget, size_of, align_of
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


comptime HUGE = 2 << 20  # transparent huge page size
comptime REGION_MIN = 8 << 20  # slot arrays this big move to a region
comptime RESERVE_FACTOR = 16


def _region_map(bytes: Int) -> Int:
    """Maps a 2 MiB-aligned, huge-page-advised anonymous region of `bytes`
    bytes (a multiple of 2 MiB). Returns its address, or 0 on failure."""
    # PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS|MAP_NORESERVE
    var raw = external_call["mmap", Int](0, bytes + HUGE, 3, 0x4022, -1, 0)
    if raw == -1:
        return 0
    var base = (raw + HUGE - 1) & ~(HUGE - 1)
    # Trim the unaligned head and tail so exactly [base, base+bytes) remains.
    if base != raw:
        _ = external_call["munmap", Int32](raw, base - raw)
    var tail = raw + HUGE - base
    if tail != 0:
        _ = external_call["munmap", Int32](base + bytes, tail)
    _ = external_call["madvise", Int32](base, bytes, 14)  # MADV_HUGEPAGE
    return base


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
    var _region: Int  # bytes of the mmap region holding the slots; 0 = malloc

    def __init__(out self, *, capacity: Int = 0):
        comptime assert Self.ALIGN <= 16, "over-aligned values unsupported"
        self._cap = capacity + 1
        self._len = 1
        self._nfree = 0
        self._region = 0
        var bytes = self._cap * Self.STRIDE
        var addr = 0
        comptime if CompilationTarget.is_linux():
            if bytes >= REGION_MIN:
                var region = (bytes + HUGE - 1) & ~(HUGE - 1)
                addr = _region_map(region)
                if addr != 0:
                    self._region = region
                    self._cap = region // Self.STRIDE
        if addr == 0:
            addr = external_call["malloc", Int](bytes)
        self._data = BytePtr(unsafe_from_address=addr)
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
        self._release_storage()

    def _release_storage(self):
        if self._region != 0:
            _ = external_call["munmap", Int32](Int(self._data), self._region)
        else:
            external_call["free", NoneType](Int(self._data))

    @inline(.always)
    def __len__(self) -> Int:
        return self._len - 1 - self._nfree

    @inline(.always)
    def capacity(self) -> Int:
        return self._cap - 1

    @inline(.never)
    def _grow(mut self):
        var new_cap = max(self._cap * 2, 4)
        var bytes = new_cap * Self.STRIDE
        comptime if CompilationTarget.is_linux():
            if bytes >= REGION_MIN:
                # Move into (or to a larger) reserved region. Reserve far more
                # address space than needed so this happens at most once per
                # 16x of growth; untouched pages cost nothing.
                var want = (
                    bytes * RESERVE_FACTOR + HUGE - 1
                ) & ~(HUGE - 1)
                var floor = (bytes + HUGE - 1) & ~(HUGE - 1)
                var addr = _region_map(want)
                while addr == 0 and want != floor:
                    want = max(floor, (want // 2 + HUGE - 1) & ~(HUGE - 1))
                    addr = _region_map(want)
                if addr != 0:
                    var fresh = BytePtr(unsafe_from_address=addr)
                    unsafe_memcpy(
                        dest=fresh, src=self._data, count=self._len * Self.STRIDE
                    )
                    self._release_storage()
                    self._data = fresh
                    self._region = want
                    self._cap = want // Self.STRIDE
                    return
        # malloc path. (Only reachable from a region if mmap failed.)
        if self._region != 0:
            var fresh = BytePtr(
                unsafe_from_address=external_call["malloc", Int](bytes)
            )
            unsafe_memcpy(
                dest=fresh, src=self._data, count=self._len * Self.STRIDE
            )
            self._release_storage()
            self._data = fresh
            self._region = 0
        else:
            self._data = BytePtr(
                unsafe_from_address=external_call["realloc", Int](
                    Int(self._data), bytes
                )
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
            _Scan[Self.STRIDE, Self.VER_OFF](Int(self._data), self._len),
            Int(self._data),
        )


struct _Scan[STRIDE: Int, VER_OFF: Int](ImplicitlyCopyable, Movable):
    """Cursor over the occupied slots of a slot array.

    Invariant: `_cur` is the address of the next occupied slot, or `_end`.
    """

    var _cur: Int
    var _end: Int

    @inline(.always)
    def __init__(out self, data: Int, len: Int):
        # Slot 0 is the sentinel (never occupied); start from it and skip.
        self._cur = data
        self._end = data + len * Self.STRIDE
        self._skip()

    @inline(.always)
    def _skip(mut self):
        """Advances `_cur` to the next occupied slot after it, or the end."""
        var a = self._cur
        var end = self._end
        while True:
            a += Self.STRIDE
            if a == end:
                break
            if BytePtr(unsafe_from_address=a + Self.VER_OFF)[] & 1 != 0:
                break
        self._cur = a

    @inline(.always)
    def done(self) -> Bool:
        return self._cur == self._end

    @inline(.always)
    def take(mut self) -> Int:
        """Returns the address of the next occupied slot and advances.
        Must not be called when `done()`."""
        var addr = self._cur
        self._skip()
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


@fieldwise_init
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
            Key(
                UInt32(UInt(addr - self._data) // UInt(SlotMap[Self.V].STRIDE)),
                ver,
            ),
            Pointer[Self.V, Self.origin](unsafe_from_address=addr),
        )
