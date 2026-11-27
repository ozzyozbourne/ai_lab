/* SPDX-License-Identifier: BSD-3-Clause
 *
 * ring_modes_bench.c - Chapter 5, example 3: SP/SC vs MP/MC vs RTS vs HTS.
 *
 * Every lcore except the last is a producer; the last lcore is the single
 * consumer. (In SP/SC mode only the main lcore produces, because an SP ring
 * must never see two producers.) Each measurement runs for a fixed amount of
 * TSC time (-d ms, default 100), NOT a fixed number of objects. That matters
 * for the overcommitted run (--lcores='(0-3)@1', four lcores time-sharing
 * one CPU): there, a producer that is preempted between "move head" and
 * "update tail" makes every other producer spin for a whole timeslice, and a
 * fixed-count run could take minutes. A fixed-time run always finishes.
 *
 * Each (mode, burst) pair is measured -r times (default 5); we print the
 * median, min and max throughput and the median cost in TSC cycles per
 * object (wall-clock cycles divided by objects delivered).
 *
 * -s selects the "symmetric" workload used by DPDK's own ring stress tests
 * (app/test/test_ring_stress_impl.h): the ring starts half full and EVERY
 * lcore loops "dequeue b objects, enqueue them back". The ring then never
 * fills or empties, so what limits throughput is only the synchronisation
 * between threads - which is exactly what we want to see when the threads
 * are preempted. In SP/SC mode only the main lcore runs (an ST ring must
 * not be shared).
 *
 * Run:
 *   ./ring_modes_bench -l 0-1 --no-pci --no-huge -m 64 --file-prefix=ch05-bench
 *   ./ring_modes_bench -l 0-2 --no-pci --no-huge -m 64 --file-prefix=ch05-bench
 *   ./ring_modes_bench --lcores='(0-3)@1' --no-pci --no-huge -m 64 --file-prefix=ch05-bench
 *   ./ring_modes_bench --lcores='(0-3)@1' ... -- -s
 *   App options after "--":  -d <ms per run>  -r <runs>  -s (symmetric)
 */
#define _GNU_SOURCE             /* for cpu_set_t / rte_cpuset_t */
#include <sched.h>
#include <stdio.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <getopt.h>

#include <rte_eal.h>
#include <rte_lcore.h>
#include <rte_launch.h>
#include <rte_errno.h>
#include <rte_cycles.h>
#include <rte_pause.h>
#include <rte_stdatomic.h>
#include <rte_ring.h>
#include <rte_debug.h>

#define MAX_BURST 32
#define RING_SIZE 1024
#define MAX_RUNS  15

struct mode {
	const char *name;
	unsigned int flags;
	int single_producer;
};

static const struct mode modes[] = {
	{ "SP/SC",   RING_F_SP_ENQ | RING_F_SC_DEQ,         1 },
	{ "MP/MC",   0,                                     0 },
	{ "RTS",     RING_F_MP_RTS_ENQ | RING_F_MC_RTS_DEQ, 0 },
	{ "HTS",     RING_F_MP_HTS_ENQ | RING_F_MC_HTS_DEQ, 0 },
};
static const unsigned int bursts[] = { 1, 8, 32 };

/* ---- state shared by all lcores for one run ------------------------- */
static struct rte_ring *ring;
static unsigned int burst;
static unsigned int nprod;                 /* producers in this run */
static uint64_t deadline;                  /* TSC value: stop producing */
static RTE_ATOMIC(uint32_t) go;            /* start barrier */
static RTE_ATOMIC(uint32_t) prod_done;     /* producers that finished */
static RTE_ATOMIC(uint32_t) cons_done;     /* consumer finished */
static uint64_t consumed;                  /* written by the consumer */
static uint64_t moved[RTE_MAX_LCORE];      /* symmetric mode, per lcore */
static RTE_ATOMIC(uint32_t) sym_done;      /* symmetric threads finished */

static void *objs[MAX_BURST];              /* values are irrelevant */

