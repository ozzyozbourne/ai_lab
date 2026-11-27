import socket, struct, sys, time
iface, n = sys.argv[1], int(sys.argv[2])
s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW)
s.bind((iface, 0))
dst = b'\xff'*6; src = b'\x02\x00\x00\x00\x06\x01'
payload = b'DPDK-ch06 ' * 5
ip = struct.pack('!BBHHHBBH4s4s', 0x45, 0, 20+8+len(payload), 1, 0, 64, 17, 0,
                 socket.inet_aton('10.66.0.1'), socket.inet_aton('10.66.0.2'))
udp = struct.pack('!HHHH', 1234, 5678, 8+len(payload), 0)
frame = dst + src + b'\x08\x00' + ip + udp + payload
for i in range(n):
    s.send(frame)
print("sent", n)
