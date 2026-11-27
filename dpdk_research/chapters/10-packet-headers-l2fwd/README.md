# Chapter 10: Parsing and Building Packets: lib/net, Checksums and l2fwd

Open `index.html` in a browser (works from `file://`, no network needed).
It covers the `lib/net` header structs, byte order, the DPDK 26.11 IPv6 types,
the Internet checksum (by hand, with lib/net, incremental RFC 1624), safe
parsing with `rte_pktmbuf_read()`, `rte_net_get_ptype()`, building frames
(ARP, ICMP, UDP, IPv6, VLAN/QinQ, VXLAN, a custom packed header), the
Ethernet CRC, and the `l2fwd` sample with its TX buffer and drain timer.
Page widgets live in `ch10.js`.

## Code (`code/`)

| File | What it does |
|---|---|
| `gen_pcaps.py` | writes `mixed.pcap` (15 test frames, 3 deliberately broken), `in.pcap` (100 UDP frames), `empty.pcap` |
| `parse_pcap.c` | bounds-checked parser over net_pcap; verifies checksums; compares with `rte_net_get_ptype()`; 2-segment `rte_pktmbuf_read()` demo |
| `build_packets.c` | builds 8 frames (ARP, ICMP, IPv4/UDP, IPv6/UDP, VXLAN, packed toy header, 802.1Q, QinQ) into `built.pcap`, plus CRC32 into `built.crc` |
| `verify.py` | independent Python check of every checksum and CRC in `built.pcap` |
| `cksum_lab.c` | the IPv4 checksum by hand vs `rte_raw_cksum`/`rte_ipv4_cksum`, byte order, incremental update, UDP pseudo-header |
| `mini_l2fwd.c` | l2fwd's core loop (`rte_eth_tx_buffer` + TSC drain timer) on two net_ring loopback ports |
| `l2check.py` | checks the MAC rewrite in the pcaps written by the prebuilt `dpdk-l2fwd` |
| `packed_old.c` | compile-only: what the removed `__rte_packed` does to old code |
| `ch10_port.h` | one-call port init used by the programs |
| `solutions/` | exercise 1 (`parse_vlan.c`), 2 (`incr_cksum.c`), 3 (`mini_l2fwd_filter.c`) |

## Run

```sh
source <path>/dpdk-env.sh        # sets PKG_CONFIG_PATH and DPDK_SRC
cd code
./run.sh 2>&1 | tee my_output.txt # builds and runs everything, about 25 s
make clean
```

All runs use `--no-pci --no-huge`, a unique `--file-prefix=ch10-*`, virtual
ports only (`net_pcap`, `net_ring`) and `timeout`. `expected_output.txt` is the
real captured output of `run.sh` on the course VM (DPDK 26.11.0, 4-core
Xeon VM). `mini_l2fwd` packet counts depend on CPU speed and vary between
runs; they come from a software loopback, not a NIC.

Notes: `build_packets.c` and `cksum_lab.c` use experimental APIs
(`rte_vlan_insert_tpid`, `rte_ipv4_cksum_simple`), so the Makefile passes
`-DALLOW_EXPERIMENTAL_API`. `parse_pcap` flags a real 26.11 quirk:
`rte_net_get_ptype()` classifies IPv4/ICMP as `L2_ETHER L3_IPV4 INNER_L4_FRAG`.
