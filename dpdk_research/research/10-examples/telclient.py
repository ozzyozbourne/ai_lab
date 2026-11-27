import socket, json, sys, glob
path = f"/var/run/dpdk/{sys.argv[1]}/dpdk_telemetry.v2"
s = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
s.connect(path)
print("hello:", s.recv(16384).decode())
for cmd in sys.argv[2:]:
    s.send(cmd.encode())
    print(cmd, "->", json.loads(s.recv(16384)))
