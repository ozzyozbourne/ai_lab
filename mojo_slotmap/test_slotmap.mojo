"""Randomized model test: SlotMap vs a Dict[UInt64, UInt64] model, plus
iterator agreement, stale keys, non-trivial value types and tiny values."""
from slotmap import Key, SlotMap

comptime M = SlotMap[UInt64]


struct Rng:
    var s: UInt64

    def __init__(out self, seed: UInt64):
        self.s = seed

    def next(mut self) -> UInt64:
        self.s += 0x9E3779B97F4A7C15
        var z = self.s
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) * 0x94D049BB133111EB
        return z ^ (z >> 31)


def check(cond: Bool, msg: StaticString) raises:
    if not cond:
        raise Error(String(msg))


def fuzz(seed: UInt64, steps: Int, bias: UInt64) raises:
    var rng = Rng(seed)
    var sm = SlotMap[UInt64]()
    var model = Dict[UInt64, UInt64]()  # key.as_ffi() -> value
    var live = List[Key]()
    var dead = List[Key]()
    for step in range(steps):
        var r = rng.next() % 100
        if r < bias or len(live) == 0:
            var v = rng.next()
            var k = sm.insert(v)
            check(M.key_to_ffi(k) not in model, "fresh key collides")
            model[M.key_to_ffi(k)] = v
            live.append(k)
        elif r < 90:
            var j = Int(rng.next() % UInt64(len(live)))
            var k = live[j]
            live[j] = live[len(live) - 1]
            _ = live.pop()
            var got = sm.remove(k)
            check(Bool(got), "remove of live key failed")
            check(got.value() == model.pop(M.key_to_ffi(k)), "removed value wrong")
            dead.append(k)
        elif len(dead) > 0:
            var k = dead[Int(rng.next() % UInt64(len(dead)))]
            check(not sm.contains_key(k), "dead key reported live")
            check(not Bool(sm.get(k)), "dead key lookup hit")
            check(not Bool(sm.remove(k)), "dead key removed twice")
        check(len(sm) == len(model), "len mismatch")
        if step % 257 == 0:
            for k in live:
                check(sm.contains_key(k), "live key missing")
                if case .Some(p) = sm.get(k):
                    check(p[] == model[M.key_to_ffi(k)], "value mismatch")
                else:
                    raise Error("live key lookup missed")
            var n = 0
            var sum = UInt64(0)
            for v in sm.values():
                n += 1
                sum += v
            var msum = UInt64(0)
            for e in model.items():
                msum += e.value
            check(n == len(model) and sum == msum, "values() disagrees")
            n = 0
            for it in sm.items():
                n += 1
                check(model[M.key_to_ffi(it.key)] == it.value[], "items() pair wrong")
            check(n == len(model), "items() count wrong")
    # out-of-range and forged keys
    check(
        not sm.contains_key(M.key_from_ffi((1 << 32) | 4000000000)),
        "out-of-range key hit",
    )
    check(not sm.contains_key(M.key_from_ffi(0)), "sentinel key hit")
    for k in live:
        check(M.key_from_ffi(M.key_to_ffi(k)) == k, "ffi round trip")


def strings() raises:
    var sm = SlotMap[String]()
    var keys = List[Key]()
    for i in range(1000):
        keys.append(sm.insert(String("value-") + String(i)))
    for i in range(0, 1000, 2):
        var r = sm.remove(keys[i])
        check(r.value() == String("value-") + String(i), "string remove")
    for i in range(1, 1000, 2):
        if case .Some(p) = sm.get(keys[i]):
            check(p[] == String("value-") + String(i), "string get")
        else:
            raise Error("string key missing")
    for i in range(300):
        _ = sm.insert(String("again-") + String(i))
    check(len(sm) == 800, "string len")
    # remaining Strings are destroyed by SlotMap.__deinit__


def tiny() raises:
    var sm = SlotMap[UInt8]()
    var keys = List[Key]()
    for i in range(300):
        keys.append(sm.insert(UInt8(i % 251)))
    for i in range(0, 300, 3):
        _ = sm.remove(keys[i])
    var n = 0
    for it in sm.items():
        n += 1
        check(
            it.value[] == UInt8((SlotMap[UInt8].index_of(it.key) - 1) % 251),
            "tiny value",
        )
    check(n == 200, "tiny count")


def runs() raises:
    # Full 64-slot chunks inside a map that has holes, plus chunk edges.
    for holes in [1, 2, 63, 64, 65, 127, 128, 129, 500]:
        var sm = SlotMap[UInt64]()
        var keys = List[Key]()
        for i in range(700):
            keys.append(sm.insert(UInt64(i)))
        var want = UInt64(0)
        for i in range(700):
            if i % holes == holes - 1 or i == 0:
                _ = sm.remove(keys[i])
            else:
                want += UInt64(i)
        var got = UInt64(0)
        var n = 0
        for v in sm.values():
            got += v
            n += 1
        check(got == want and n == len(sm), "run iteration (values)")
        got = 0
        for it in sm.items():
            got += it.value[]
            check(
                UInt64(M.index_of(it.key) - 1) == it.value[],
                "run iteration (key)",
            )
        check(got == want, "run iteration (items)")
    var empty = SlotMap[UInt64]()
    for _ in empty.values():
        raise Error("empty map yielded a value")
    var k = empty.insert(1)
    _ = empty.remove(k)
    for _ in empty.values():
        raise Error("emptied map yielded a value")


def main() raises:
    runs()
    for seed in range(12):
        fuzz(UInt64(seed), 20000, 55)
        fuzz(UInt64(seed + 100), 20000, 35)
    fuzz(999, 300000, 60)
    strings()
    tiny()
    print("all slotmap tests passed")