static void
wait_go(void)
{
	while (rte_atomic_load_explicit(&go, rte_memory_order_acquire) == 0)
		rte_pause();
}

static void
produce(void)
{
	wait_go();
	while (rte_rdtsc() < deadline) {
		/* Default call: dispatches on the sync mode set by the flags
		 * at create time (SP, MP, RTS or HTS). */
		if (rte_ring_enqueue_burst(ring, objs, burst, NULL) == 0)
			rte_pause();
	}
	rte_atomic_fetch_add_explicit(&prod_done, 1, rte_memory_order_release);
}

static void
consume(void)
{
	void *out[MAX_BURST];
	uint64_t got = 0;

	wait_go();
	for (;;) {
		unsigned int n = rte_ring_dequeue_burst(ring, out, burst, NULL);
		got += n;
		if (n == 0) {
			if (rte_atomic_load_explicit(&prod_done,
					rte_memory_order_acquire) == nprod &&
			    rte_ring_empty(ring))
				break;
			rte_pause();
		}
	}
	consumed = got;
	rte_atomic_store_explicit(&cons_done, 1, rte_memory_order_release);
}

/* Symmetric worker: dequeue a batch, put it straight back. Bulk calls so
 * that what we take is exactly what we return. */
static void
both(void)
{
	void *tmp[MAX_BURST];
	uint64_t n_moved = 0;

	wait_go();
	while (rte_rdtsc() < deadline) {
		if (rte_ring_dequeue_bulk(ring, tmp, burst, NULL) == 0) {
			rte_pause();
			continue;
		}
		while (rte_ring_enqueue_bulk(ring, tmp, burst, NULL) == 0)
			rte_pause();
		n_moved += burst;
	}
	moved[rte_lcore_id()] = n_moved;
	rte_atomic_fetch_add_explicit(&sym_done, 1, rte_memory_order_release);
}

/* What each worker does in a run: 0 = idle, 1 = produce, 2 = consume,
 * 3 = symmetric (dequeue + enqueue) */
static int role[RTE_MAX_LCORE];

