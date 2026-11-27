/* SPDX-License-Identifier: BSD-3-Clause
 *
 * Chapter 14: rcu_swap.c - replace a shared config with a pointer swap and
 * free the old one only after an RCU QSBR grace period.
 *
 * Readers (every worker lcore) run a poll loop:
 *     c = load_acquire(&cur);  use c;  rte_rcu_qsbr_quiescent(qs, me);
 * The writer (main lcore) builds a new config, swaps the pointer and then
 * must not free the old config until every reader has passed a quiescent
 * state, because a reader may still hold the old pointer.
 *
 * Configs live in a small pool of slots. "Freeing" a slot poisons it
 * (magic = DEAD) and lets the writer reuse it for a later version, which is
 * exactly what a mempool or rte_free would do. A reader that ever sees a
 * poisoned or half-rewritten slot has hit a use-after-free.
 *
 * Modes (argument after --):
 *   sync    rte_rcu_qsbr_synchronize() before freeing (default, correct)
 *   broken  free immediately after the swap (wrong: readers hit freed slots)
 *   slow    like sync, but one reader holds its config for 50 us per
 *           iteration: grace periods stretch to that reader's loop time
 *   offline like slow, but the slow reader calls rte_rcu_qsbr_thread_offline()
 *           around its 50 us pause, and does not touch the config meanwhile
 *
 * Run: ./rcu_swap -l 0-3 --no-pci --no-huge -m 64 --file-prefix=ch14-rcu -- sync
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
#include <rte_malloc.h>
#include <rte_stdatomic.h>
#include <rte_rcu_qsbr.h>

#define RUN_MS 1000
#define MAX_SWAPS 20000
#define NSLOTS 4
#define NPAY 6
#define ALIVE 0xA11CEu
#define DEAD  0xDEADu

struct __rte_cache_aligned cfg {
	RTE_ATOMIC(uint32_t) magic;
	uint64_t version;
	uint64_t payload[NPAY];		/* all equal to version while alive */
};

static struct cfg slots[NSLOTS];
static RTE_ATOMIC(struct cfg *) cur;	/* the pointer readers follow */
static struct rte_rcu_qsbr *qs;		/* the QSBR variable */
static RTE_ATOMIC(int) stop;
static enum { M_SYNC, M_BROKEN, M_SLOW, M_OFFLINE } mode;
static unsigned int slow_lcore;

struct __rte_cache_aligned rstat { uint64_t reads, uaf; };
static struct rstat rst[RTE_MAX_LCORE];

static void
cfg_fill(struct cfg *c, uint64_t v)
{
	c->version = v;
	for (int i = 0; i < NPAY; i++)
		c->payload[i] = v;
	rte_atomic_store_explicit(&c->magic, ALIVE, rte_memory_order_release);
}

static void
cfg_free(struct cfg *c)		/* poison: what a use-after-free would read */
{
	rte_atomic_store_explicit(&c->magic, DEAD, rte_memory_order_relaxed);
	for (int i = 0; i < NPAY; i++)
		c->payload[i] = 0xdeadbeef;
}

