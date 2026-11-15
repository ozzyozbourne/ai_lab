"""Benchmark for the Mojo SlotMap. Mirrors rust_bench/src/main.rs
workload-for-workload (same PRNG, same op order, same checksums)."""
from std.benchmark import keep
from std.sys import argv
from std.time import perf_counter_ns

from slotmap import Key, SlotMap

comptime Map = SlotMap[UInt64]


@inline(.always)
def ffi(k: Key) -> UInt64:
    """Key in Rust's `KeyData::as_ffi` encoding (index | version << 32)."""
    return k.as_ffi()  # KEY-FFI


struct Rng:
    var s: UInt64

    def __init__(out self, seed: UInt64):
        self.s = seed

    @inline(.always)
    def next(mut self) -> UInt64:
        self.s += 0x9E3779B97F4A7C15
        var z = self.s
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) * 0x94D049BB133111EB
        return z ^ (z >> 31)

    @inline(.always)
    def below(mut self, n: UInt64) -> UInt64:
        return ((self.next() >> 32) * n) >> 32


def shuffle(mut v: List[Key], mut rng: Rng):
    var p = v.unsafe_ptr()
    var i = len(v)
    while i > 1:
        var j = Int(rng.below(UInt64(i)))
        i -= 1
        var t = p[unsafe_offset=i]
        p[unsafe_offset=i] = p[unsafe_offset=j]
        p[unsafe_offset=j] = t


def build(n: Int, mut keys: List[Key]) -> Map:
    var sm = Map()
    keys.clear()
    keys.reserve(n)
    for i in range(n):
        keys.append(sm.insert(UInt64(i) * 3 + 1))
    return sm^


@fieldwise_init
struct Res(ImplicitlyCopyable, Movable):
    var t: UInt64
    var chk: UInt64


@inline(.always)
def now() -> UInt64:
    return UInt64(perf_counter_ns())


def selected(name: StaticString) -> Bool:
    var args = argv()
    if len(args) < 3:
        return True
    for part in String(args[2]).split(","):
        if String(name).find(String(part)) != -1:
            return True
    return False


comptime CAL_ITERS = 50000


@inline(.never)
def calib_once(seed: UInt64) -> UInt64:
    """Calibration: a dependent shift-xor-multiply chain (5 cycles per
    iteration; it has no closed form the compiler could exploit).
    Its wall time tracks the core's current clock speed, which lets results
    be reported in CPU cycles instead of nanoseconds."""
    var s = seed
    keep(s)
    var x = s
    var t = now()
    for _ in range(CAL_ITERS):
        x = (x ^ (x >> 29)) * 0xBF58476D1CE4E5B9
    var e = now() - t
    keep(x)
    return e


def calib() -> Float64:
    var best = UInt64.MAX
    for i in range(3):
        var e = calib_once(UInt64(i))
        if e < best:
            best = e
    return Float64(best)


def bench[f: def(Int, UInt64) thin -> Res](name: StaticString, n: Int, reps: Int):
    """Runs `f` `reps` times in batches bracketed by calibration runs. A batch
    only counts if the clock speed was the same before and after it. Prints
    name, n, cycles/op (best valid batch), checksum, raw best ns/op."""
    if not selected(name):
        return
    var best_cyc = Float64.MAX
    var best_ns = UInt64.MAX
    var chk = UInt64(0)
    var done = 0
    while done < reps:
        var c0 = calib()
        var start = now()
        var bmin = UInt64.MAX
        while done < reps and (
            bmin == UInt64.MAX or now() - start < 20000000
        ):
            var r = f(n, UInt64(done))
            if r.t < bmin:
                bmin = r.t
            chk += r.chk
            done += 1
        var c1 = calib()
        if bmin < best_ns:
            best_ns = bmin
        var d = c1 - c0
        if d < 0.0:
            d = -d
        if d <= 0.02 * c0:
            var cyc = Float64(bmin) / (0.5 * (c0 + c1)) * Float64(CAL_ITERS * 5)
            if cyc < best_cyc:
                best_cyc = cyc
    if best_cyc == Float64.MAX:
        best_cyc = -1.0
    print(
        name,
        n,
        best_cyc / Float64(n),
        chk,
        Float64(best_ns) / Float64(n),
        sep="\t",
    )


@inline(.never)
def insert_grow(n: Int, rep: UInt64) -> Res:
    var sm = Map()
    var chk = UInt64(0)
    var t = now()
    for i in range(n):
        chk += ffi(sm.insert(UInt64(i)))
    keep(sm)
    var e = now() - t
    return Res(e, chk + UInt64(len(sm)))


@inline(.never)
def insert_reserved(n: Int, rep: UInt64) -> Res:
    var sm = Map(capacity=n)
    var chk = UInt64(0)
    var t = now()
    for i in range(n):
        chk += ffi(sm.insert(UInt64(i)))
    keep(sm)
    var e = now() - t
    return Res(e, chk + UInt64(len(sm)))


@inline(.always)
def lookup_all(sm: Map, keys: List[Key]) -> Res:
    var kp = keys.unsafe_ptr()
    var n = len(keys)
    var sum = UInt64(0)
    var t = now()
    for i in range(n):
        if case .Some(p) = sm.get(kp[unsafe_offset=i]):
            sum += p[]
    var sum_out = sum
    keep(sum_out)
    return Res(now() - t, sum)


