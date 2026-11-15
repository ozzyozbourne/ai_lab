"""SlotMap for Mojo: storage with stable, versioned keys.

A port of Rust's `slotmap::SlotMap` (https://github.com/orlp/slotmap), tuned
to be at least as fast. Like the original it is an array of slots, each with a
version counter (odd = occupied); a `Key` is a slot handle plus the version it
was created with, so a stale key is detected by a version mismatch.

Where it differs from the Rust implementation (see the research log for the
measurements behind each choice):

* Free slots are tracked in a LIFO stack of handles instead of a linked list
  threaded through the vacant slots. Reuse order is the same, but an insert
  does not have to read a (cold) vacant slot to find the next free one, so
  refilling scattered holes is not a pointer chase.
* The stack lives inside the slot array: entry j is a 4-byte cell in slot j,
  placed after the version. For 8-byte-aligned values that is padding, so it
  is free.
* No element counter: `len == slots in use - 1 - free count`.
* A key stores its slot index pre-multiplied (`slot * STRIDE / SCALE`), so the
  slot address is a single scaled-index addressing mode with no shift.
* Iteration walks runs of occupied slots found with a 64-slot occupancy mask;
  a map without holes is a single run and is never scanned.
* Custom allocator: the slot array uses libc malloc/realloc until it reaches
  8 MiB, then moves once into its own mmap region that is reserved at 16x the
  needed size (grows in place, no realloc or copy) and is backed by
  transparent huge pages (far fewer TLB misses on random access). Linux only;
  elsewhere it stays on malloc.

v16 in the hill-climb history (variants/): v15 + pre-scaled key handles.
"""
from std.bit import count_trailing_zeros, pop_count
from std.ffi import external_call
from std.iter import downcast
from std.memory import unsafe_memcpy
from std.os import abort
from std.sys import CompilationTarget, align_of, size_of
from std.sys._assembly import inlined_assembly
from std.sys.intrinsics import likely, unlikely
from std.traits import IsTriviallyDeinitable

comptime BytePtr = MutPointer[Byte, MutUntrackedOrigin]

comptime HUGE = 2 << 20  # transparent huge page size
comptime REGION_MIN = 8 << 20  # slot arrays this big move to an mmap region
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


struct Key(Equatable, ImplicitlyCopyable, Movable):
    """Handle to an element of a `SlotMap`.

    Treat both fields as opaque: `slot` is the slot index pre-multiplied by a
    per-value-type constant, and `version` is always odd. Use
    `SlotMap.index_of`, `SlotMap.key_to_ffi` and `SlotMap.key_from_ffi` to
    convert.
    """

    var slot: UInt32
    var version: UInt32

    @inline(.always)
    def __init__(out self, *, slot: UInt32, odd_version: UInt32):
        self.slot = slot
        self.version = odd_version


struct InvalidKey(ImplicitlyCopyable, Movable):
    """Raised by `SlotMap.pop` when the key does not refer to a live element."""

    def __init__(out self):
        pass


