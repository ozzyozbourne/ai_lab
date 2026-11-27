/* SPDX-License-Identifier: BSD-3-Clause
 *
 * Chapter 14: litmus.c - memory-ordering litmus tests on two lcores.
 *
 * A "litmus test" is a tiny two-thread program plus a question: "can this
 * outcome happen?". We run each test ITERS times and count every outcome.
 *
 *   MP (message passing)          SB (store buffering, "Dekker")
 *   T0: data = 1;                 T0: x = 1;   r1 = y;
 *       flag = 1;                 T1: y = 1;   r2 = x;
 *   T1: r1 = flag;
 *       r2 = data;
 *   forbidden: r1==1 && r2==0     forbidden under sequential consistency:
 *   (saw the flag, missed data)   r1==0 && r2==0 (both loads beat both stores)
 *
 * On x86 (TSO) the hardware never reorders store->store or load->load, so
 * MP shows zero forbidden outcomes even with relaxed ordering. SB is the one
 * reordering x86 does show: a store waits in the store buffer while a later
 * load to another address goes ahead. Release/acquire does NOT forbid it;
 * only a seq_cst fence (or seq_cst operations) does.
 *
 * The last part measures what each barrier costs on this CPU.
 *
 * Run: ./litmus -l 0-2 --no-pci --no-huge -m 64 --file-prefix=ch14-litmus [-- ITERS]
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <inttypes.h>

#include <rte_eal.h>
#include <rte_lcore.h>
#include <rte_launch.h>
#include <rte_cycles.h>
#include <rte_pause.h>
#include <rte_atomic.h>      /* rte_atomic_thread_fence, rte_mb, rte_io_wmb */
#include <rte_stdatomic.h>   /* RTE_ATOMIC, rte_atomic_*_explicit */
#include <rte_common.h>
#include <rte_debug.h>

/* Each shared variable gets its own cache line, so the test is about
 * ordering, not about two variables sharing a line. */
struct __rte_cache_aligned line { RTE_ATOMIC(int) v; };
static struct line X, Y, DATA, FLAG;

/* A two-thread spin barrier: a counter both threads increment. */
static struct line BAR;
static uint64_t iters = 1000000;

enum test {
	MP_RELAXED, MP_RELACQ,
	SB_RELAXED, SB_RELACQ, SB_FENCE,
	NB_TESTS
};
static const char *test_name[NB_TESTS] = {
	"MP  relaxed store/relaxed load",
	"MP  release store/acquire load",
	"SB  relaxed",
	"SB  release store/acquire load",
	"SB  relaxed + seq_cst fence",
};
/* which (r1,r2) outcome is the "interesting" one for each test */
static const int forbidden[NB_TESTS][2] = {
	{1, 0}, {1, 0}, {0, 0}, {0, 0}, {0, 0}
};

static enum test cur;
/* results: one byte per iteration and thread (r1 from T0 or T1, see below) */
static uint8_t *res[2];

static inline void
barrier2(uint64_t *gen)
{
	/* Both threads add 1; generation g is complete when the counter is 2*g. */
	*gen += 2;
	rte_atomic_fetch_add_explicit(&BAR.v, 1, rte_memory_order_acq_rel);
	while ((uint64_t)rte_atomic_load_explicit(&BAR.v, rte_memory_order_acquire) < *gen)
		rte_pause();
}

static int
litmus_thread(void *arg)
{
	int me = (int)(uintptr_t)arg;	/* 0 = T0, 1 = T1 */
	uint64_t gen = 0;
	int r;

	for (uint64_t i = 0; i < iters; i++) {
		barrier2(&gen);		/* start both threads together */
		r = 0;
		switch (cur) {
		case MP_RELAXED:
			if (me == 0) {
				rte_atomic_store_explicit(&DATA.v, 1, rte_memory_order_relaxed);
				rte_atomic_store_explicit(&FLAG.v, 1, rte_memory_order_relaxed);
			} else {
				int f = rte_atomic_load_explicit(&FLAG.v, rte_memory_order_relaxed);
				int d = rte_atomic_load_explicit(&DATA.v, rte_memory_order_relaxed);
				r = f | (d << 1);
			}
			break;
		case MP_RELACQ:
			if (me == 0) {
				rte_atomic_store_explicit(&DATA.v, 1, rte_memory_order_relaxed);
				rte_atomic_store_explicit(&FLAG.v, 1, rte_memory_order_release);
			} else {
				int f = rte_atomic_load_explicit(&FLAG.v, rte_memory_order_acquire);
				int d = rte_atomic_load_explicit(&DATA.v, rte_memory_order_relaxed);
				r = f | (d << 1);
			}
			break;
		case SB_RELAXED:
			if (me == 0) {
				rte_atomic_store_explicit(&X.v, 1, rte_memory_order_relaxed);
				r = rte_atomic_load_explicit(&Y.v, rte_memory_order_relaxed);
			} else {
				rte_atomic_store_explicit(&Y.v, 1, rte_memory_order_relaxed);
				r = rte_atomic_load_explicit(&X.v, rte_memory_order_relaxed);
			}
			break;
		case SB_RELACQ:
			if (me == 0) {
				rte_atomic_store_explicit(&X.v, 1, rte_memory_order_release);
				r = rte_atomic_load_explicit(&Y.v, rte_memory_order_acquire);
			} else {
				rte_atomic_store_explicit(&Y.v, 1, rte_memory_order_release);
				r = rte_atomic_load_explicit(&X.v, rte_memory_order_acquire);
			}
			break;
		case SB_FENCE:
			if (me == 0) {
				rte_atomic_store_explicit(&X.v, 1, rte_memory_order_relaxed);
				rte_atomic_thread_fence(rte_memory_order_seq_cst);
				r = rte_atomic_load_explicit(&Y.v, rte_memory_order_relaxed);
			} else {
				rte_atomic_store_explicit(&Y.v, 1, rte_memory_order_relaxed);
				rte_atomic_thread_fence(rte_memory_order_seq_cst);
				r = rte_atomic_load_explicit(&X.v, rte_memory_order_relaxed);
			}
			break;
		default:
			break;
		}
		res[me][i] = (uint8_t)r;
		barrier2(&gen);		/* both finished the test */
		if (me == 0) {		/* reset; the next barrier publishes it */
			rte_atomic_store_explicit(&X.v, 0, rte_memory_order_relaxed);
			rte_atomic_store_explicit(&Y.v, 0, rte_memory_order_relaxed);
			rte_atomic_store_explicit(&DATA.v, 0, rte_memory_order_relaxed);
			rte_atomic_store_explicit(&FLAG.v, 0, rte_memory_order_relaxed);
		}
	}
	return 0;
}

