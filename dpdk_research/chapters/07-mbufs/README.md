# Chapter 07: rte_mbuf, the packet buffer

Open `index.html` in a browser (works from `file://`, no network). It covers the
two-cache-line `struct rte_mbuf`, pktmbuf pools, headroom/data/tailroom helpers,
chains, refcnt and clones, external buffers and pinned extbuf pools, `ol_flags`,
packet types and `tx_offload`, dynamic fields/flags (including the timestamp
helpers), pool ops selection, `rte_pktmbuf_prefree_seg`, ownership and debug aids.

Interactive parts (in `ch07.js`): mbuf anatomy explorer, chain view
(predict-then-step), refcnt/clone/extbuf animation (predict-then-step), and the
`ol_flags` bit-board with offload recipes.

## Code (`code/`)

| Program | Shows |
|---|---|
| `mbuf_anatomy.c` | `offsetof` of every field, element layout, append/prepend/adj/trim, overflow returns, flag/ptype names, `tx_offload` packing |
| `payload_build.c` | payload-first then prepend an app header, private area, `rte_pktmbuf_dump`, `rte_hexdump` |
| `chain_demo.c` | `rte_pktmbuf_chain`, `rte_pktmbuf_read` across a boundary, `rte_pktmbuf_linearize`, `-EOVERFLOW` |
| `clone_extbuf.c` | multicast with header + clone pools (refcnt 1 -> 4 -> 0), external buffer with `free_cb` |
| `dynfield_demo.c` | dynfield/dynflag registration, Rx/Tx timestamp registration, lookup, `rte_mbuf_dyn_dump` |
| `pool_ops.c` | `rte_mbuf_best_mempool_ops`, `--mbuf-pool-ops-name`, `rte_pktmbuf_pool_create_by_ops`, `rte_pktmbuf_pool_create_extbuf`, `rte_pktmbuf_prefree_seg` |
| `debug_aids.c` | `rte_mbuf_check` reasons, a silent double free, mbuf history in a non-debug build |
| `solutions/vlan_prepend.c` | exercise 1: VLAN tag inserted in place via the headroom |
| `solutions/clone_corrupt.c` | exercise 2: writing/prepending into clones corrupts shared data; `rte_pktmbuf_copy` fix |
| `solutions/dyn_order.c` | exercise 3: dynfield offsets depend on registration order |

Build and run everything (no devices, no hugepages, `--no-pci --no-huge -m 64`,
unique `--file-prefix=ch07-*`, 20 s timeouts, runtime dirs cleaned on exit):

```sh
source <path>/dpdk-env.sh     # sets PKG_CONFIG_PATH for the installed DPDK 26.11
cd code && ./run.sh           # or: make && ./mbuf_anatomy -l 0 --no-pci --no-huge -m 64 --file-prefix=ch07-anat
```

`code/expected_output.txt` is the real output of `./run.sh` on the course VM
(4-core Xeon, IOVA as VA). Addresses and the ns timings in `pool_ops` vary per run.
