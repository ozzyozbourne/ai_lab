import struct, socket, sys
out, n = sys.argv[1], int(sys.argv[2])
with open(out, 'wb') as f:
    f.write(struct.pack('<IHHiIII', 0xa1b2c3d4, 2, 4, 0, 0, 65535, 1))
    for i in range(n):
        payload = b'pkt%05d' % i
        ip = struct.pack('!BBHHHBBH4s4s', 0x45, 0, 28+len(payload), i, 0, 64, 17, 0,
             socket.inet_aton('192.0.2.%d' % (1 + i % 4)), socket.inet_aton('198.51.100.1'))
        udp = struct.pack('!HHHH', 1000 + i % 8, 53, 8+len(payload), 0)
        fr = b'\x02\x00\x00\x00\x00\x02' + b'\x02\x00\x00\x00\x00\x01' + b'\x08\x00' + ip + udp + payload
        f.write(struct.pack('<IIII', 1700000000 + i, 0, len(fr), len(fr)) + fr)
