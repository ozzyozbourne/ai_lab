# Chapter 08: Your First Port (ethdev lifecycle and the burst API)

Open `index.html` in a browser (works from `file://`). Chapter widgets live in `ch08.js`.

## What is here

| File | What it shows |
|---|---|
| `code/port_explorer.c` | Port discovery, `rte_eth_dev_info_get`, rx_burst before start (dummy fp op), `-EBUSY` on configure while started, link/MAC/stats/xstats, deferred-start preview, close. `--nb-desc N --no-adjust` for the descriptor-limit error. |
| `code/lifecycle_rules.c` | Lifecycle calls in the wrong order and what ethdev answers. `-- --early-setup` calls queue setup before configure (`-EINVAL` on net_tap, SIGSEGV on net_null in 26.11). |
| `code/my_skeleton.c` | Commented rewrite of `examples/skeleton` with stats, pool sizing, `--burst N`, `--tx-buffer` (rte_eth_tx_buffer + 100 us drain), clean shutdown. |
| `code/burst_sweep.c` | Cycles/packet of the rx->tx loop on net_null for bursts 1..128, median of 5 runs, a/B + c fit. |
| `code/ring_cable.c` | Two ports joined by `rte_eth_from_rings`; in-order delivery, full Tx ring, freeing the unsent tail; `-- --leak` drains the pool (exercise 2). |
| `code/solutions/skeleton_pairs.c` | Exercise 1: explicit port pairing that survives gaps in port ids. |
| `code/init_errors.sh` | Captures port-init errors: no ports, pool ENOMEM, nb_desc outside limits (virtio_user + background net_vhost testpmd), -EBUSY, deferred start -ENOTSUP. |
| `code/expected_output.txt` | Real output of `run.sh` on the course VM. |

## How to run

```bash
source <dpdk-env.sh>          # sets PKG_CONFIG_PATH, PATH, DPDK_SRC
cd code
./run.sh 2>&1 | tee expected_output.txt
```

Everything uses `--no-pci --no-huge -m 64/128`, unique `--file-prefix=ch08-*`,
`timeout`, and virtual devices (net_null, net_ring, net_tap `ch08tap0/1`,
virtio_user/net_vhost). The scripts remove the runtime directories, TAP
interfaces and the vhost socket on exit. Needs root for net_tap. Nothing needs a real NIC.
