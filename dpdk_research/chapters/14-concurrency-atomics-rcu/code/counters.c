/* SPDX-License-Identifier: BSD-3-Clause
 *
 * Chapter 14: counters.c - one packet counter per worker, four layouts.
 *
 *   shared  one RTE_ATOMIC(uint64_t), every worker does a relaxed fetch_add
 *           (x86: lock xadd). Always correct, but one cache line for all.
 *   packed  uint64_t packed[RTE_MAX_LCORE]: each worker owns one slot, but
 *           8 slots share a 64-byte line -> false sharing.
 *   padded  one counter per cache line plus RTE_CACHE_GUARD after it.
 *   lcorevar RTE_LCORE_VAR_HANDLE / RTE_LCORE_VAR_ALLOC / RTE_LCORE_VAR:
 *           the EAL places each lcore's copy RTE_MAX_LCORE_VAR bytes apart.
 *
 * In the last three a counter has exactly one writer, so the natural
 * increment is a relaxed load + relaxed store (no lock prefix): readers on
 * other lcores see a value that is never torn, possibly a little old.
 * We also run each of them
 *   - with a "stats reader" on the main lcore that keeps summing all
 *     counters while the workers count (like a telemetry thread polling), and
 *   - with a locked fetch_add instead of load+store (a common mistake: an
 *     atomic RMW on a counter that only one lcore writes).
 *
 * Each run: every worker does ITERS increments; we time it with the TSC and
 * report cycles per increment (median, min, max of RUNS runs), then the
 * main lcore aggregates the counters and checks the total.
 *
 * Build with -DALLOW_EXPERIMENTAL_API (lcore variables are experimental).
 * Run: ./counters -l 0-3 --no-pci --no-huge -m 64 --file-prefix=ch14-cnt
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdalign.h>
#include <inttypes.h>

#include <rte_eal.h>
#include <rte_lcore.h>
#include <rte_launch.h>
#include <rte_cycles.h>
#include <rte_pause.h>
#include <rte_common.h>
#include <rte_debug.h>
#include <rte_stdatomic.h>
#include <rte_lcore_var.h>

#define ITERS 5000000ULL
#define RUNS 5

/* Layout 1: one shared counter */
static struct __rte_cache_aligned { RTE_ATOMIC(uint64_t) v; } shared;

/* Layout 2: packed array (false sharing between neighbouring lcores) */
static __rte_cache_aligned RTE_ATOMIC(uint64_t) packed[RTE_MAX_LCORE];

/* Layout 3: padded array: 64 B counter line + 64 B guard line per lcore */
struct padded_ctr {
	alignas(RTE_CACHE_LINE_SIZE) RTE_ATOMIC(uint64_t) v;
	RTE_CACHE_GUARD;
};
static struct padded_ctr padded[RTE_MAX_LCORE];

/* Layout 4: lcore variable. No alignment or guard needed (and the docs say
 * not to add them): each lcore's copy is in its own RTE_MAX_LCORE_VAR slice. */
struct lv_ctr {
	RTE_ATOMIC(uint64_t) v;
};
static RTE_LCORE_VAR_HANDLE(struct lv_ctr, lv);

enum layout { SHARED, PACKED, PADDED, LCOREVAR, NB_LAYOUTS };
static const char *lname[NB_LAYOUTS] = {
	"shared atomic", "packed array", "padded+GUARD", "lcore variable",
};
enum inc_kind { INC_PLAIN, INC_LOCKED };

/* the experiments, one output row each */
static const struct row {
	enum layout layout;
	enum inc_kind inc;
	int poll;		/* main lcore polls the counters meanwhile */
} rows[] = {
	{ SHARED,   INC_LOCKED, 0 },
	{ PACKED,   INC_PLAIN,  0 }, { PADDED, INC_PLAIN,  0 }, { LCOREVAR, INC_PLAIN,  0 },
	{ PACKED,   INC_PLAIN,  1 }, { PADDED, INC_PLAIN,  1 }, { LCOREVAR, INC_PLAIN,  1 },
	{ PACKED,   INC_LOCKED, 0 }, { PADDED, INC_LOCKED, 0 }, { LCOREVAR, INC_LOCKED, 0 },
};
static enum layout cur;
static enum inc_kind cur_inc;
static RTE_ATOMIC(int) running;	/* workers still counting */
static RTE_ATOMIC(int) go;
static struct __rte_cache_aligned { uint64_t cycles; } wcyc[RTE_MAX_LCORE];

/* single-writer increment: load + store, both relaxed, no lock prefix */
static inline void
inc_owned(RTE_ATOMIC(uint64_t) *p)
{
	rte_atomic_store_explicit(p,
		rte_atomic_load_explicit(p, rte_memory_order_relaxed) + 1,
		rte_memory_order_relaxed);
}

static int
worker(void *arg)
{
	unsigned int id = rte_lcore_id();
	unsigned int slot = (unsigned int)(uintptr_t)arg; /* 0,1,2: adjacent slots */
	RTE_ATOMIC(uint64_t) *mine = NULL;

	switch (cur) {
	case PACKED:   mine = &packed[slot]; break;
	case PADDED:   mine = &padded[slot].v; break;
	case LCOREVAR: mine = &RTE_LCORE_VAR(lv)->v; break;	/* my own copy */
	default: break;
	}
	while (!rte_atomic_load_explicit(&go, rte_memory_order_acquire))
		rte_pause();

	uint64_t t0 = rte_rdtsc_precise();
	if (cur == SHARED) {
		for (uint64_t i = 0; i < ITERS; i++)
			rte_atomic_fetch_add_explicit(&shared.v, 1, rte_memory_order_relaxed);
	} else if (cur_inc == INC_LOCKED) {
		for (uint64_t i = 0; i < ITERS; i++)	/* lock xadd / lock inc */
			rte_atomic_fetch_add_explicit(mine, 1, rte_memory_order_relaxed);
	} else {
		for (uint64_t i = 0; i < ITERS; i++)	/* plain mov; inc; mov */
			inc_owned(mine);
	}
	wcyc[id].cycles = rte_rdtsc_precise() - t0;
	rte_atomic_fetch_sub_explicit(&running, 1, rte_memory_order_release);
	return 0;
}

