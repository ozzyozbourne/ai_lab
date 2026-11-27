/* SPDX-License-Identifier: BSD-3-Clause
 *
 * Chapter 14, exercise 2 solution: rcu_swap with the RCU defer queue.
 *
 * Same readers as rcu_swap.c. The writer performs UPDATES config swaps
 * twice:
 *   phase "synchronize": swap, rte_rcu_qsbr_synchronize(), free old
 *   phase "defer queue": swap, rte_rcu_qsbr_dq_enqueue(old) and go on;
 *                        the dq frees old configs later, from inside
 *                        enqueue (auto reclaim) or rte_rcu_qsbr_dq_reclaim()
 * and reports the writer's per-update latency for both.
 *
 * The defer queue needs more slots, because freed configs wait in it for
 * their grace period: we size the pool at NSLOTS and the dq at NSLOTS too.
 *
 * Run: ./rcu_dq -l 0-3 --no-pci --no-huge -m 64 --file-prefix=ch14-rcudq
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <inttypes.h>

#include <rte_eal.h>
#include <rte_lcore.h>
#include <rte_launch.h>
#include <rte_cycles.h>
#include <rte_pause.h>
#include <rte_common.h>
#include <rte_debug.h>
#include <rte_errno.h>
#include <rte_malloc.h>
#include <rte_stdatomic.h>
#include <rte_rcu_qsbr.h>

#define UPDATES 20000
#define NSLOTS 256
#define NPAY 6
#define ALIVE 0xA11CEu
#define DEAD  0xDEADu

struct __rte_cache_aligned cfg {
	RTE_ATOMIC(uint32_t) magic;
	uint64_t version;
	uint64_t payload[NPAY];
};

static struct cfg slots[NSLOTS];
static struct cfg *free_list[NSLOTS];	/* writer-only stack of free slots */
static unsigned int nfree;
static RTE_ATOMIC(struct cfg *) cur;
static struct rte_rcu_qsbr *qs;
static RTE_ATOMIC(int) stop;
static struct __rte_cache_aligned { uint64_t reads, uaf; } rst[RTE_MAX_LCORE];

static void
cfg_free(struct cfg *c)
{
	rte_atomic_store_explicit(&c->magic, DEAD, rte_memory_order_relaxed);
	for (int i = 0; i < NPAY; i++)
		c->payload[i] = 0xdeadbeef;
	free_list[nfree++] = c;
}

/* Called by the defer queue once the grace period of 'e' is over.
 * e points to the esize bytes we enqueued: here, one struct cfg pointer. */
static void
dq_free(void *p, void *e, unsigned int n)
{
	(void)p;
	for (unsigned int i = 0; i < n; i++)
		cfg_free(((struct cfg **)e)[i]);
}

static int
reader(void *arg)
{
	unsigned int id = rte_lcore_id();
	(void)arg;
	rte_rcu_qsbr_thread_register(qs, id);
	rte_rcu_qsbr_thread_online(qs, id);
	while (!rte_atomic_load_explicit(&stop, rte_memory_order_relaxed)) {
		struct cfg *c = rte_atomic_load_explicit(&cur, rte_memory_order_acquire);
		int bad = rte_atomic_load_explicit(&c->magic, rte_memory_order_relaxed) != ALIVE;
		for (int i = 0; i < NPAY; i++)
			bad |= (c->payload[i] != c->version);
		bad |= rte_atomic_load_explicit(&c->magic, rte_memory_order_acquire) != ALIVE;
		rst[id].uaf += bad;
		rst[id].reads++;
		rte_rcu_qsbr_quiescent(qs, id);
	}
	rte_rcu_qsbr_thread_offline(qs, id);
	rte_rcu_qsbr_thread_unregister(qs, id);
	return 0;
}

static int
cmp_u64(const void *a, const void *b)
{
	uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
	return (x > y) - (x < y);
}

static void
report(const char *name, uint64_t *lat, unsigned int n, uint64_t elapsed)
{
	double us = rte_get_tsc_hz() / 1e6;
	qsort(lat, n, sizeof(lat[0]), cmp_u64);
	printf("%-12s %6u updates in %7.2f ms | per update: median %6.2f us, p99 %6.2f us, max %8.2f us\n",
	       name, n, elapsed / us / 1000.0, lat[n / 2] / us, lat[n * 99 / 100] / us,
	       lat[n - 1] / us);
}