static void
run_test(enum test t, unsigned int l0, unsigned int l1)
{
	uint64_t cnt[2][2] = {{0}};
	uint64_t t0 = rte_get_tsc_cycles();

	cur = t;
	rte_atomic_store_explicit(&BAR.v, 0, rte_memory_order_relaxed);
	rte_eal_remote_launch(litmus_thread, (void *)0, l0);
	rte_eal_remote_launch(litmus_thread, (void *)1, l1);
	rte_eal_wait_lcore(l0);
	rte_eal_wait_lcore(l1);

	for (uint64_t i = 0; i < iters; i++) {
		int r1, r2;
		if (t <= MP_RELACQ) {		/* only T1 reads: bit0 = flag, bit1 = data */
			r1 = res[1][i] & 1;
			r2 = (res[1][i] >> 1) & 1;
		} else {			/* r1 from T0, r2 from T1 */
			r1 = res[0][i];
			r2 = res[1][i];
		}
		cnt[r1][r2]++;
	}
	double ms = (double)(rte_get_tsc_cycles() - t0) * 1000.0 / rte_get_tsc_hz();
	printf("%-32s  r1,r2: 0,0=%-8" PRIu64 " 0,1=%-8" PRIu64 " 1,0=%-8" PRIu64
	       " 1,1=%-8" PRIu64 " -> outcome %d,%d seen %" PRIu64 " times (%.0f ms)\n",
	       test_name[t], cnt[0][0], cnt[0][1], cnt[1][0], cnt[1][1],
	       forbidden[t][0], forbidden[t][1],
	       cnt[forbidden[t][0]][forbidden[t][1]], ms);
}

/* ---- Part 2: what does each barrier cost? -------------------------------- */
static RTE_ATOMIC(uint64_t) sink;
#define NB 2000000

#define TIME_IT(label, stmt) do {					\
	uint64_t _s = rte_rdtsc_precise();				\
	for (int _i = 0; _i < NB; _i++) {				\
		rte_atomic_store_explicit(&sink, _i, rte_memory_order_relaxed); \
		stmt;							\
	}								\
	uint64_t _e = rte_rdtsc_precise();				\
	printf("  %-52s %6.1f cycles/iter\n", label, (double)(_e - _s) / NB); \
} while (0)

static void
barrier_costs(void)
{
	printf("\nCost of a store followed by a barrier (1 lcore, %d iterations):\n", NB);
	TIME_IT("store only", (void)0);
	TIME_IT("store + rte_compiler_barrier()", rte_compiler_barrier());
	TIME_IT("store + rte_atomic_thread_fence(release)",
		rte_atomic_thread_fence(rte_memory_order_release));
	TIME_IT("store + rte_io_wmb()", rte_io_wmb());
	TIME_IT("store + rte_atomic_thread_fence(seq_cst)",
		rte_atomic_thread_fence(rte_memory_order_seq_cst));
	TIME_IT("store + rte_mb()  (mfence)", rte_mb());
	TIME_IT("seq_cst store (xchg) instead of relaxed store",
		rte_atomic_store_explicit(&sink, _i, rte_memory_order_seq_cst));
}

int
main(int argc, char **argv)
{
	int ret = rte_eal_init(argc, argv);
	if (ret < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	argc -= ret;
	argv += ret;
	if (argc > 1)
		iters = strtoull(argv[1], NULL, 0);

	unsigned int l0 = rte_get_next_lcore(-1, 1, 0);
	unsigned int l1 = rte_get_next_lcore(l0, 1, 0);
	if (l0 >= RTE_MAX_LCORE || l1 >= RTE_MAX_LCORE)
		rte_exit(EXIT_FAILURE, "need 2 worker lcores (e.g. -l 0-2)\n");

	res[0] = calloc(iters, 1);
	res[1] = calloc(iters, 1);
	if (res[0] == NULL || res[1] == NULL)
		rte_exit(EXIT_FAILURE, "no memory\n");

	printf("litmus: %" PRIu64 " iterations per test, T0 on lcore %u, T1 on lcore %u\n",
	       iters, l0, l1);
	printf("RTE_ATOMIC(int) is %s here (enable_stdatomic=%s)\n",
#ifdef RTE_ENABLE_STDATOMIC
	       "_Atomic(int)", "true"
#else
	       "plain int + GCC __atomic builtins", "false"
#endif
	       );
	for (int t = 0; t < NB_TESTS; t++)
		run_test(t, l0, l1);

	barrier_costs();

	free(res[0]);
	free(res[1]);
	rte_eal_cleanup();
	return 0;
}