/* The reader side: sum everything (the stats thread / telemetry does this). */
static uint64_t
aggregate(enum layout l)
{
	uint64_t sum = 0;
	unsigned int i;
	struct lv_ctr *val;

	switch (l) {
	case SHARED:
		return rte_atomic_load_explicit(&shared.v, rte_memory_order_relaxed);
	case PACKED:
		for (i = 0; i < RTE_MAX_LCORE; i++)
			sum += rte_atomic_load_explicit(&packed[i], rte_memory_order_relaxed);
		return sum;
	case PADDED:
		for (i = 0; i < RTE_MAX_LCORE; i++)
			sum += rte_atomic_load_explicit(&padded[i].v, rte_memory_order_relaxed);
		return sum;
	case LCOREVAR:
		RTE_LCORE_VAR_FOREACH(i, val, lv)
			sum += rte_atomic_load_explicit(&val->v, rte_memory_order_relaxed);
		return sum;
	default:
		return 0;
	}
}

static void
reset_all(void)
{
	unsigned int i;
	struct lv_ctr *val;

	shared.v = 0;
	for (i = 0; i < RTE_MAX_LCORE; i++) {
		packed[i] = 0;
		padded[i].v = 0;
	}
	RTE_LCORE_VAR_FOREACH(i, val, lv)
		val->v = 0;
}

static int
cmp_d(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;
	return (x > y) - (x < y);
}

int
main(int argc, char **argv)
{
	unsigned int l, nw;

	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	nw = rte_lcore_count() - 1;
	if (nw < 1)
		rte_exit(EXIT_FAILURE, "need worker lcores, e.g. -l 0-3\n");

	RTE_LCORE_VAR_ALLOC(lv);	/* zeroed, never freed */

	printf("counters: %u workers x %llu increments, median of %d runs\n", nw,
	       (unsigned long long)ITERS, RUNS);
	printf("layout addresses (lcore slot 0 and 1):\n");
	printf("  packed   %p %p  (distance %zu B)\n", (void *)&packed[0], (void *)&packed[1],
	       (size_t)((char *)&packed[1] - (char *)&packed[0]));
	printf("  padded   %p %p  (distance %zu B)\n", (void *)&padded[0], (void *)&padded[1],
	       (size_t)((char *)&padded[1] - (char *)&padded[0]));
	printf("  lcorevar %p %p  (distance %zu B = RTE_MAX_LCORE_VAR)\n\n",
	       (void *)RTE_LCORE_VAR_LCORE(1, lv), (void *)RTE_LCORE_VAR_LCORE(2, lv),
	       (size_t)((char *)RTE_LCORE_VAR_LCORE(2, lv) - (char *)RTE_LCORE_VAR_LCORE(1, lv)));
	printf("%-15s %-9s %-6s %10s %8s %8s %10s %s\n", "layout", "increment", "poller",
	       "median", "min", "max", "total", "check");
	printf("%-15s %-9s %-6s %10s %8s %8s\n", "", "", "", "cyc/inc", "cyc/inc", "cyc/inc");

	for (unsigned int ri = 0; ri < RTE_DIM(rows); ri++) {
		double r[RUNS];
		uint64_t total = 0, polls = 0;
		int ok = 1;

		cur = rows[ri].layout;
		cur_inc = rows[ri].inc;
		for (int run = 0; run < RUNS; run++) {
			unsigned int slot = 0;
			uint64_t cyc = 0;

			reset_all();
			rte_atomic_store_explicit(&go, 0, rte_memory_order_relaxed);
			rte_atomic_store_explicit(&running, nw, rte_memory_order_relaxed);
			RTE_LCORE_FOREACH_WORKER(l)
				rte_eal_remote_launch(worker, (void *)(uintptr_t)slot++, l);
			rte_atomic_store_explicit(&go, 1, rte_memory_order_release);
			/* optional stats reader: sum the counters until workers finish */
			while (rows[ri].poll &&
			       rte_atomic_load_explicit(&running, rte_memory_order_acquire) > 0) {
				polls += aggregate(cur) != 0;
			}
			rte_eal_mp_wait_lcore();
			RTE_LCORE_FOREACH_WORKER(l)
				cyc += wcyc[l].cycles;
			r[run] = (double)cyc / nw / ITERS;
			total = aggregate(cur);
			ok &= (total == ITERS * nw);
		}
		qsort(r, RUNS, sizeof(r[0]), cmp_d);
		printf("%-15s %-9s %-6s %10.2f %8.2f %8.2f %10" PRIu64 " %s\n", lname[cur],
		       (cur == SHARED || cur_inc == INC_LOCKED) ? "fetch_add" : "ld+st",
		       rows[ri].poll ? "yes" : "no",
		       r[RUNS / 2], r[0], r[RUNS - 1], total, ok ? "ok" : "WRONG");
		(void)polls;
	}
	rte_eal_cleanup();
	return 0;
}
