/* SPDX-License-Identifier: BSD-3-Clause
 *
 * Chapter 14: locks_bench.c - what does each DPDK lock cost, and is it fair?
 *
 * For every lock and for 1, 2 and 3 worker lcores, each worker runs
 *     lock(); shared_counter++; unlock();   my_ops++;
 * for a fixed TSC time (DURATION_MS). We report, per configuration:
 *   - cycles per lock+unlock as seen by one thread = elapsed * workers / ops
 *     (median, min and max of RUNS runs)
 *   - the share of acquisitions each lcore got in the median run (fairness)
 *   - a correctness check: shared_counter must equal the sum of my_ops
 *     (for the read-lock modes the counter is not written; readers share)
 *
 * The critical section is tiny on purpose: we measure the lock itself.
 * This is a 4-vCPU VM shared with other jobs: numbers are noisy, which is why
 * we report median/min/max.
 *
 * Run: ./locks_bench -l 0-3 --no-pci --no-huge -m 64 --file-prefix=ch14-locks
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <inttypes.h>
#include <pthread.h>

#include <rte_eal.h>
#include <rte_lcore.h>
#include <rte_launch.h>
#include <rte_cycles.h>
#include <rte_pause.h>
#include <rte_common.h>
#include <rte_debug.h>
#include <rte_stdatomic.h>
#include <rte_spinlock.h>
#include <rte_ticketlock.h>
#include <rte_mcslock.h>
#include <rte_rwlock.h>
#include <rte_pflock.h>
#include <rte_seqlock.h>

#define DURATION_MS 20
#define RUNS 5
#define MAX_W 3

enum lock_kind {
	L_SPIN, L_TICKET, L_MCS, L_RW_WRITE, L_PF_WRITE, L_SEQ_WRITE, L_MUTEX,
	L_RW_READ, L_PF_READ, NB_KINDS
};
static const char *kind_name[NB_KINDS] = {
	"rte_spinlock", "rte_ticketlock", "rte_mcslock", "rte_rwlock (write)",
	"rte_pflock (write)", "rte_seqlock (write)", "pthread_mutex",
	"rte_rwlock (read)", "rte_pflock (read)",
};

/* Each lock on its own cache line so they do not disturb each other. */
static struct __rte_cache_aligned { rte_spinlock_t l; } spin = { RTE_SPINLOCK_INITIALIZER };
static struct __rte_cache_aligned { rte_ticketlock_t l; } ticket = { RTE_TICKETLOCK_INITIALIZER };
static struct __rte_cache_aligned { RTE_ATOMIC(rte_mcslock_t *) l; } mcs; /* NULL = unlocked */
static struct __rte_cache_aligned { rte_rwlock_t l; } rw = { RTE_RWLOCK_INITIALIZER };
static struct __rte_cache_aligned { rte_pflock_t l; } pf;
static struct __rte_cache_aligned { rte_seqlock_t l; } seq = { RTE_SEQLOCK_INITIALIZER };
static struct __rte_cache_aligned { pthread_mutex_t l; } mtx = { PTHREAD_MUTEX_INITIALIZER };

/* The data the locks protect, on its own line. */
static struct __rte_cache_aligned { uint64_t counter; } shared;

/* Control flags, read by everyone, written rarely. */
static struct __rte_cache_aligned {
	RTE_ATOMIC(int) go;
	RTE_ATOMIC(int) stop;
	enum lock_kind kind;
} ctl;

/* Per-worker results, padded so that workers do not false-share. */
static struct __rte_cache_aligned { uint64_t ops; } res[RTE_MAX_LCORE];

static int
worker(void *arg)
{
	unsigned int slot = (unsigned int)(uintptr_t)arg;
	enum lock_kind k = ctl.kind;
	uint64_t ops = 0;
	uint64_t sink = 0;
	rte_mcslock_t me;	/* MCS: each thread brings its own queue node */

	while (rte_atomic_load_explicit(&ctl.go, rte_memory_order_acquire) == 0)
		rte_pause();

	while (rte_atomic_load_explicit(&ctl.stop, rte_memory_order_relaxed) == 0) {
		switch (k) {
		case L_SPIN:
			rte_spinlock_lock(&spin.l);
			shared.counter++;
			rte_spinlock_unlock(&spin.l);
			break;
		case L_TICKET:
			rte_ticketlock_lock(&ticket.l);
			shared.counter++;
			rte_ticketlock_unlock(&ticket.l);
			break;
		case L_MCS:
			rte_mcslock_lock(&mcs.l, &me);
			shared.counter++;
			rte_mcslock_unlock(&mcs.l, &me);
			break;
		case L_RW_WRITE:
			rte_rwlock_write_lock(&rw.l);
			shared.counter++;
			rte_rwlock_write_unlock(&rw.l);
			break;
		case L_PF_WRITE:
			rte_pflock_write_lock(&pf.l);
			shared.counter++;
			rte_pflock_write_unlock(&pf.l);
			break;
		case L_SEQ_WRITE:
			rte_seqlock_write_lock(&seq.l);
			shared.counter++;
			rte_seqlock_write_unlock(&seq.l);
			break;
		case L_MUTEX:
			pthread_mutex_lock(&mtx.l);
			shared.counter++;
			pthread_mutex_unlock(&mtx.l);
			break;
		case L_RW_READ:		/* readers only: they can all be inside */
			rte_rwlock_read_lock(&rw.l);
			sink += shared.counter;
			rte_rwlock_read_unlock(&rw.l);
			break;
		case L_PF_READ:
			rte_pflock_read_lock(&pf.l);
			sink += shared.counter;
			rte_pflock_read_unlock(&pf.l);
			break;
		default:
			break;
		}
		ops++;
	}
	res[slot].ops = ops + (sink & 0);	/* keep 'sink' alive */
	return 0;
}

