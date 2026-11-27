/* SPDX-License-Identifier: BSD-3-Clause
 *
 * Chapter 6, example 2: cache_explorer.c
 *
 * Part A  Trace cache->len after every get/put on a pool of 4095 objects with
 *         a 256-entry per-lcore cache. Each step is chosen to hit one branch
 *         of rte_mempool_do_generic_get/put() in lib/mempool/rte_mempool.h
 *         (26.11 algorithm: the cache never holds more than `size`; refills
 *         and flushes move exactly size/2 objects; requests larger than
 *         size/2 may bypass the cache).
 * Part B  Cache size limits in 26.11: 1024 (> the old 512 limit) works,
 *         cache_size > n fails with EINVAL.
 * Part C  A non-EAL pthread has no default cache; give it a user-owned one
 *         with rte_mempool_cache_create() + rte_mempool_generic_get/put().
 * Part D  Timing: main lcore + one worker lcore both do get_bulk(32)/
 *         put_bulk(32) in a loop on the same pool, with cache 0, 256, 1024.
 *         5 runs each; we print median, min and max cycles per object.
 *
 * Run:  ./cache_explorer -l 0-1 --no-pci --no-huge -m 64 --file-prefix=ch06-cache
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

#include <rte_eal.h>
#include <rte_errno.h>
#include <rte_lcore.h>
#include <rte_launch.h>
#include <rte_cycles.h>
#include <rte_mempool.h>
#include <rte_debug.h>

#define POOL_N  4095
#define BURST   32
#define ITERS   200000
#define RUNS    5

static void *held[POOL_N];     /* objects the "application" currently holds */
static unsigned int nheld;

/* objects in the backend ring = all available minus what sits in caches.
 * Only the main lcore touches the pool in part A, so one cache is enough. */
static unsigned int
backend_count(struct rte_mempool *mp, struct rte_mempool_cache *c)
{
	return rte_mempool_avail_count(mp) - c->len;
}

static void
step_get(struct rte_mempool *mp, struct rte_mempool_cache *c, unsigned int n,
	 const char *why)
{
	int ret = rte_mempool_get_bulk(mp, &held[nheld], n);
	if (ret == 0)
		nheld += n;
	printf("  get %-4u -> ret=%d cache.len=%-4u backend=%-5u | %s\n",
	       n, ret, c->len, backend_count(mp, c), why);
}

static void
step_put(struct rte_mempool *mp, struct rte_mempool_cache *c, unsigned int n,
	 const char *why)
{
	nheld -= n;
	rte_mempool_put_bulk(mp, &held[nheld], n);
	printf("  put %-4u ->       cache.len=%-4u backend=%-5u | %s\n",
	       n, c->len, backend_count(mp, c), why);
}

static void
part_a(void)
{
	struct rte_mempool *mp;
	struct rte_mempool_cache *c;

	mp = rte_mempool_create("ch06_trace", POOL_N, 64, 256, 0, NULL, NULL,
				NULL, NULL, rte_socket_id(), 0);
	if (mp == NULL)
		rte_exit(EXIT_FAILURE, "create: %s\n", rte_strerror(rte_errno));
	c = rte_mempool_default_cache(mp, rte_lcore_id());
	printf("[A] pool n=%u, cache size=%u (size/2=%u) on lcore %u\n",
	       mp->size, c->size, c->size / 2, rte_lcore_id());
	printf("  start               cache.len=%-4u backend=%-5u\n",
	       c->len, backend_count(mp, c));
	/* Give the "application" a stock of 400 objects to put back later.
	 * cache=NULL means: go straight to the backend, leave the cache alone. */
	rte_mempool_generic_get(mp, held, 400, NULL);
	nheld = 400;
	printf("  stock 400 (cache=NULL) cache.len=%-4u backend=%-5u | app now holds 400\n",
	       c->len, backend_count(mp, c));

	step_get(mp, c, 1,   "miss: refill size/2=128 from backend, hand out 1");
	step_put(mp, c, 1,   "fits: push on top of the cache");
	step_put(mp, c, 100, "fits: 128+100 <= 256");
	step_put(mp, c, 50,  "overflow: flush the bottom 128, keep hot 100, add 50");
	step_get(mp, c, 150, "hit: all 150 served from the cache");
	step_get(mp, c, 32,  "miss: refill 128, hand out 32");
	step_get(mp, c, 200, "drain 96, remaining 104 <= 128: refill 128, give 104");
	step_get(mp, c, 200, "drain 24, remaining 176 > 128: direct from backend");
	step_put(mp, c, 200, "fits: 0+200 <= 256 (even though 200 > size/2)");
	step_put(mp, c, 200, "no room and 200 > size/2: bypass, straight to backend");
	rte_mempool_cache_flush(c, mp);
	printf("  cache_flush ->      cache.len=%-4u backend=%-5u | everything cached goes back\n",
	       c->len, backend_count(mp, c));
	step_put(mp, c, nheld, "return the rest (direct: > size/2 and no room)");
	printf("  in_use=%u, nheld=%u\n", rte_mempool_in_use_count(mp), nheld);
	rte_mempool_free(mp);
}

