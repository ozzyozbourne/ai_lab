/* SPDX-License-Identifier: BSD-3-Clause
 *
 * tsc_lab.c - Chapter 3: time in DPDK, and the course measurement recipe.
 *
 *   ./tsc_lab -l 0 --no-pci --no-huge -m 64 --file-prefix=ch03-tsc
 *
 * Part A: check rte_get_tsc_hz() against the kernel clock.
 * Part B: cost per call of four clocks (rte_rdtsc, rte_rdtsc_precise,
 *         rte_get_timer_cycles, clock_gettime(CLOCK_MONOTONIC)).
 * Part C: rte_delay_us_block() vs rte_delay_us_sleep(): same wall time,
 *         very different CPU time.
 *
 * "How to measure on this machine" (used by every later benchmark):
 *   1. warm up once and throw the result away,
 *   2. repeat N >= 5 times (here N = 7),
 *   3. report the median, and min and max to show the noise,
 *   4. use one lcore per CPU (no oversubscription),
 *   5. never publish a number you did not measure.
 */
#define _GNU_SOURCE
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#include <rte_cycles.h>
#include <rte_eal.h>
#include <rte_errno.h>

#define REPS   7            /* N measured repetitions (after 1 warm-up) */
#define CALLS  1000000      /* calls per repetition in part B */

static volatile uint64_t sink;   /* stops the compiler deleting the loops */

static int
cmp_double(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;
	return (x > y) - (x < y);
}

/* Sort the samples and print "median (min .. max)". */
static void
report(const char *name, double *v, int n, const char *unit)
{
	qsort(v, n, sizeof(*v), cmp_double);
	printf("  %-34s median %8.2f %s   (min %8.2f, max %8.2f, N=%d)\n",
	       name, v[n / 2], unit, v[0], v[n - 1], n);
}

static uint64_t
now_ns(clockid_t c)
{
	struct timespec ts;
	clock_gettime(c, &ts);
	return (uint64_t)ts.tv_sec * 1000000000ull + ts.tv_nsec;
}

/* ---- the four clocks under test --------------------------------------- */
static inline uint64_t c_rdtsc(void)    { return rte_rdtsc(); }
static inline uint64_t c_precise(void)  { return rte_rdtsc_precise(); }
static inline uint64_t c_timer(void)    { return rte_get_timer_cycles(); }
static inline uint64_t c_mono(void)     { return now_ns(CLOCK_MONOTONIC); }

typedef uint64_t (*clock_fn)(void);

/* One repetition: CALLS calls, timed with the TSC; returns ns per call. */
static double
one_rep(clock_fn fn, double ns_per_cycle)
{
	uint64_t acc = 0, t0, t1;

	t0 = rte_rdtsc_precise();
	for (int i = 0; i < CALLS; i++)
		acc += fn();
	t1 = rte_rdtsc_precise();
	sink = acc;
	return (double)(t1 - t0) * ns_per_cycle / CALLS;
}

static void
bench_clock(const char *name, clock_fn fn, double ns_per_cycle)
{
	double v[REPS];

	one_rep(fn, ns_per_cycle);                  /* 1. warm-up, discarded */
	for (int r = 0; r < REPS; r++)              /* 2. N repetitions */
		v[r] = one_rep(fn, ns_per_cycle);
	report(name, v, REPS, "ns/call");           /* 3. median, min, max */
}

/* Part C: wall time and CPU time of one delay call, in microseconds. */
static void
bench_delay(const char *name, void (*delay)(unsigned int), unsigned int us)
{
	double wall[5], cpu[5];

	delay(us);                                   /* warm-up */
	for (int r = 0; r < 5; r++) {
		uint64_t w0 = now_ns(CLOCK_MONOTONIC);
		uint64_t c0 = now_ns(CLOCK_THREAD_CPUTIME_ID);
		delay(us);
		cpu[r]  = (now_ns(CLOCK_THREAD_CPUTIME_ID) - c0) / 1000.0;
		wall[r] = (now_ns(CLOCK_MONOTONIC) - w0) / 1000.0;
	}
	printf("  %s(%u):\n", name, us);
	report("    wall time", wall, 5, "us");
	report("    CPU time of this thread", cpu, 5, "us");
}

int
main(int argc, char **argv)
{
	int ret = rte_eal_init(argc, argv);
	uint64_t hz;
	double ns_per_cycle;

	if (ret < 0) {
		fprintf(stderr, "rte_eal_init failed: %s\n", rte_strerror(rte_errno));
		return 1;
	}
	setvbuf(stdout, NULL, _IOLBF, 0);
	hz = rte_get_tsc_hz();
	ns_per_cycle = 1e9 / (double)hz;

	printf("== A. TSC frequency\n");
	printf("  rte_get_tsc_hz()   = %" PRIu64 " Hz\n", hz);
	printf("  rte_get_timer_hz() = %" PRIu64 " Hz (timer source = TSC here)\n",
	       rte_get_timer_hz());
	{
		double v[REPS];
		for (int r = 0; r < REPS; r++) {
			uint64_t n0 = now_ns(CLOCK_MONOTONIC), t0 = rte_rdtsc_precise();
			rte_delay_us_block(20000);                 /* 20 ms */
			uint64_t n1 = now_ns(CLOCK_MONOTONIC), t1 = rte_rdtsc_precise();
			v[r] = (double)(t1 - t0) / (double)(n1 - n0) * 1000.0; /* MHz */
		}
		report("TSC measured vs CLOCK_MONOTONIC", v, REPS, "MHz");
	}

	printf("\n== B. cost of reading a clock (%d calls per repetition)\n", CALLS);
	bench_clock("rte_rdtsc()", c_rdtsc, ns_per_cycle);
	bench_clock("rte_rdtsc_precise()", c_precise, ns_per_cycle);
	bench_clock("rte_get_timer_cycles()", c_timer, ns_per_cycle);
	bench_clock("clock_gettime(CLOCK_MONOTONIC)", c_mono, ns_per_cycle);

	printf("\n== C. busy delay vs sleeping delay\n");
	bench_delay("rte_delay_us_block", rte_delay_us_block, 10000);
	bench_delay("rte_delay_us_sleep", rte_delay_us_sleep, 10000);

	rte_eal_cleanup();
	return 0;
}
