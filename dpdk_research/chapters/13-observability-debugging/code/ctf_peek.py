#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
# Chapter 13: ctf_peek.py - a tiny reader for DPDK's CTF trace output.
#
# usage: python3 -I ctf_peek.py <trace dir> [max events to print]
#
# babeltrace is the real tool (not installed on the course VM). This reader
# understands just enough of what lib/eal/common/eal_common_trace_ctf.c
# writes to show the structure:
#   metadata     TSDL text: types, the clock (freq), and one "event {}"
#                block per REGISTERED tracepoint (id, name, fields)
#   channel0_N   one binary stream per thread that ever traced:
#                packet.header  = u32 magic 0xc1fc1fc1 + 16-byte uuid
#                packet.context = u32 cpu_id + char name[32] (thread name)
#                then events, each 8-byte aligned:
#                   u64 header = timestamp (low 48 bits) | event id << 48
#                   payload fields packed in declaration order
import glob
import os
import re
import struct
import sys

SIZES = {"uint8_t": 1, "int8_t": 1, "uint16_t": 2, "int16_t": 2,
         "uint32_t": 4, "int32_t": 4, "uint64_t": 8, "int64_t": 8,
         "uintptr_t": 8, "long": 8, "size_t": 8, "time_t": 4,
         "float": 4, "double": 8}
FMT = {1: "B", 2: "H", 4: "I", 8: "Q"}


def parse_metadata(path):
    text = open(path).read()
    freq = int(re.search(r"freq\s*=\s*(\d+)", text).group(1))
    events = {}
    for m in re.finditer(r"event \{\s*id = (\d+);\s*name = \"([^\"]+)\";"
                         r"\s*fields := struct \{(.*?)\};\s*\};", text, re.S):
        fields = []
        for line in m.group(3).strip().splitlines():
            line = line.strip().rstrip(";")
            if not line:
                continue
            typ, name = line.split()[0], line.split()[1]
            arr = re.match(r"(\w+)\[(\d+)\]", name)
            if arr:
                fields.append((arr.group(1), typ, int(arr.group(2))))
            else:
                fields.append((name, typ, 0))
        events[int(m.group(1))] = (m.group(2), fields)
    return freq, events, len(text)


def decode(buf, off, fields):
    out = []
    for name, typ, n in fields:
        if n:                      # bounded string / byte array
            raw = buf[off:off + n]
            off += n
            out.append(f"{name}=\"{raw.split(b'\0')[0].decode(errors='replace')}\"")
        else:
            sz = SIZES.get(typ, 8)
            v = struct.unpack_from("<" + FMT[sz], buf, off)[0]
            off += sz
            out.append(f"{name}={v}")
    return off, " ".join(out)


def main():
    d = sys.argv[1]
    limit = int(sys.argv[2]) if len(sys.argv) > 2 else 6
    freq, events, mlen = parse_metadata(os.path.join(d, "metadata"))
    print(f"metadata: {mlen} bytes, {len(events)} event types registered, "
          f"clock {freq} Hz")
    for ch in sorted(glob.glob(os.path.join(d, "channel0_*"))):
        buf = open(ch, "rb").read()
        magic = struct.unpack_from("<I", buf, 0)[0]
        cpu = struct.unpack_from("<I", buf, 20)[0]
        tname = buf[24:56].split(b"\0")[0].decode()
        off, n, t0, prev, shown, counts = 56, 0, None, None, 0, {}
        lines = []
        while off + 8 <= len(buf):
            hdr = struct.unpack_from("<Q", buf, off)[0]
            ts, eid = hdr & ((1 << 48) - 1), hdr >> 48
            if eid not in events:
                break
            name, fields = events[eid]
            end, txt = decode(buf, off + 8, fields)
            t0 = ts if t0 is None else t0
            if shown < limit:
                gap = "" if prev is None else f" (+{(ts - prev) * 1e9 / freq:.0f} ns)"
                lines.append(f"    t={(ts - t0) * 1e6 / freq:9.3f} us{gap:>14}  "
                             f"{name}: {txt}")
                shown += 1
            prev = ts
            counts[name] = counts.get(name, 0) + 1
            n += 1
            off = (end + 7) & ~7          # events are 8-byte aligned
        print(f"{os.path.basename(ch)}: {len(buf)} bytes, magic 0x{magic:08x}, "
              f"cpu_id {cpu}, thread '{tname}', {n} events {counts}")
        for line in lines:
            print(line)
        if n > shown:
            print(f"    ... {n - shown} more")


main()
