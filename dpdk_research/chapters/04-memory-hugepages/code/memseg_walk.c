/* SPDX-License-Identifier: BSD-3-Clause
 *
 * memseg_walk.c - Chapter 4, example 3 (deep dive).
 *
 * Shows how EAL describes the memory it mapped:
 *   memseg list  = one big reserved VA window per (page size, NUMA node)
 *   memseg       = one page inside that window (va, iova, len, socket, flags)
 * and then asks for a 3 MB IOVA-contiguous memzone, which needs two 2 MB pages
 * that are next to each other in IOVA space. In PA mode the kernel rarely
 * hands out physically adjacent hugepages, so it usually fails; in VA mode
 * IOVA == VA and the request always succeeds.
 *
 *   ./memseg_walk -l 0 --no-pci -m 32 --file-prefix=ch04-ms                  (PA)
 *   ./memseg_walk -l 0 --no-pci -m 32 --iova-mode=va --file-prefix=ch04-ms   (VA)
 *   ./memseg_walk -l 0 --no-pci --no-huge -m 32 --file-prefix=ch04-ms        (4 KB pages)
 */
#include <stdio.h>
#include <inttypes.h>

#include <rte_eal.h>
#include <rte_errno.h>
#include <rte_memory.h>
#include <rte_memzone.h>

/* rte_memseg_list_walk() callback: one line per memseg list. */
static int msl_cb(const struct rte_memseg_list *msl, void *arg)
{
	(void)arg;
	printf("  list: base_va=%p page=%6" PRIu64 "K socket=%d VA window=%6zu MB "
	       "slots=%5u used=%u%s\n",
	       msl->base_va, msl->page_sz >> 10, msl->socket_id, msl->len >> 20,
	       msl->memseg_arr.len, msl->memseg_arr.count,
	       msl->external ? " (external)" : "");
	return 0;   /* 0 = keep walking */
}

struct seg_state {
	int n;               /* segments seen */
	int jumps;           /* neighbours whose IOVAs are not adjacent */
	rte_iova_t next_iova;
};

/* rte_memseg_walk() callback: called for every mapped page. */
static int ms_cb(const struct rte_memseg_list *msl, const struct rte_memseg *ms, void *arg)
{
	struct seg_state *s = arg;
	(void)msl;

	if (s->n > 0 && ms->iova != s->next_iova)
		s->jumps++;
	s->next_iova = ms->iova + ms->len;
	if (s->n < 8)
		printf("  seg %d: va=%p iova=0x%09" PRIx64 " len=%4zuK flags=%#x%s\n",
		       s->n, ms->addr, ms->iova, ms->len >> 10, ms->flags,
		       (ms->flags & RTE_MEMSEG_FLAG_DO_NOT_FREE) ? " (DO_NOT_FREE: pinned by -m)" : "");
	s->n++;
	return 0;
}

/* rte_memseg_contig_walk(): runs of pages that are contiguous in VA. */
static int contig_cb(const struct rte_memseg_list *msl, const struct rte_memseg *ms,
		     size_t len, void *arg)
{
	(void)msl; (void)arg;
	printf("  VA-contiguous run: va=%p len=%zu MB (first iova=0x%" PRIx64 ")\n",
	       ms->addr, len >> 20, ms->iova);
	return 0;
}

int main(int argc, char **argv)
{
	if (rte_eal_init(argc, argv) < 0) {
		fprintf(stderr, "rte_eal_init failed: %s\n", rte_strerror(rte_errno));
		return 1;
	}
	printf("IOVA mode: %s\n", rte_eal_iova_mode() == RTE_IOVA_PA ? "PA" :
	       rte_eal_iova_mode() == RTE_IOVA_VA ? "VA" : "DC");

	printf("\nmemseg lists (VA reserved, not memory):\n");
	rte_memseg_list_walk(msl_cb, NULL);

	struct seg_state s = { 0 };
	printf("\nmemsegs (pages actually mapped):\n");
	rte_memseg_walk(ms_cb, &s);
	printf("  ... %d segments, %d of %d neighbours are NOT adjacent in IOVA\n",
	       s.n, s.jumps, s.n > 0 ? s.n - 1 : 0);

	printf("\ncontiguous in VA (says nothing about IOVA):\n");
	rte_memseg_contig_walk(contig_cb, NULL);

	/* Look a VA up: which memseg holds it? */
	const struct rte_memzone *probe = rte_memzone_reserve("probe", 1000, SOCKET_ID_ANY, 0);
	if (probe) {
		const struct rte_memseg *ms = rte_mem_virt2memseg(probe->addr, NULL);
		printf("\nrte_mem_virt2memseg(%p) -> page va=%p iova=0x%" PRIx64 "\n",
		       probe->addr, ms ? ms->addr : NULL, ms ? ms->iova : 0);
		rte_memzone_free(probe);
	}

	/* The IOVA-contiguity experiment. */
	printf("\nrte_memzone_reserve_aligned(\"dma_ring\", 3 MB, RTE_MEMZONE_IOVA_CONTIG):\n");
	const struct rte_memzone *mz = rte_memzone_reserve_aligned("dma_ring", 3 << 20,
			SOCKET_ID_ANY, RTE_MEMZONE_IOVA_CONTIG, 4096);
	if (mz == NULL) {
		printf("  FAILED: rte_errno=%d (%s)\n", rte_errno, rte_strerror(rte_errno));
	} else {
		printf("  OK: va=%p iova=0x%" PRIx64 " len=%zu page=%" PRIu64 "K\n",
		       mz->addr, mz->iova, mz->len, mz->hugepage_sz >> 10);
		rte_memzone_free(mz);
	}
	/* Without the flag the same size always works: VA-contiguous is enough
	 * for the CPU, only a device needs IOVA contiguity. */
	mz = rte_memzone_reserve_aligned("cpu_only", 3 << 20, SOCKET_ID_ANY, 0, 4096);
	printf("  same size without IOVA_CONTIG: %s\n", mz ? "OK" : rte_strerror(rte_errno));
	rte_memzone_free(mz);

	rte_eal_cleanup();
	return 0;
}