static int
worker_main(void *arg __rte_unused)
{
	switch (role[rte_lcore_id()]) {
	case 1: produce(); break;
	case 2: consume(); break;
	case 3: both(); break;
	default: break;
	}
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
	unsigned int ms = 100, runs = 5, lc, i, m, b, k;
	unsigned int lcores[RTE_MAX_LCORE], nlc = 0;
	int opt, sym = 0;

	int ret = rte_eal_init(argc, argv);
	if (ret < 0)
		rte_exit(EXIT_FAILURE, "rte_eal_init failed\n");
	argc -= ret;
	argv += ret;
	while ((opt = getopt(argc, argv, "d:r:s")) != -1) {
		if (opt == 'd')
			ms = atoi(optarg);
		else if (opt == 'r')
			runs = atoi(optarg);
		else if (opt == 's')
			sym = 1;
	}
	if (runs < 1 || runs > MAX_RUNS)
		runs = 5;

	RTE_LCORE_FOREACH(lc)              /* main first, then workers */
		lcores[nlc++] = lc;
	if (nlc < 2)
		rte_exit(EXIT_FAILURE, "need at least 2 lcores\n");
	unsigned int cons_lc = lcores[nlc - 1];
	unsigned int max_prod = nlc - 1;   /* main + all workers but the last */

	for (i = 0; i < MAX_BURST; i++)
		objs[i] = (void *)(uintptr_t)(i + 1);

	printf("lcores (lcore@cpus):");
	for (i = 0; i < nlc; i++) {
		rte_cpuset_t cs = rte_lcore_cpuset(lcores[i]);
		printf(" %u@", lcores[i]);
		for (int c = 0, first = 1; c < CPU_SETSIZE; c++)
			if (CPU_ISSET(c, &cs)) {
				printf("%s%d", first ? "" : ",", c);
				first = 0;
			}
	}
	if (sym)
		printf("\nsymmetric: every lcore dequeues %s and enqueues back,"
		       " ring starts half full\n", "b objects");
	else
		printf("\nproducers: main lcore %u + %u worker(s); consumer: lcore %u\n",
		       lcores[0], max_prod - 1, cons_lc);
	printf("ring size %u, %u ms per run, median of %u runs, TSC %" PRIu64 " MHz\n\n",
	       RING_SIZE, ms, runs, rte_get_tsc_hz() / 1000000);
	printf("%-6s %5s %5s %12s %12s %12s %10s\n", "mode", "burst",
	       sym ? "thr" : "prod",
	       "Mobj/s med", "min", "max", "cyc/obj");

	for (m = 0; m < RTE_DIM(modes); m++) {
		for (b = 0; b < RTE_DIM(bursts); b++) {
			double mops[MAX_RUNS], cyc[MAX_RUNS];
			burst = bursts[b];
			nprod = modes[m].single_producer ? 1 : max_prod;
			if (sym)
				nprod = modes[m].single_producer ? 1 : nlc;

			for (k = 0; k < runs; k++) {
				ring = rte_ring_create("bench", RING_SIZE,
					rte_socket_id(), modes[m].flags);
				if (ring == NULL)
					rte_exit(EXIT_FAILURE, "create: %s\n",
						 rte_strerror(rte_errno));
				rte_atomic_store_explicit(&go, 0, rte_memory_order_relaxed);
				rte_atomic_store_explicit(&prod_done, 0, rte_memory_order_relaxed);
				rte_atomic_store_explicit(&cons_done, 0, rte_memory_order_relaxed);
				rte_atomic_store_explicit(&sym_done, 0, rte_memory_order_relaxed);
				consumed = 0;
				memset(moved, 0, sizeof(moved));
				if (sym) {
					/* Pre-fill half the ring. */
					void *fill[RING_SIZE / 2];
					for (i = 0; i < RING_SIZE / 2; i++)
						fill[i] = objs[0];
					rte_ring_enqueue_bulk(ring, fill, RING_SIZE / 2, NULL);
				}

				/* Roles: workers 1..nprod-1 produce, last consumes;
				 * in symmetric mode the first nprod lcores do both. */
				for (i = 1; i < nlc; i++) {
					unsigned int id = lcores[i];
					if (sym)
						role[id] = (i < nprod) ? 3 : 0;
					else
						role[id] = (id == cons_lc) ? 2 :
							   (i < nprod) ? 1 : 0;
					rte_eal_remote_launch(worker_main, NULL, id);
				}

				uint64_t t0 = rte_rdtsc();
				deadline = t0 + rte_get_tsc_hz() * ms / 1000;
				rte_atomic_store_explicit(&go, 1, rte_memory_order_release);
				/* Sleep instead of spinning, so that in the
				 * overcommitted run main gives its CPU away. */
				if (sym) {
					both();        /* the main lcore works too */
					while (rte_atomic_load_explicit(&sym_done,
						rte_memory_order_acquire) < nprod)
						usleep(100);
					for (i = 0; i < nlc; i++)
						consumed += moved[lcores[i]];
				} else {
					produce();     /* the main lcore produces too */
					while (rte_atomic_load_explicit(&cons_done,
						rte_memory_order_acquire) == 0)
						usleep(100);
				}
				uint64_t t1 = rte_rdtsc();
				rte_eal_mp_wait_lcore();

				double secs = (double)(t1 - t0) / rte_get_tsc_hz();
				mops[k] = consumed / secs / 1e6;
				cyc[k] = consumed ? (double)(t1 - t0) / consumed : 0;
				rte_ring_free(ring);
			}
			qsort(mops, runs, sizeof(double), cmp_dbl);
			qsort(cyc, runs, sizeof(double), cmp_dbl);
			printf("%-6s %5u %5u %12.2f %12.2f %12.2f %10.1f\n",
			       modes[m].name, burst, nprod, mops[runs / 2],
			       mops[0], mops[runs - 1], cyc[runs / 2]);
			fflush(stdout);
		}
	}
	rte_eal_cleanup();
	return 0;
}
