/* SPDX-License-Identifier: BSD-3-Clause
 *
 * Chapter 6, exercise 2 solution: bakeoff_mp.c
 *
 * handler_bakeoff.c with contention: every lcore in -l (main included) runs
 * get_bulk(32)+put_bulk(32) on the SAME pool at the same time, cache 0, so
 * all of them hit the handler concurrently.
 *
 * ring_sp_sc is left out on purpose: it is only safe with ONE producer and
 * ONE consumer thread. With several lcores it silently corrupts the ring.
 *
 * Run:  ./bakeoff_mp -l 0-2 --no-pci --no-huge -m 128 --file-prefix=ch06-opsmp
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <rte_eal.h>
#include <rte_errno.h>
#include <rte_lcore.h>
#include <rte_launch.h>
#include <rte_cycles.h>
#include <rte_mempool.h>
#include <rte_debug.h>

#define POOL_N 2047
#define BURST  32
#define ITERS  50000
#define RUNS   5

static const char *handlers[] = {
	"ring_mp_mc", "ring_mt_hts", "ring_mt_rts", "stack", "lf_stack", "pile", "bucket",
};

static struct rte_mempool *mp;
static uint64_t cycles[RTE_MAX_LCORE];
static volatile int go;

static int
loop(void *arg)
{
	void *objs[BURST];
	uint64_t t0;
	int i;
	(void)arg;

	while (!go)
		rte_pause();
	t0 = rte_rdtsc_precise();
	for (i = 0; i < ITERS; i++)
		if (rte_mempool_get_bulk(mp, objs, BURST) == 0)
			rte_mempool_put_bulk(mp, objs, BURST);
	cycles[rte_lcore_id()] = rte_rdtsc_precise() - t0;
	return 0;
}

static int
cmp_dbl(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;
	return (x > y) - (x < y);
}

int
main(int argc, char **argv)
{
	unsigned int h, r, lc, n;

	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	n = rte_lcore_count();
	printf("%u lcores hammer one pool (n=%d, cache 0), burst %d x %d, %d runs\n",
	       n, POOL_N, BURST, ITERS, RUNS);

	for (h = 0; h < RTE_DIM(handlers); h++) {
		double res[RUNS];
		for (r = 0; r < RUNS; r++) {
			uint64_t sum = 0;
			mp = rte_mempool_create_empty("ch06_mp", POOL_N, 64, 0, 0,
						      rte_socket_id(), 0);
			if (mp == NULL || rte_mempool_set_ops_byname(mp, handlers[h], NULL) ||
			    rte_mempool_populate_default(mp) < 0)
				rte_exit(EXIT_FAILURE, "pool %s\n", handlers[h]);
			go = 0;
			rte_eal_mp_remote_launch(loop, NULL, SKIP_MAIN); /* workers wait for go */
			go = 1;
			loop(NULL);                                      /* main joins in */
			rte_eal_mp_wait_lcore();
			RTE_LCORE_FOREACH(lc)
				sum += cycles[lc];
			res[r] = (double)sum / n / ((double)ITERS * BURST);
			if (rte_mempool_avail_count(mp) != POOL_N)
				printf("  !! %s: %u objects missing\n", handlers[h],
				       POOL_N - rte_mempool_avail_count(mp));
			rte_mempool_free(mp);
		}
		qsort(res, RUNS, sizeof(res[0]), cmp_dbl);
		printf("  %-11s median %8.2f cycles/obj (min %.2f, max %.2f)\n",
		       handlers[h], res[RUNS / 2], res[0], res[RUNS - 1]);
	}
	printf("(per lcore, one get + one put of one object; VM, software only)\n");
	rte_eal_cleanup();
	return 0;
}