struct SlotMap[V: Movable & Deinitable](Movable, Sized):
    # Slot layout: [ value | pad | version: u32 | free-stack cell: u32 | pad ]
    comptime VER_OFF = (size_of[Self.V]() + 3) & ~3
    comptime CELL_OFF = Self.VER_OFF + 4
    comptime ALIGN = max(align_of[Self.V](), 4)
    comptime STRIDE = (Self.CELL_OFF + 4 + Self.ALIGN - 1) & ~(Self.ALIGN - 1)
    # A handle h addresses the slot at byte offset h * SCALE; SCALE is an x86
    # addressing-mode scale, so no shift or multiply is needed.
    comptime SCALE = 8 if Self.STRIDE % 8 == 0 else 4
    comptime UNIT = Self.STRIDE // Self.SCALE  # handle units per slot

    var _data: BytePtr
    var _len: Int  # handle one past the last slot in use (incl. sentinel)
    var _cap: Int  # handle one past the last slot allocated
    var _nfree: Int  # free-stack height, in handle units
    var _region: Int  # bytes of the mmap region holding the slots; 0 = malloc

    def __init__(out self, *, capacity: Int = 0):
        comptime assert Self.ALIGN <= 16, "over-aligned values unsupported"
        var slots = capacity + 1
        self._len = Self.UNIT
        self._nfree = 0
        self._region = 0
        var bytes = slots * Self.STRIDE
        var addr = 0
        comptime if CompilationTarget.is_linux():
            if bytes >= REGION_MIN:
                var region = (bytes + HUGE - 1) & ~(HUGE - 1)
                addr = _region_map(region)
                if addr != 0:
                    self._region = region
                    slots = region // Self.STRIDE
        if addr == 0:
            addr = external_call["malloc", Int](bytes)
        self._cap = Self._clamp_cap(slots) * Self.UNIT
        self._data = BytePtr(unsafe_from_address=addr)
        # Slot 0 is a sentinel that is never occupied (even version).
        self._data.unsafe_offset(Self.VER_OFF).unsafe_bitcast[UInt32]()[] = 0

    def __deinit__(deinit self):
        comptime if not IsTriviallyDeinitable[Self.V]:
            var h = Self.UNIT
            while h < self._len:
                var sp = self._data.unsafe_offset(h * Self.SCALE)
                if (
                    sp.unsafe_offset(Self.VER_OFF).unsafe_bitcast[UInt32]()[]
                    & 1
                    != 0
                ):
                    sp.unsafe_bitcast[Self.V]().unsafe_deinit_pointee()
                h += Self.UNIT
        self._release_storage()

    @staticmethod
    @inline(.always)
    def _clamp_cap(slots: Int) -> Int:
        """Handles are 32-bit, which bounds the number of slots."""
        return min(slots, (1 << 32) // Self.UNIT)

    def _release_storage(self):
        if self._region != 0:
            _ = external_call["munmap", Int32](Int(self._data), self._region)
        else:
            external_call["free", NoneType](Int(self._data))

    @inline(.always)
    def __len__(self) -> Int:
        return (self._len - self._nfree) // Self.UNIT - 1

    @inline(.always)
    def capacity(self) -> Int:
        return self._cap // Self.UNIT - 1

    @inline(.never)
    def _grow(mut self):
        var old_slots = self._cap // Self.UNIT
        if old_slots >= (1 << 32) // Self.UNIT:
            abort("SlotMap is full")
        var new_slots = Self._clamp_cap(max(old_slots * 2, 4))
        var bytes = new_slots * Self.STRIDE
        var used = self._len * Self.SCALE
        comptime if CompilationTarget.is_linux():
            if bytes >= REGION_MIN:
                # Move into (or to a larger) reserved region. Reserve far more
                # address space than needed so this happens at most once per
                # 16x of growth; untouched pages cost nothing.
                var floor = (bytes + HUGE - 1) & ~(HUGE - 1)
                var want = (bytes * RESERVE_FACTOR + HUGE - 1) & ~(HUGE - 1)
                var addr = _region_map(want)
                while addr == 0 and want != floor:
                    want = max(floor, (want // 2 + HUGE - 1) & ~(HUGE - 1))
                    addr = _region_map(want)
                if addr != 0:
                    var fresh = BytePtr(unsafe_from_address=addr)
                    unsafe_memcpy(dest=fresh, src=self._data, count=used)
                    self._release_storage()
                    self._data = fresh
                    self._region = want
                    self._cap = (
                        Self._clamp_cap(want // Self.STRIDE) * Self.UNIT
                    )
                    return
        if self._region != 0:
            # Only reachable if mmap failed: fall back to the heap.
            var fresh = BytePtr(
                unsafe_from_address=external_call["malloc", Int](bytes)
            )
            unsafe_memcpy(dest=fresh, src=self._data, count=used)
            self._release_storage()
            self._data = fresh
            self._region = 0
        else:
            self._data = BytePtr(
                unsafe_from_address=external_call["realloc", Int](
                    Int(self._data), bytes
                )
            )
        self._cap = new_slots * Self.UNIT

    # ---- keys ------------------------------------------------------------

    @staticmethod
    @inline(.always)
    def index_of(key: Key) -> Int:
        """The slot index of `key` (1-based; what Rust's slotmap calls idx)."""
        return Int(key.slot) // Self.UNIT

    @staticmethod
    @inline(.always)
    def key_to_ffi(key: Key) -> UInt64:
        """Same encoding as Rust's `KeyData::as_ffi`."""
        return (UInt64(key.version) << 32) | UInt64(
            UInt(key.slot) // UInt(Self.UNIT)
        )

    @staticmethod
    @inline(.always)
    def key_from_ffi(value: UInt64) -> Key:
        """Inverse of `key_to_ffi`. Any input yields a key that is safe to
        use (it simply may not refer to a live element)."""
        var idx = value & 0xFFFF_FFFF
        if idx >= UInt64((1 << 32) // Self.UNIT):
            idx = 0
        return Key(
            slot=UInt32(idx * UInt64(Self.UNIT)),
            odd_version=UInt32(value >> 32) | 1,
        )

    # ---- element access --------------------------------------------------

    @inline(.always)
    def _version_ptr(
        self, h: Int
    ) -> MutPointer[UInt32, MutUntrackedOrigin]:
        return self._data.unsafe_offset(
            h * Self.SCALE + Self.VER_OFF
        ).unsafe_bitcast[UInt32]()

    @inline(.always)
    def _value_ptr(self, h: Int) -> MutPointer[Self.V, MutUntrackedOrigin]:
        return self._data.unsafe_offset(h * Self.SCALE).unsafe_bitcast[
            Self.V
        ]()

    @inline(.always)
    def contains_key(self, key: Key) -> Bool:
        var h = Int(key.slot)
        return h < self._len and self._version_ptr(h)[] == key.version

    @inline(.always)
    def get(
        ref self, key: Key
    ) -> Optional[Pointer[Self.V, origin_of(self)]]:
        """Pointer to the value for `key`, or None if it is not live."""
        var h = Int(key.slot)
        if unlikely(h >= self._len):
            return None
        if unlikely(self._version_ptr(h)[] != key.version):
            return None
        return Optional(
            Pointer[Self.V, origin_of(self)](
                unsafe_from_address=Int(self._value_ptr(h))
            )
        )

    # ---- insertion / removal ---------------------------------------------

    @inline(.always)
    def insert(mut self, var value: Self.V) -> Key:
        var nfree = self._nfree
        var data = self._data
        if nfree != 0:
            # Reuse the most recently freed slot.
            nfree -= Self.UNIT
            var handle = data.unsafe_offset(
                nfree * Self.SCALE + Self.CELL_OFF
            ).unsafe_bitcast[UInt32]()[]
            self._nfree = nfree
            var sp = data.unsafe_offset(Int(handle) * Self.SCALE)
            var vp = sp.unsafe_offset(Self.VER_OFF).unsafe_bitcast[UInt32]()
            var occ = vp[] | 1
            sp.unsafe_bitcast[Self.V]().unsafe_write(value^)
            vp[] = occ
            return Key(slot=handle, odd_version=occ)
        var len = self._len
        if unlikely(len == self._cap):
            self._grow()
            data = self._data
        var sp = data.unsafe_offset(len * Self.SCALE)
        sp.unsafe_bitcast[Self.V]().unsafe_write(value^)
        sp.unsafe_offset(Self.VER_OFF).unsafe_bitcast[UInt32]()[] = 1
        self._len = len + Self.UNIT
        return Key(slot=UInt32(len), odd_version=1)

    @inline(.always)
    def _release(mut self, h: Int, kver: UInt32):
        """Marks occupied slot `h` vacant and pushes it on the free stack."""
        var n1 = self._nfree + Self.UNIT
        var data = self._data
        data.unsafe_offset(h * Self.SCALE + Self.VER_OFF).unsafe_bitcast[
            UInt32
        ]()[] = kver + 1
        self._nfree = n1
        data.unsafe_offset(
            n1 * Self.SCALE + (Self.CELL_OFF - Self.STRIDE)
        ).unsafe_bitcast[UInt32]()[] = UInt32(h)

    @inline(.always)
    def remove(mut self, key: Key) -> Optional[Self.V]:
        """Removes `key`, returning its value, or None if it is not live."""
        var h = Int(key.slot)
        var kver = key.version
        if unlikely(h >= self._len):
            return None
        if unlikely(self._version_ptr(h)[] != kver):
            return None
        var value = self._value_ptr(h).unsafe_take_pointee()
        self._release(h, kver)
        return Optional[Self.V](value^)

    @inline(.always)
    def pop(mut self, key: Key) raises InvalidKey -> Self.V:
        """Removes `key` and returns its value; raises if it is not live.

        Same operation as `remove`, in the style of `Dict.pop`. It is the
        faster of the two because no `Optional[V]` has to be materialized.
        """
        var h = Int(key.slot)
        var kver = key.version
        if unlikely(h >= self._len):
            raise InvalidKey()
        if unlikely(self._version_ptr(h)[] != kver):
            raise InvalidKey()
        var value = self._value_ptr(h).unsafe_take_pointee()
        self._release(h, kver)
        return value^

    # ---- iteration -------------------------------------------------------

    @inline(.always)
    def _scan(self) -> _Scan[Self.STRIDE, Self.VER_OFF]:
        return _Scan[Self.STRIDE, Self.VER_OFF](
            Int(self._data), self._len * Self.SCALE, self._nfree == 0
        )

    @inline(.always)
    def values(
        ref self,
    ) -> _Values[downcast[Self.V, Copyable], origin_of(self)] where conforms_to(
        Self.V, Copyable
    ):
        return _Values[downcast[Self.V, Copyable], origin_of(self)](
            self._scan()
        )

    @inline(.always)
    def items(ref self) -> _Items[Self.V, origin_of(self)]:
        return _Items[Self.V, origin_of(self)](self._scan(), Int(self._data))


struct _Scan[STRIDE: Int, VER_OFF: Int](ImplicitlyCopyable, Movable):
    """Cursor over the occupied slots of a slot array, one run at a time.

    Invariants: [`_cur`, `_run_end`) is the unvisited part of the current run
    of occupied slots; it is empty only when the scan is exhausted. `_mask`
    holds the occupied slots after that run within the 64-slot chunk at
    address `_base`.
    """

    var _cur: Int
    var _run_end: Int
    var _mask: UInt64
    var _base: Int
    var _end: Int  # address one past the last slot in use
    var _long_runs: Bool  # current chunk is walked run by run

    @inline(.always)
    def __init__(out self, data: Int, used_bytes: Int, dense: Bool):
        self._end = data + used_bytes
        self._mask = 0
        self._long_runs = True
        if dense:
            # No vacant slots: everything after the sentinel is one run.
            self._cur = data + Self.STRIDE
            self._run_end = self._end
            self._base = self._end
        else:
            self._cur = 0
            self._run_end = 0
            self._base = data - 64 * Self.STRIDE
            self._next_run()

    @inline(.always)
    def _occ(self, addr: Int) -> UInt64:
        var bit = UInt64(
            BytePtr(unsafe_from_address=addr + Self.VER_OFF)[] & 1
        )
        # Identity through an empty inline-asm statement: keeps each bit a
        # separate scalar so the SLP vectorizer does not turn the mask build
        # into a (much slower) byte-insert chain.
        return inlined_assembly[
            "", UInt64, constraints="=r,0", has_side_effect=False
        ](bit)

    @inline(.always)
    def _chunk_mask(self, base: Int, end: Int) -> UInt64:
        """Occupancy mask of the (up to 64) slots in [base, end)."""
        var m = UInt64(0)
        if likely(end - base >= 64 * Self.STRIDE):
            var j = 0
            while j < 64:
                var a = base + j * Self.STRIDE
                var byte = UInt64(0)
                comptime for b in range(8):
                    byte |= self._occ(a + b * Self.STRIDE) << UInt64(b)
                m |= byte << UInt64(j)
                j += 8
        else:
            var a = base
            var shift = UInt64(0)
            while a < end:
                m |= self._occ(a) << shift
                shift += 1
                a += Self.STRIDE
        return m

    @inline(.always)
    def _next_run(mut self):
        """Loads the next run of occupied slots, or leaves the run empty."""
        var m = self._mask
        var base = self._base
        var end = self._end
        var long_runs = self._long_runs
        while m == 0:
            base += 64 * Self.STRIDE
            if base >= end:
                self._base = base
                self._cur = end
                self._run_end = end
                return
            m = self._chunk_mask(base, end)
            # Walk the chunk run by run only if its runs are long (average
            # >= 8 slots); otherwise step one occupied slot at a time, which
            # keeps the end-of-run branch in `take` predictable.
            # Number of runs = number of 0->1 transitions.
            long_runs = pop_count(m) >= 8 * pop_count(m & ~(m << 1))
            self._long_runs = long_runs
        var start = count_trailing_zeros(m)
        var cur = base + Int(start) * Self.STRIDE
        self._base = base
        self._cur = cur
        if long_runs:
            var length = count_trailing_zeros(~(m >> start))
            # Adding the lowest set bit carries through the lowest run of
            # ones; and-ing with the original clears exactly that run.
            self._mask = m & (m + (UInt64(1) << start))
            self._run_end = cur + Int(length) * Self.STRIDE
        else:
            self._mask = m & (m - 1)
            self._run_end = cur + Self.STRIDE

    @inline(.always)
    def done(self) -> Bool:
        return self._cur == self._run_end

    @inline(.always)
    def take(mut self) -> Int:
        """Returns the address of the next occupied slot and advances.
        Must not be called when `done()`."""
        var addr = self._cur
        var next = addr + Self.STRIDE
        self._cur = next
        if next == self._run_end:
            self._next_run()
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
                slot=UInt32(
                    UInt(addr - self._data) // UInt(SlotMap[Self.V].SCALE)
                ),
                odd_version=ver,
            ),
            Pointer[Self.V, Self.origin](unsafe_from_address=addr),
        )
