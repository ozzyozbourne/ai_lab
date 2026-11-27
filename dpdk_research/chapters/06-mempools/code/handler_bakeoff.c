/* SPDX-License-Identifier: BSD-3-Clause
 *
 * Chapter 6, example 3: handler_bakeoff.c
 *
 * The same workload over every software mempool handler ("ops") built here:
 *   ring_mp_mc  ring_sp_sc  ring_mt_hts  stack  lf_stack  pile  bucket
 *
 * For each handler we build the pool step by step:
 *   rte_mempool_create_empty() -> rte_mempool_set_ops_byname()
 *   -> rte_mempool_populate_default() -> rte_mempool_obj_iter() (number objs)
 * and then measure, with cache_size = 0 so every call reaches the handler:
 *   1. cycles per object for get_bulk(32)+put_bulk(32) on ONE lcore
 *      (median of 5 runs, min and max);
 *   2. reuse order of single objects: get 5, put them back (0,1,2,3,4 in
 *      that order), get 5 again -- a FIFO hands out different, older objects,
 *      a LIFO hands back the ones just freed (cache-warm);
 *   3. reuse order of a 64-object bulk: the pile handler is LIFO per
 *      32-object bulk, not per object (documented 26.11 behaviour).
 *
 * Exercise 2 (solutions/bakeoff_mp.c) repeats part 1 with several lcores.
 *
 * Run:  ./handler_bakeoff -l 0 --no-pci --no-huge -m 128 --file-prefix=ch06-ops
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <rte_eal.h>
#include <rte_errno.h>
#include <rte_lcore.h>
#include <rte_cycles.h>
#include <rte_mempool.h>
#include <rte_debug.h>

#define POOL_N  2047
#define BURST   32
#define ITERS   100000
#define RUNS    5

static const char *handlers[] = {
	"ring_mp_mc", "ring_sp_sc", "ring_mt_hts",
	"stack", "lf_stack", "pile", "bucket",
};

/* Each object starts with its index, written by obj_iter. */
static void
number_obj(struct rte_mempool *mp, void *arg, void *obj, unsigned int idx)
{
	(void)mp; (void)arg;
	*(uint32_t *)obj = idx;
}

#define IDX(p) (*(uint32_t *)(p))

static struct rte_mempool *
make_pool(const char *ops)
{
	struct rte_mempool *mp;
	int ret;

	mp = rte_mempool_create_empty("ch06_bake", POOL_N, 64,
				      0 /* no cache: measure the handler */,
				      0, rte_socket_id(), 0);
	if (mp == NULL)
		return NULL;
	ret = rte_mempool_set_ops_byname(mp, ops, NULL);
	if (ret != 0) {
		printf("  %-11s set_ops_byname: %s\n", ops, strerror(-ret));
		rte_mempool_free(mp);
		return NULL;
	}
	ret = rte_mempool_populate_default(mp);
	if (ret < 0) {
		printf("  %-11s populate: %s\n", ops, strerror(-ret));
		rte_mempool_free(mp);
		return NULL;
	}
	rte_mempool_obj_iter(mp, number_obj, NULL);
	return mp;
}

static int
cmp_dbl(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;
	return (x > y) - (x < y);
}

static double
time_once(struct rte_mempool *mp)
{
	void *objs[BURST];
	uint64_t t0 = rte_rdtsc_precise();
	int i;

	for (i = 0; i < ITERS; i++) {
		if (rte_mempool_get_bulk(mp, objs, BURST) == 0)
			rte_mempool_put_bulk(mp, objs, BURST);
	}
	return (double)(rte_rdtsc_precise() - t0) / ((double)ITERS * BURST);
}

int
main(int argc, char **argv)
{
	unsigned int h, r, i;

	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");

	printf("pool n=%d, elt 64 B, cache 0, 1 lcore; burst %d x %d iterations, %d runs\n",
	       POOL_N, BURST, ITERS, RUNS);
	printf("%-11s %8s %8s %8s | %-22s | %s\n", "handler", "median", "min", "max",
	       "singles: 1st get->reget", "bulk64 reget[0..4] (got[0..4])");

	for (h = 0; h < RTE_DIM(handlers); h++) {
		struct rte_mempool *mp = make_pool(handlers[h]);
		double res[RUNS];
		void *s[5], *a[64], *b[64];
		char singles[64], bulk[96];
		int n = 0;

		if (mp == NULL)
			continue;

		for (r = 0; r < RUNS; r++)
			res[r] = time_once(mp);
		qsort(res, RUNS, sizeof(res[0]), cmp_dbl);

		/* 2. single objects: get 5, put 5 in order, get 5 again */
		for (i = 0; i < 5; i++)
			rte_mempool_get(mp, &s[i]);
		n = snprintf(singles, sizeof(singles), "%u,%u,%u->",
			     IDX(s[0]), IDX(s[1]), IDX(s[2]));
		for (i = 0; i < 5; i++)
			rte_mempool_put(mp, s[i]);
		for (i = 0; i < 5; i++)
			rte_mempool_get(mp, &s[i]);
		snprintf(singles + n, sizeof(singles) - n, "%u,%u,%u",
			 IDX(s[0]), IDX(s[1]), IDX(s[2]));
		for (i = 0; i < 5; i++)
			rte_mempool_put(mp, s[i]);

		/* 3. a 64-object bulk: get, put back, get again */
		rte_mempool_get_bulk(mp, a, 64);
		rte_mempool_put_bulk(mp, a, 64);
		rte_mempool_get_bulk(mp, b, 64);
		snprintf(bulk, sizeof(bulk), "%u %u %u %u %u (%u %u %u %u %u)",
			 IDX(b[0]), IDX(b[1]), IDX(b[2]), IDX(b[3]), IDX(b[4]),
			 IDX(a[0]), IDX(a[1]), IDX(a[2]), IDX(a[3]), IDX(a[4]));
		rte_mempool_put_bulk(mp, b, 64);

		printf("%-11s %8.2f %8.2f %8.2f | %-22s | %s\n", handlers[h],
		       res[RUNS / 2], res[0], res[RUNS - 1], singles, bulk);
		if (rte_mempool_avail_count(mp) != POOL_N)
			printf("  !! %u objects missing\n", POOL_N - rte_mempool_avail_count(mp));
		rte_mempool_free(mp);
	}
	printf("(cycles per object for one get + one put; VM, software only)\n");
	rte_eal_cleanup();
	return 0;
}
