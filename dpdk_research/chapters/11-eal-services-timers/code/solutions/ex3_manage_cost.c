/* SPDX-License-Identifier: BSD-3-Clause
 * Chapter 11, exercise 3 solution: what does rte_timer_manage() cost?
 *
 * Arms N timers far in the future (none expires during the test), then times
 * 200000 calls of rte_timer_manage(). Repeated 5 times per N; prints the
 * median and the min..max of the average cycles per call.
 * A final case arms 1000 timers that ALL expire, to show the cost of
 * actually running callbacks.
 *
 *   ./ex3_manage_cost -l 0 --no-pci --no-huge -m 128 --file-prefix=ch11-ex3
 */
#include <stdio.h>
#include <stdlib.h>
#include <inttypes.h>
#include <rte_eal.h>
#include <rte_lcore.h>
#include <rte_cycles.h>
#include <rte_malloc.h>
#include <rte_timer.h>

#define CALLS 200000
#define RUNS 5

static uint64_t fired;

static void
cb(struct rte_timer *t, void *arg)
{
	(void)t;
	(void)arg;
	fired++;
}

static int
cmp(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;

	return (x > y) - (x < y);
}

int
main(int argc, char **argv)
{
	static const unsigned int counts[] = {0, 10, 1000, 100000};
	struct rte_timer *tims;
	uint64_t hz, t;
	double r[RUNS];
	unsigned int c, i, run, k;

	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	rte_timer_subsystem_init();
	hz = rte_get_timer_hz();
	tims = rte_zmalloc("tims", sizeof(*tims) * 100000, 0);
	if (tims == NULL)
		rte_exit(EXIT_FAILURE, "no memory\n");

	printf("pending timers   cycles per rte_timer_manage() call, median [min..max] of %d runs\n",
	       RUNS);
	for (c = 0; c < RTE_DIM(counts); c++) {
		for (i = 0; i < counts[c]; i++) {
			rte_timer_init(&tims[i]);
			/* 1 hour away, spread so the skiplist has real work on insert */
			rte_timer_reset(&tims[i], 3600 * hz + i, SINGLE, rte_lcore_id(), cb, NULL);
		}
		for (run = 0; run < RUNS; run++) {
			t = rte_rdtsc();
			for (k = 0; k < CALLS; k++)
				rte_timer_manage();
			r[run] = (double)(rte_rdtsc() - t) / CALLS;
		}
		qsort(r, RUNS, sizeof(double), cmp);
		printf("%14u   %6.1f [%.1f..%.1f]\n", counts[c], r[2], r[0], r[RUNS - 1]);
		for (i = 0; i < counts[c]; i++)
			rte_timer_stop(&tims[i]);
	}

	/* 1000 timers that are all due: one manage() call runs 1000 callbacks */
	for (run = 0; run < RUNS; run++) {
		for (i = 0; i < 1000; i++) {
			rte_timer_init(&tims[i]);
			rte_timer_reset(&tims[i], 0, SINGLE, rte_lcore_id(), cb, NULL);
		}
		t = rte_rdtsc();
		rte_timer_manage();
		r[run] = (double)(rte_rdtsc() - t);
	}
	qsort(r, RUNS, sizeof(double), cmp);
	printf("1000 expired timers in one call: %.0f cycles [%.0f..%.0f] = %.0f cycles per callback; "
	       "fired %" PRIu64 "\n", r[2], r[0], r[RUNS - 1], r[2] / 1000, fired);
	rte_free(tims);
	rte_timer_subsystem_finalize();
	rte_eal_cleanup();
	return 0;
}