static void
part_b(void)
{
	unsigned int sizes[] = { 512, 1024, 4095, 4096 };
	unsigned int i;

	printf("[B] cache_size limits (pool n=%u, RTE_MEMPOOL_CACHE_MAX_SIZE=%d)\n",
	       POOL_N, RTE_MEMPOOL_CACHE_MAX_SIZE);
	for (i = 0; i < RTE_DIM(sizes); i++) {
		struct rte_mempool *mp = rte_mempool_create("ch06_lim", POOL_N, 64,
				sizes[i], 0, NULL, NULL, NULL, NULL, rte_socket_id(), 0);
		if (mp != NULL) {
			printf("  cache_size=%-5u ok, sizeof_cache_per_lcore=%u bytes\n",
			       sizes[i], mp->sizeof_cache_per_lcore);
			rte_mempool_free(mp);
		} else {
			printf("  cache_size=%-5u FAILED: %s\n", sizes[i],
			       rte_strerror(rte_errno));
		}
	}
}

/* ---- Part C: a plain pthread, not an EAL lcore ------------------------- */
static void *
non_eal_thread(void *arg)
{
	struct rte_mempool *mp = arg;
	struct rte_mempool_cache *uc;
	void *objs[BURST];

	printf("[C] non-EAL pthread: rte_lcore_id()=%s, default cache=%p\n",
	       rte_lcore_id() == LCORE_ID_ANY ? "LCORE_ID_ANY" : "?",
	       (void *)rte_mempool_default_cache(mp, rte_lcore_id()));

	uc = rte_mempool_cache_create(256, SOCKET_ID_ANY);
	if (uc == NULL) {
		printf("  cache_create failed\n");
		return NULL;
	}
	rte_mempool_generic_get(mp, objs, BURST, uc);
	printf("  user cache: generic_get(32) -> cache.len=%u (refill 128, hand out 32)\n", uc->len);
	rte_mempool_generic_put(mp, objs, BURST, uc);
	printf("  user cache: generic_put(32) -> cache.len=%u\n", uc->len);
	rte_mempool_cache_flush(uc, mp);   /* MUST flush before freeing it */
	printf("  after flush cache.len=%u, pool avail=%u\n", uc->len,
	       rte_mempool_avail_count(mp));
	rte_mempool_cache_free(uc);
	return NULL;
}

static void
part_c(void)
{
	pthread_t t;
	struct rte_mempool *mp = rte_mempool_create("ch06_noneal", POOL_N, 64, 256,
			0, NULL, NULL, NULL, NULL, rte_socket_id(), 0);
	if (mp == NULL)
		rte_exit(EXIT_FAILURE, "create\n");
	pthread_create(&t, NULL, non_eal_thread, mp);
	pthread_join(t, NULL);
	rte_mempool_free(mp);
}

/* ---- Part D: timing ----------------------------------------------------- */
static struct rte_mempool *bench_mp;
static volatile int go;

static int
bench_loop(void *arg)
{
	uint64_t *cycles = arg;
	void *objs[BURST];
	uint64_t t0;
	int i;

	while (!go)
		rte_pause();
	t0 = rte_rdtsc_precise();
	for (i = 0; i < ITERS; i++) {
		if (rte_mempool_get_bulk(bench_mp, objs, BURST) == 0)
			rte_mempool_put_bulk(bench_mp, objs, BURST);
	}
	*cycles = rte_rdtsc_precise() - t0;
	return 0;
}

static int
cmp_dbl(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;
	return (x > y) - (x < y);
}

static void
part_d(void)
{
	unsigned int caches[] = { 0, 256, 1024 };
	unsigned int worker = rte_get_next_lcore(-1, 1, 0);
	unsigned int i, r;

	if (worker >= RTE_MAX_LCORE) {
		printf("[D] skipped: needs 2 lcores (-l 0-1)\n");
		return;
	}
	printf("[D] 2 lcores (%u and %u) each: get_bulk(%d)+put_bulk(%d) x %d, %d runs\n",
	       rte_lcore_id(), worker, BURST, BURST, ITERS, RUNS);
	for (i = 0; i < RTE_DIM(caches); i++) {
		double res[RUNS];
		for (r = 0; r < RUNS; r++) {
			uint64_t cw = 0, cm = 0;
			bench_mp = rte_mempool_create("ch06_bench", POOL_N, 64, caches[i],
					0, NULL, NULL, NULL, NULL, rte_socket_id(), 0);
			if (bench_mp == NULL)
				rte_exit(EXIT_FAILURE, "bench create\n");
			go = 0;
			rte_eal_remote_launch(bench_loop, &cw, worker);
			go = 1;
			bench_loop(&cm);
			rte_eal_wait_lcore(worker);
			/* cycles per object (one get + one put), averaged over both lcores */
			res[r] = (double)(cw + cm) / 2 / ((double)ITERS * BURST);
			rte_mempool_free(bench_mp);
		}
		qsort(res, RUNS, sizeof(res[0]), cmp_dbl);
		printf("  cache %-5u: median %7.2f cycles per get+put of one object (min %.2f, max %.2f)\n",
		       caches[i], res[RUNS / 2], res[0], res[RUNS - 1]);
	}
}

int
main(int argc, char **argv)
{
	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	part_a();
	part_b();
	part_c();
	part_d();
	rte_eal_cleanup();
	return 0;
}