@inline(.never)
def get_seq(n: Int, rep: UInt64) -> Res:
    var keys = List[Key]()
    var sm = build(n, keys)
    return lookup_all(sm, keys)


@inline(.never)
def get_rand(n: Int, rep: UInt64) -> Res:
    var keys = List[Key]()
    var sm = build(n, keys)
    var rng = Rng(1 + 100 * rep)
    shuffle(keys, rng)
    return lookup_all(sm, keys)


def remove_half(mut sm: Map, mut keys: List[Key], seed: UInt64):
    var rng = Rng(seed)
    shuffle(keys, rng)
    var kp = keys.unsafe_ptr()
    for i in range(len(keys) // 2):
        _ = sm.remove(kp[unsafe_offset=i])


@inline(.never)
def get_mixed_rand(n: Int, rep: UInt64) -> Res:
    var keys = List[Key]()
    var sm = build(n, keys)
    remove_half(sm, keys, 2 + 100 * rep)
    var rng = Rng(3 + 100 * rep)
    shuffle(keys, rng)
    return lookup_all(sm, keys)


@inline(.always)
def sum_values(sm: Map) -> Res:
    var sum = UInt64(0)
    var t = now()
    for v in sm.values():
        sum += v
    var sum_out = sum
    keep(sum_out)
    return Res(now() - t, sum)


@inline(.never)
def iter_values_full(n: Int, rep: UInt64) -> Res:
    var keys = List[Key]()
    var sm = build(n, keys)
    return sum_values(sm)


@inline(.never)
def iter_values_half(n: Int, rep: UInt64) -> Res:
    var keys = List[Key]()
    var sm = build(n, keys)
    remove_half(sm, keys, 4 + 100 * rep)
    return sum_values(sm)


@inline(.never)
def iter_kv_half(n: Int, rep: UInt64) -> Res:
    var keys = List[Key]()
    var sm = build(n, keys)
    remove_half(sm, keys, 5 + 100 * rep)
    var sum = UInt64(0)
    var t = now()
    for it in sm.items():
        sum += it.value[] ^ ffi(it.key)
    var sum_out = sum
    keep(sum_out)
    return Res(now() - t, sum)


@inline(.always)
def remove_all(mut sm: Map, keys: List[Key]) -> Res:
    var kp = keys.unsafe_ptr()
    var n = len(keys)
    var sum = UInt64(0)
    var t = now()
    for i in range(n):
        if case .Some(v) = sm.remove(kp[unsafe_offset=i]):  # REMOVE-I
            sum += v
    keep(sm)
    var e = now() - t
    return Res(e, sum + UInt64(len(sm)))


@inline(.never)
def remove_seq(n: Int, rep: UInt64) -> Res:
    var keys = List[Key]()
    var sm = build(n, keys)
    return remove_all(sm, keys)


@inline(.never)
def remove_rand(n: Int, rep: UInt64) -> Res:
    var keys = List[Key]()
    var sm = build(n, keys)
    var rng = Rng(6 + 100 * rep)
    shuffle(keys, rng)
    return remove_all(sm, keys)


@inline(.never)
def reinsert_rand(n: Int, rep: UInt64) -> Res:
    var keys = List[Key]()
    var sm = build(n, keys)
    var rng = Rng(7 + 100 * rep)
    shuffle(keys, rng)
    var kp = keys.unsafe_ptr()
    for i in range(n):
        _ = sm.remove(kp[unsafe_offset=i])
    var chk = UInt64(0)
    var t = now()
    for i in range(n):
        chk += ffi(sm.insert(UInt64(i)))
    keep(sm)
    var e = now() - t
    return Res(e, chk + UInt64(len(sm)))


@inline(.never)
def churn(n: Int, rep: UInt64) -> Res:
    var keys = List[Key]()
    var sm = build(n, keys)
    var kp = keys.unsafe_ptr()
    var rng = Rng(8 + 100 * rep)
    var sum = UInt64(0)
    var t = now()
    for i in range(n):
        var j = Int(rng.below(UInt64(n)))
        if case .Some(v) = sm.remove(kp[unsafe_offset=j]):  # REMOVE-J
            sum += v
        var k = sm.insert(UInt64(i))
        kp[unsafe_offset=j] = k
        sum += ffi(k)
    keep(sm)
    var e = now() - t
    return Res(e, sum + UInt64(len(sm)))


def run(n: Int, reps: Int):
    bench[insert_grow]("insert_grow", n, reps)
    bench[insert_reserved]("insert_reserved", n, reps)
    bench[get_seq]("get_seq", n, reps)
    bench[get_rand]("get_rand", n, reps)
    bench[get_mixed_rand]("get_mixed_rand", n, reps)
    bench[iter_values_full]("iter_values_full", n, reps)
    bench[iter_values_half]("iter_values_half", n, reps)
    bench[iter_kv_half]("iter_kv_half", n, reps)
    bench[remove_seq]("remove_seq", n, reps)
    bench[remove_rand]("remove_rand", n, reps)
    bench[reinsert_rand]("reinsert_rand", n, reps)
    bench[churn]("churn", n, reps)


def main() raises:
    var scale = 1.0
    var args = argv()
    if len(args) > 1:
        scale = atof(args[1])
    for n in [1000, 100000, 2000000]:
        var reps = min(max(Int(2.0e7 * scale) // n, 7), 3000)
        run(n, reps)
