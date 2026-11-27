import socket, struct, sys, time
def csum(b):
    if len(b)%2: b+=b'\0'
    s=sum(struct.unpack('!%dH'%(len(b)//2),b)); s=(s>>16)+(s&0xffff); s+=s>>16; return (~s)&0xffff
s=socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0800)); s.bind((sys.argv[1],0)); s.settimeout(1.0)
end=time.time()+float(sys.argv[2])
while time.time()<end:
    try: f,addr=s.recvfrom(65535)
    except socket.timeout: continue
    if addr[2]!=socket.PACKET_HOST and addr[2]!=socket.PACKET_BROADCAST and addr[2]!=0: pass
    ip=f[14:34]; proto=ip[9]; tl=struct.unpack('!H',ip[2:4])[0]
    if ip[12:16]!=bytes([10,58,0,2]): continue
    l4=f[34:14+tl]; ph=ip[12:20]+struct.pack('!BBH',0,proto,len(l4))
    print("captured proto=%d len=%d ip_csum_valid=%s l4_csum_valid=%s" % (proto, len(f), csum(ip)==0, csum(ph+l4)==0), flush=True)
