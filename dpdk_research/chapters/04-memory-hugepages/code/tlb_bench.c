/* SPDX-License-Identifier: BSD-3-Clause
 *
 * tlb_bench.c - Chapter 4: does the page size matter? Measure it.
 *
 * A pointer chase that touches ONE cache line in each 4 KB page of a 64 MB
 * buffer, visiting the pages in one random cycle. Every load depends on the
 * previous one. The data actually touched is small (16384 lines = 1 MB, it
 * fits in the CPU caches), but it is spread over many pages, so the cost
 * that remains is address translation:
 *   64 MB / 4 KB = 16384 pages  -> far more than the TLB holds -> page walks
 *   64 MB / 2 MB =    32 pages  -> all translations stay in the TLB
 * The line used inside page p is (p / 32) % 64. Together with the low bits
 * of p this gives every slot a different cache set, so the lines do not
 * evict each other. (With "line = p % 64" the 2 MB run is 3x SLOWER: in a
 * hugepage the address bits that pick the cache set repeat with a short
 * period, and conflict misses swamp the TLB effect. Try it.)
 * It prints cycles per load for 5 runs and the median, min and max.
 *
 *   ./tlb_bench -l 0 --no-pci --no-huge -m 128 --file-prefix=ch04-tlb4k
 *   ./tlb_bench -l 0 --no-pci --huge-unlink --file-prefix=ch04-tlb2m
 * (numbers from a VM: nested paging makes each TLB miss more expensive
 *  than on bare metal.)
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

#include <rte_eal.h>
#include <rte_errno.h>
#include <rte_cycles.h>
#include <rte_malloc.h>
#include <rte_random.h>

#define SIZE   (64u << 20)
#define PAGE4K 4096u                    /* one slot per 4 KB page */
#define STEPS  (4u << 20)               /* loads per run */
#define RUNS   5

static int cmp(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;
	return (x > y) - (x < y);
}

int main(int argc, char **argv)
{
	if (rte_eal_init(argc, argv) < 0) {
		fprintf(stderr, "rte_eal_init: %s\n", rte_strerror(rte_errno));
		return 1;
	}
	const uint64_t n = SIZE / PAGE4K;
	uint64_t *mem = rte_malloc("chase", SIZE, 4096);
	uint32_t *perm = malloc(n * sizeof(*perm));
	if (mem == NULL || perm == NULL) {
		printf("allocation failed\n");
		return 1;
	}

	/* Sattolo's algorithm: a random permutation that is ONE cycle. */
	for (uint64_t i = 0; i < n; i++)
		perm[i] = i;
	for (uint64_t i = n - 1; i > 0; i--) {
		uint64_t j = rte_rand_max(i);          /* 0 <= j < i */
		uint32_t t = perm[i]; perm[i] = perm[j]; perm[j] = t;
	}
	/* word index of the slot in page p: page start + rotating line */
#define SLOT_IDX(p) ((uint64_t)(p) * (PAGE4K / 8) + (((p) >> 5) % 64) * 8)
	/* slot of page perm[i] holds the index of the slot of page perm[i+1] */
	for (uint64_t i = 0; i < n; i++)
		mem[SLOT_IDX(perm[i])] = SLOT_IDX(perm[(i + 1) % n]);
	uint32_t perm0 = perm[0];
	free(perm);

	double cyc[RUNS];
	uint64_t pos = SLOT_IDX(perm0);
	for (uint64_t i = 0; i < STEPS; i++)            /* warm up */
		pos = mem[pos];
	for (int r = 0; r < RUNS; r++) {
		uint64_t t0 = rte_rdtsc_precise();
		for (uint64_t i = 0; i < STEPS; i++)
			pos = mem[pos];                 /* the dependent load */
		cyc[r] = (double)(rte_rdtsc_precise() - t0) / STEPS;
		printf("  run %d: %.1f cycles per load\n", r + 1, cyc[r]);
	}
	qsort(cyc, RUNS, sizeof(cyc[0]), cmp);
	printf("%s pages: median %.1f cycles/load (min %.1f, max %.1f) over %d runs [pos=%lu]\n",
	       rte_eal_has_hugepages() ? "2 MB" : "4 KB", cyc[RUNS / 2], cyc[0], cyc[RUNS - 1],
	       RUNS, (unsigned long)(pos & 1));

	rte_free(mem);
	rte_eal_cleanup();
	return 0;
}