int
main(int argc, char **argv)
{
	static uint64_t lat[UPDATES];
	uint64_t v = 1;
	unsigned int l;

	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	if (rte_lcore_count() < 2)
		rte_exit(EXIT_FAILURE, "need worker lcores, e.g. -l 0-3\n");

	qs = rte_zmalloc(NULL, rte_rcu_qsbr_get_memsize(RTE_MAX_LCORE), RTE_CACHE_LINE_SIZE);
	if (qs == NULL || rte_rcu_qsbr_init(qs, RTE_MAX_LCORE) != 0)
		rte_exit(EXIT_FAILURE, "qsbr init failed\n");

	struct rte_rcu_qsbr_dq_parameters p = {
		.name = "ch14_dq",
		.flags = RTE_RCU_QSBR_DQ_MT_UNSAFE,	/* only the writer uses it */
		.size = NSLOTS,
		.esize = sizeof(struct cfg *),		/* we store the pointer */
		.trigger_reclaim_limit = 32,		/* auto-reclaim when >= 32 wait */
		.max_reclaim_size = 32,
		.free_fn = dq_free,
		.p = NULL,
		.v = qs,
	};
	struct rte_rcu_qsbr_dq *dq = rte_rcu_qsbr_dq_create(&p);
	if (dq == NULL)
		rte_exit(EXIT_FAILURE, "dq create: %s\n", rte_strerror(rte_errno));

	for (int i = NSLOTS - 1; i >= 1; i--)
		free_list[nfree++] = &slots[i];
	slots[0].version = v;
	for (int i = 0; i < NPAY; i++)
		slots[0].payload[i] = v;
	slots[0].magic = ALIVE;
	rte_atomic_store_explicit(&cur, &slots[0], rte_memory_order_release);
	rte_eal_mp_remote_launch(reader, NULL, SKIP_MAIN);
	rte_delay_ms(10);

	for (int phase = 0; phase < 2; phase++) {
		uint64_t start = rte_rdtsc();
		for (unsigned int u = 0; u < UPDATES; u++) {
			uint64_t t0 = rte_rdtsc();
			while (nfree == 0) {	/* pool empty: force reclamation */
				unsigned int fr, pend, avail;
				rte_rcu_qsbr_dq_reclaim(dq, 32, &fr, &pend, &avail);
			}
			struct cfg *n = free_list[--nfree];
			n->version = ++v;
			for (int i = 0; i < NPAY; i++)
				n->payload[i] = v;
			rte_atomic_store_explicit(&n->magic, ALIVE, rte_memory_order_release);
			struct cfg *old = rte_atomic_exchange_explicit(&cur, n, rte_memory_order_acq_rel);
			if (phase == 0) {
				rte_rcu_qsbr_synchronize(qs, RTE_QSBR_THRID_INVALID);
				cfg_free(old);
			} else if (rte_rcu_qsbr_dq_enqueue(dq, &old) != 0) {
				rte_exit(EXIT_FAILURE, "dq enqueue: %s\n", rte_strerror(rte_errno));
			}
			lat[u] = rte_rdtsc() - t0;
		}
		report(phase == 0 ? "synchronize" : "defer queue", lat, UPDATES, rte_rdtsc() - start);
	}

	unsigned int fr = 0, pend = 0, avail = 0;
	rte_rcu_qsbr_dq_reclaim(dq, NSLOTS, &fr, &pend, &avail);
	printf("after the run: dq reclaimed %u more, %u still pending, %u free in pool\n",
	       fr, pend, nfree);

	rte_atomic_store_explicit(&stop, 1, rte_memory_order_relaxed);
	rte_eal_mp_wait_lcore();
	uint64_t uaf = 0;
	RTE_LCORE_FOREACH_WORKER(l)
		uaf += rst[l].uaf;
	printf("readers saw freed/torn config: %" PRIu64 " times\n", uaf);
	if (rte_rcu_qsbr_dq_delete(dq) != 0)
		printf("dq delete: %s\n", rte_strerror(rte_errno));
	rte_free(qs);
	rte_eal_cleanup();
	return 0;
}