struct run_result {
	double cyc_per_op;
	uint64_t ops[MAX_W];
	uint64_t total;
	int correct;
};

static void
one_run(enum lock_kind k, unsigned int nw, const unsigned int *lc, struct run_result *rr)
{
	uint64_t hz = rte_get_tsc_hz();

	ctl.kind = k;
	shared.counter = 0;
	rte_atomic_store_explicit(&ctl.go, 0, rte_memory_order_relaxed);
	rte_atomic_store_explicit(&ctl.stop, 0, rte_memory_order_relaxed);
	for (unsigned int i = 0; i < nw; i++) {
		res[i].ops = 0;
		rte_eal_remote_launch(worker, (void *)(uintptr_t)i, lc[i]);
	}
	uint64_t t0 = rte_get_tsc_cycles();
	rte_atomic_store_explicit(&ctl.go, 1, rte_memory_order_release);
	while (rte_get_tsc_cycles() - t0 < hz * DURATION_MS / 1000)
		rte_pause();
	rte_atomic_store_explicit(&ctl.stop, 1, rte_memory_order_relaxed);
	uint64_t elapsed = rte_get_tsc_cycles() - t0;
	for (unsigned int i = 0; i < nw; i++)
		rte_eal_wait_lcore(lc[i]);

	rr->total = 0;
	for (unsigned int i = 0; i < nw; i++) {
		rr->ops[i] = res[i].ops;
		rr->total += res[i].ops;
	}
	rr->cyc_per_op = (double)elapsed * nw / (double)rr->total;
	rr->correct = (k >= L_RW_READ) ? 1 : (shared.counter == rr->total);
}

static int
cmp_rr(const void *a, const void *b)
{
	double x = ((const struct run_result *)a)->cyc_per_op;
	double y = ((const struct run_result *)b)->cyc_per_op;
	return (x > y) - (x < y);
}

int
main(int argc, char **argv)
{
	unsigned int lc[MAX_W], nlc = 0, l;

	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	RTE_LCORE_FOREACH_WORKER(l) {
		if (nlc < MAX_W)
			lc[nlc++] = l;
	}
	if (nlc < 1)
		rte_exit(EXIT_FAILURE, "need worker lcores, e.g. -l 0-3\n");
	rte_pflock_init(&pf.l);

	printf("locks_bench: %d ms per run, median of %d runs, TSC %.2f GHz, workers on lcores",
	       DURATION_MS, RUNS, rte_get_tsc_hz() / 1e9);
	for (unsigned int i = 0; i < nlc; i++)
		printf(" %u", lc[i]);
	printf("\n\n%-20s %3s %10s %10s %10s   %-24s %s\n", "lock", "thr",
	       "median", "min", "max", "share per lcore (median)", "check");
	printf("%-20s %3s %10s %10s %10s\n", "", "", "cyc/op", "cyc/op", "cyc/op");

	for (int k = 0; k < NB_KINDS; k++) {
		for (unsigned int nw = 1; nw <= nlc; nw++) {
			struct run_result rr[RUNS];
			int all_ok = 1;

			for (int r = 0; r < RUNS; r++) {
				one_run(k, nw, lc, &rr[r]);
				all_ok &= rr[r].correct;
			}
			qsort(rr, RUNS, sizeof(rr[0]), cmp_rr);
			struct run_result *med = &rr[RUNS / 2];
			char share[64] = "";
			int off = 0;
			for (unsigned int i = 0; i < nw; i++)
				off += snprintf(share + off, sizeof(share) - off, "%s%4.1f%%",
						i ? " " : "", 100.0 * med->ops[i] / med->total);
			printf("%-20s %3u %10.1f %10.1f %10.1f   %-24s %s\n",
			       kind_name[k], nw, med->cyc_per_op, rr[0].cyc_per_op,
			       rr[RUNS - 1].cyc_per_op, share, all_ok ? "ok" : "LOST UPDATES");
		}
	}
	rte_eal_cleanup();
	return 0;
}
