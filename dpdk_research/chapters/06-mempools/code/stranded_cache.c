/* SPDX-License-Identifier: BSD-3-Clause
 *
 * Chapter 6, example 4: stranded_cache.c
 *
 * A pool of 256 objects with a 128-entry per-lcore cache, used by 3 lcores.
 * Each worker lcore does a perfectly balanced get/put pattern -- it frees
 * everything it allocated -- yet when it stops, its cache holds 128 objects.
 * Two workers x 128 = 256 = the whole pool. The main lcore then sees
 * rte_mempool_avail_count() == 256 and still cannot get a single object.
 *
 * Fix 1: each worker flushes its own cache (rte_mempool_cache_flush) when it
 *        is done. The cache is not thread-safe, so the flush must run on the
 *        lcore that owns it -- we relaunch the workers to do it.
 * Fix 2: size the pool so caches cannot swallow it:
 *        n >= in_flight + nb_lcores * cache_size.
 *
 * Run:  ./stranded_cache -l 0-2 --no-pci --no-huge -m 64 --file-prefix=ch06-strand
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <rte_eal.h>
#include <rte_errno.h>
#include <rte_lcore.h>
#include <rte_launch.h>
#include <rte_mempool.h>
#include <rte_debug.h>

#define CACHE 128

static struct rte_mempool *mp;

/* A balanced worker: two bursts of 64 out, two bursts of 64 back. */
static int
worker_balanced(void *arg)
{
	void *a[64], *b[64];
	int i;
	(void)arg;

	for (i = 0; i < 1000; i++) {
		if (rte_mempool_get_bulk(mp, a, 64) != 0)
			continue;
		if (rte_mempool_get_bulk(mp, b, 64) != 0) {
			rte_mempool_put_bulk(mp, a, 64);
			continue;
		}
		rte_mempool_put_bulk(mp, a, 64);
		rte_mempool_put_bulk(mp, b, 64);
	}
	return 0;
}

/* Fix 1: give the cached objects back. Runs ON the owning lcore. */
static int
worker_flush(void *arg)
{
	(void)arg;
	rte_mempool_cache_flush(rte_mempool_default_cache(mp, rte_lcore_id()), mp);
	return 0;
}

static void
show(const char *when)
{
	unsigned int lc, cached = 0;

	printf("%s\n  avail_count=%u in_use=%u |", when,
	       rte_mempool_avail_count(mp), rte_mempool_in_use_count(mp));
	RTE_LCORE_FOREACH(lc) {
		unsigned int len = rte_mempool_default_cache(mp, lc)->len;
		cached += len;
		printf(" cache[%u]=%u", lc, len);
	}
	printf(" | in backend=%u\n", rte_mempool_avail_count(mp) - cached);
}

static void
try_get(unsigned int n)
{
	void *objs[512];
	int ret = rte_mempool_get_bulk(mp, objs, n);

	printf("  main lcore: get_bulk(%u) = %d%s\n", n, ret,
	       ret == 0 ? " ok" : " FAILED although avail_count says there are free objects");
	if (ret == 0)
		rte_mempool_put_bulk(mp, objs, n);
}

static void
run_workers(lcore_function_t *fn)
{
	rte_eal_mp_remote_launch(fn, NULL, SKIP_MAIN);
	rte_eal_mp_wait_lcore();
}

int
main(int argc, char **argv)
{
	unsigned int n_lcores;

	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	n_lcores = rte_lcore_count();
	if (n_lcores < 3)
		rte_exit(EXIT_FAILURE, "needs 3 lcores: -l 0-2\n");

	/* ---- the problem ----------------------------------------------- */
	mp = rte_mempool_create("ch06_strand", 256, 64, CACHE, 0, NULL, NULL,
				NULL, NULL, rte_socket_id(), 0);
	if (mp == NULL)
		rte_exit(EXIT_FAILURE, "create: %s\n", rte_strerror(rte_errno));
	printf("pool n=256, cache_size=%d, %u lcores\n", CACHE, n_lcores);

	run_workers(worker_balanced);
	show("[1] after workers ran a balanced get/put loop and stopped:");
	try_get(1);
	try_get(64);

	/* ---- fix 1: flush on the owning lcores -------------------------- */
	run_workers(worker_flush);
	show("[2] after each worker ran rte_mempool_cache_flush() on itself:");
	try_get(256);
	rte_mempool_free(mp);

	/* ---- fix 2: size the pool for the caches ------------------------ */
	{
		unsigned int in_flight = 256;          /* what the app really needs */
		unsigned int n = in_flight + n_lcores * CACHE;

		mp = rte_mempool_create("ch06_strand2", n, 64, CACHE, 0, NULL, NULL,
					NULL, NULL, rte_socket_id(), 0);
		if (mp == NULL)
			rte_exit(EXIT_FAILURE, "create2: %s\n", rte_strerror(rte_errno));
		printf("[3] resized pool: n = in_flight %u + %u lcores x cache %d = %u\n",
		       in_flight, n_lcores, CACHE, n);
		run_workers(worker_balanced);
		show("    after the same worker loop:");
		try_get(in_flight);
		rte_mempool_dump(stdout, mp);
		rte_mempool_free(mp);
	}

	rte_eal_cleanup();
	return 0;
}
