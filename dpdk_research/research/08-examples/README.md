# Chapter-08 research examples (accelerators: cryptodev, compressdev, eventdev, dmadev, bbdev, rawdev)

All verified on DPDK 26.11.0, this VM, `--no-huge`, unique `--file-prefix`, no PCI.

```
source <scratchpad>/dpdk-env.sh
cc_dpdk() { gcc -O2 "$1.c" -o "$1" $(pkg-config --cflags libdpdk) $(pkg-config --libs --static libdpdk); }
```

| file | run | verified output |
|---|---|---|
| crypto_aes_cbc_sha.c | `./crypto_aes_cbc_sha --no-huge -m 256 --no-pci --file-prefix=ch08c --vdev=crypto_openssl0` | ciphertext `6aa8b73a...837fd8`, HMAC `3c430304...3e50c4`; both match `openssl enc -aes-128-cbc -nopad` / `openssl dgst -sha256 -hmac` |
| crypto_asym_modexp.c | `... --file-prefix=ch08x --vdev=crypto_openssl0` | `0x614b49e77c2112d0736ee11cdeb818a7` == python `pow(b,65537,n)` |
| comp_zlib_roundtrip.c | `... --file-prefix=ch08z --vdev=compress_zlib0` | 4000 B -> 56 B (1.4%), decompress matches |
| event_sw_atomic.c | `./event_sw_atomic -l 0-2 --no-huge -m 256 --no-pci --file-prefix=ch08e --vdev=event_sw0 -- atomic\|ordered\|parallel` | atomic: each flow pinned to 1 worker, 0 collisions, 0 reorder; ordered: ~2000 same-flow collisions, 0 reorder at sink; parallel: ~1000 collisions AND ~1000 reordered |
| event_timer_demo.c | `./event_timer_demo -l 0-1 --no-huge -m 256 --no-pci --file-prefix=ch08t --vdev=event_sw0` | 6 armed, 1 cancelled (state 2), 5 expiry events at ~50/100/150/200/250 ms |
| event_crypto_adapter_new.c | `./event_crypto_adapter_new -l 0-1 --no-huge -m 256 --no-pci --file-prefix=ch08ca --vdev=event_sw0 --vdev=crypto_openssl0` | caps=0x8 (SW service), 32 ops -> 32 CRYPTODEV events with flow 7 |
| dma_skeleton_copy.c | `./dma_skeleton_copy -l 0-1 --no-huge -m 256 --no-pci --file-prefix=ch08d --vdev=dma_skeleton0,lcore=1` | ring_idx 0..15, completions, 0 mismatches, burst_capacity 63 for nb_desc 64 |
| bbdev_null_loopback.c | `... --file-prefix=ch08bb --vdev=baseband_null0,max_nb_queues=2` | 16 enq / 16 deq in order |
| (rawdev) | any EAL app + `--vdev=rawdev_skeleton,selftest=1` | `Total tests: 12 Passed: 12` |
| mkpcap.py | `python3 mkpcap.py in.pcap 64 64` | IPv4/UDP pcap for net_pcap rx |
| ipsec_secgw_ep0.cfg | config for dpdk-ipsec-secgw (see research note: app starts, traffic dropped - unresolved) | |

Prebuilt apps (in $DPDK_SRC/build/app and build/examples) verified:
- dpdk-test-crypto-perf throughput on crypto_openssl (1.45 Mops @64B AES-CBC+SHA1) and on crypto_scheduler(round-robin over 2x crypto_null).
- dpdk-test-eventdev order_queue / perf_queue on event_sw with `-s 0x8` service core.
- dpdk-l2fwd-crypto with net_pcap + crypto_openssl (64/64 packets encrypted).
- dpdk-l2fwd-event, dpdk-eventdev_pipeline with event_sw + net_pcap(infinite_rx=1).
- dpdk-dma with dma_skeleton + net_pcap (skeleton copy thread bottleneck ~2 Mops/s vs 11 Mpps rx).
