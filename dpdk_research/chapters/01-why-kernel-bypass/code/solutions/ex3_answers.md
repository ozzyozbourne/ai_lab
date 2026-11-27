# Chapter 01, exercise 3: when AF_XDP or plain sockets beat DPDK

1. **An HTTP/gRPC API server.** It needs a full, well-tested TCP stack, TLS,
   and the usual tools (`ss`, `tcpdump`, `iptables`). Its packet rate is far
   below what the kernel can handle, so polling cores and hugepages buy nothing.
   Use plain sockets with `epoll` or `io_uring`.
2. **A DDoS filter or firewall on a host that also runs other services.**
   XDP drops unwanted packets in the kernel driver before an `sk_buff` exists,
   and AF_XDP sends selected flows to user space, while the kernel keeps the NIC
   for SSH, monitoring and everything else. DPDK would take the whole NIC (unless
   the NIC has a bifurcated driver such as mlx5).
3. **A monitoring or telemetry agent deployed on every server in a fleet.**
   It cannot dedicate a core that spins at 100%, reserve hugepages, or unbind a
   NIC on machines it does not own. A raw socket, AF_PACKET with `PACKET_MMAP`,
   or AF_XDP in its wake-up (`poll()`) mode fits.

Other good answers: low-rate control-plane protocols (BGP, OSPF: keep them in the
kernel, see the ch30 capstone), laptops or battery devices (power), and teams
with no measured performance problem (operational cost).