static int
reader(void *arg)
{
	unsigned int id = rte_lcore_id();
	struct rstat *s = &rst[id];
	int is_slow = (mode == M_SLOW || mode == M_OFFLINE) && id == slow_lcore;
	(void)arg;

	/* 1. register once, 2. go online before the first dereference */
	rte_rcu_qsbr_thread_register(qs, id);
	rte_rcu_qsbr_thread_online(qs, id);

	while (!rte_atomic_load_explicit(&stop, rte_memory_order_relaxed)) {
		/* ---- critical section: we hold a reference to *c ---- */
		struct cfg *c = rte_atomic_load_explicit(&cur, rte_memory_order_acquire);
		int bad = rte_atomic_load_explicit(&c->magic, rte_memory_order_relaxed) != ALIVE;
		uint64_t v = c->version;
		for (int i = 0; i < NPAY; i++)
			bad |= (c->payload[i] != v);
		if (is_slow && mode == M_SLOW)
			rte_delay_us_block(50);	/* still holding c */
		/* re-check after use: was it freed under our feet? */
		bad |= rte_atomic_load_explicit(&c->magic, rte_memory_order_acquire) != ALIVE;
		s->uaf += bad;
		s->reads++;
		/* ---- end of critical section: no references held ---- */
		rte_rcu_qsbr_quiescent(qs, id);

		if (is_slow && mode == M_OFFLINE) {
			/* About to block (sleep, syscall, long wait): go offline so the
			 * writer does not wait for us. No reference may be held. */
			rte_rcu_qsbr_thread_offline(qs, id);
			rte_delay_us_block(50);
			rte_rcu_qsbr_thread_online(qs, id);
		}
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

int
main(int argc, char **argv)
{
	static uint64_t gp[MAX_SWAPS];		/* grace period of each swap, cycles */
	const char *mname[] = { "sync", "broken", "slow", "offline" };
	unsigned int l, nswaps = 0, next_slot = 1;
	int ret;

	ret = rte_eal_init(argc, argv);
	if (ret < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	argc -= ret;
	argv += ret;
	if (argc > 1) {
		if (!strcmp(argv[1], "broken"))
			mode = M_BROKEN;
		else if (!strcmp(argv[1], "slow"))
			mode = M_SLOW;
		else if (!strcmp(argv[1], "offline"))
			mode = M_OFFLINE;
	}
	if (rte_lcore_count() < 2)
		rte_exit(EXIT_FAILURE, "need worker lcores, e.g. -l 0-3\n");
	slow_lcore = rte_get_next_lcore(-1, 1, 0);

	/* The QSBR variable: size depends on the max number of reader ids. */
	size_t sz = rte_rcu_qsbr_get_memsize(RTE_MAX_LCORE);
	qs = rte_zmalloc("ch14_qsbr", sz, RTE_CACHE_LINE_SIZE);
	if (qs == NULL || rte_rcu_qsbr_init(qs, RTE_MAX_LCORE) != 0)
		rte_exit(EXIT_FAILURE, "qsbr init failed\n");
	printf("rcu_swap mode=%s: qsbr variable for %u thread ids = %zu bytes, %u readers\n",
	       mname[mode], RTE_MAX_LCORE, sz, rte_lcore_count() - 1);

	cfg_fill(&slots[0], 1);
	rte_atomic_store_explicit(&cur, &slots[0], rte_memory_order_release);
	rte_eal_mp_remote_launch(reader, NULL, SKIP_MAIN);
	rte_delay_ms(10);	/* let the readers register and go online */

	uint64_t hz = rte_get_tsc_hz(), start = rte_get_tsc_cycles();
	while (nswaps < MAX_SWAPS && rte_get_tsc_cycles() - start < hz * RUN_MS / 1000) {
		/* build the new version in a free slot (nobody can see it yet) */
		struct cfg *n = &slots[next_slot];
		next_slot = (next_slot + 1) % NSLOTS;
		cfg_fill(n, nswaps + 2);

		/* publish: one atomic pointer swap; readers see old or new */
		struct cfg *old = rte_atomic_exchange_explicit(&cur, n, rte_memory_order_acq_rel);

		uint64_t t0 = rte_rdtsc();
		if (mode != M_BROKEN)
			/* wait until every online reader has reported a quiescent
			 * state after the swap; the writer is not a reader, so it
			 * passes RTE_QSBR_THRID_INVALID */
			rte_rcu_qsbr_synchronize(qs, RTE_QSBR_THRID_INVALID);
		gp[nswaps++] = rte_rdtsc() - t0;

		cfg_free(old);	/* safe only after the grace period */
	}
	rte_atomic_store_explicit(&stop, 1, rte_memory_order_relaxed);
	rte_eal_mp_wait_lcore();

	qsort(gp, nswaps, sizeof(gp[0]), cmp_u64);
	double us = hz / 1e6;
	printf("swaps: %u in %.0f ms\n", nswaps,
	       (double)(rte_get_tsc_cycles() - start) * 1000.0 / hz);
	printf("grace period: median %.2f us, min %.2f us, p99 %.2f us, max %.2f us\n",
	       gp[nswaps / 2] / us, gp[0] / us, gp[nswaps * 99 / 100] / us, gp[nswaps - 1] / us);
	uint64_t total_uaf = 0;
	RTE_LCORE_FOREACH_WORKER(l) {
		printf("  reader lcore %u%s: %10" PRIu64 " reads, %8" PRIu64 " saw freed/torn config\n",
		       l, ((mode == M_SLOW || mode == M_OFFLINE) && l == slow_lcore) ? " (slow)" : "",
		       rst[l].reads, rst[l].uaf);
		total_uaf += rst[l].uaf;
	}
	printf("result: %s\n", total_uaf ? "USE-AFTER-FREE DETECTED" : "no use-after-free");
	rte_free(qs);
	rte_eal_cleanup();
	return 0;
}
