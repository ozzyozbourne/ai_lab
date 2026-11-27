/* dmadev demo on the software dma_skeleton driver: ring-index (job handle) model.
 * Run: ./dma_skeleton_copy -l 0-1 --no-huge -m 256 --no-pci --file-prefix=ch08d --vdev=dma_skeleton0,lcore=1 */
#include <stdio.h>
#include <inttypes.h>
#include <string.h>
#include <rte_eal.h>
#include <rte_malloc.h>
#include <rte_dmadev.h>
#include <rte_cycles.h>

#define N 16
#define SZ 4096
int main(int argc, char **argv)
{
	if (rte_eal_init(argc, argv) < 0) rte_exit(1, "eal\n");
	int16_t dev = rte_dma_get_dev_id_by_name("dma_skeleton0");
	if (dev < 0) rte_exit(1, "no dma_skeleton0\n");
	struct rte_dma_info info; rte_dma_info_get(dev, &info);
	printf("dmadev %s: max_vchans=%u desc=[%u..%u] capa=0x%" PRIx64 " %s%s%s\n", info.dev_name,
	       info.max_vchans, info.min_desc, info.max_desc, info.dev_capa,
	       (info.dev_capa & RTE_DMA_CAPA_MEM_TO_MEM) ? "MEM_TO_MEM " : "",
	       (info.dev_capa & RTE_DMA_CAPA_SVA) ? "SVA " : "",
	       (info.dev_capa & RTE_DMA_CAPA_OPS_COPY) ? "COPY" : "");
	struct rte_dma_conf dc = { .nb_vchans = 1 };
	if (rte_dma_configure(dev, &dc)) rte_exit(1, "configure\n");
	struct rte_dma_vchan_conf vc = { .direction = RTE_DMA_DIR_MEM_TO_MEM, .nb_desc = info.min_desc > 64 ? info.min_desc : 64 };
	if (rte_dma_vchan_setup(dev, 0, &vc)) rte_exit(1, "vchan\n");
	if (rte_dma_start(dev)) rte_exit(1, "start\n");

	uint8_t *src[N], *dst[N];
	for (int i = 0; i < N; i++) {
		src[i] = rte_malloc(NULL, SZ, 64); dst[i] = rte_zmalloc(NULL, SZ, 64);
		memset(src[i], 'A' + i, SZ);
	}
	printf("burst_capacity before = %u\n", rte_dma_burst_capacity(dev, 0));
	for (int i = 0; i < N; i++) {
		/* enqueue only writes descriptors; nothing moves until submit (doorbell) */
		int idx = rte_dma_copy(dev, 0, rte_malloc_virt2iova(src[i]), rte_malloc_virt2iova(dst[i]), SZ,
				       i == N - 1 ? RTE_DMA_OP_FLAG_SUBMIT : 0);
		if (i < 3 || i == N - 1) printf("enqueued copy %d -> ring_idx %d\n", i, idx);
	}
	uint16_t done = 0, last = 0; bool err = false; uint64_t t0 = rte_rdtsc();
	while (done < N) {
		uint16_t c = rte_dma_completed(dev, 0, N, &last, &err);
		if (c) printf("completed %u ops, last ring_idx=%u, error=%d\n", c, last, err);
		done += c;
	}
	printf("waited %.1f us\n", (rte_rdtsc() - t0) * 1e6 / rte_get_tsc_hz());
	int bad = 0; for (int i = 0; i < N; i++) bad += memcmp(src[i], dst[i], SZ) != 0;
	printf("verify: %d mismatches; dst[5][0]='%c'\n", bad, dst[5][0]);
	struct rte_dma_stats st; rte_dma_stats_get(dev, 0, &st);
	printf("stats submitted=%" PRIu64 " completed=%" PRIu64 " errors=%" PRIu64 "\n", st.submitted, st.completed, st.errors);
	rte_dma_dump(dev, stdout);
	rte_dma_stop(dev); rte_dma_close(dev); rte_eal_cleanup();
	return 0;
}
