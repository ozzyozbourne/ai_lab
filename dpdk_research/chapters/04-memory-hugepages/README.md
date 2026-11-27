# Chapter 04: Memory: Hugepages, Memzones, rte_malloc and IOVA

Open `index.html` in a browser (works from `file://`). It covers TLB reach and
hugepages, the EAL memory options and the files they create, `rte_malloc`,
memzones, IOVA (PA/VA and contiguity), NUMA, the startup-error catalogue
(part 1), an optional deep dive (memsegs, heap internals, memory events and
validators, external memory and `rte_dev_dma_map`) and the band 1 review.
`chapter.js` holds the five widgets: TLB reach slider, VA -> IOVA mapping with
predict, EAL error decoder, VA-window animation and malloc-heap stepper.

## Code (`code/`)

| File | What it shows |
|---|---|
| `hello_memory.c` | rte_malloc/zmalloc/calloc/realloc, alignment, validate, heap stats, va vs iova, NUMA socket 1 |
| `tlb_bench.c` | pointer chase on 4 KB vs 2 MB pages (median/min/max of 5 rounds) |
| `sleeper.c` + `see_the_files.sh` | files and mappings in default, single-file, in-memory and no-huge modes; kill -9 leftovers |
| `memseg_walk.c` | memseg lists, memsegs, contig walk, 3 MB `RTE_MEMZONE_IOVA_CONTIG` in PA vs VA |
| `memzones.c` | reserve/aligned/bounded, lookup, walk, dump, EEXIST, ENAMETOOLONG, ENOSPC (max_set 4) |
| `heap_events.c` | mem event callback, allocation validator, external heap; ENOTSUP with --no-huge/--legacy-mem |
| `extmem_dma.c` | `rte_extmem_register` + `rte_dev_dma_map` on net_vhost, net_null and hot-plugged net_virtio_user |
| `startup_errors.sh` | nine reproduced startup errors -> `errors.tsv` (feeds the decoder widget) |
| `solutions/overhead.c`, `solutions/no_cap.c` | exercises 1 and 2 |

## Run

```sh
source <dpdk-env.sh>     # sets PKG_CONFIG_PATH (run.sh does this itself)
cd code
make                     # -Wall -Wextra, static link via pkg-config libdpdk
./run.sh                 # builds and runs everything, about 20 s, as root
```

Every run uses `--no-pci`, a unique `--file-prefix=ch04-*`, `timeout`, and
16 to 64 MB of hugepages at most (or `--no-huge`). The trap removes
`/dev/hugepages/ch04-*map_*`, `/run/dpdk/ch04-*`, the vhost socket and the
private hugetlbfs mount. `code/expected_output.txt` is the real output of
`./run.sh` on the course VM (4 vCPU, 1 NUMA node, no IOMMU, root).

Not runnable here: real VFIO/IOMMU DMA mapping (no PCI NIC may be bound), so
`extmem_dma` demonstrates the API checks on virtual devices; the "no free
hugepages" error is produced with fake sysfs counters inside `unshare -m`.

The page is generated from `_build/index.src.html` by `_build/build.py`, which inserts the C
sources, `errors.tsv` and the captured output verbatim (run it after `run.sh`).
