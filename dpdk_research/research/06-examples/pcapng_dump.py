import struct, sys
d = open(sys.argv[1], 'rb').read(); off = 0; names = {0x0A0D0D0A:'SHB',1:'IDB',6:'EPB',5:'ISB',3:'SPB'}
cnt = {}
while off + 8 <= len(d):
    t, l = struct.unpack_from('<II', d, off)
    n = names.get(t, hex(t)); cnt[n] = cnt.get(n, 0) + 1
    if t == 6 and cnt[n] <= 3:
        ifid, th, tl, caplen, origlen = struct.unpack_from('<IIIII', d, off + 8)
        pkt = d[off+28:off+28+caplen]
        sport = struct.unpack('!H', pkt[34:36])[0]
        print(f"EPB if={ifid} ts={(th<<32)|tl} caplen={caplen} dst={pkt[0:6].hex(':')} src={pkt[6:12].hex(':')} udp.sport={sport}")
    off += l
print(cnt)
