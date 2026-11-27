/* SPDX-License-Identifier: BSD-3-Clause
 * Chapter 13: logdp.c - fast-path logging: RTE_LOG_DP versus RTE_LOG.
 *
 * RTE_LOG(level, type, ...) is filtered at RUN time: every call checks the
 * current level of the log type (set with --log-level). Cheap, but not free,
 * and the format string and the call stay in the binary.
 *
 * RTE_LOG_DP(level, type, ...) is ALSO filtered at COMPILE time against
 * RTE_LOG_DP_LEVEL (rte_config.h: RTE_LOG_INFO). A DEBUG message is a
 * constant-false branch: the compiler deletes it, so --log-level=...:debug
 * cannot bring it back. Use it inside per-packet loops.
 *
 *   ./logdp -l 0 --no-pci --no-huge -m 64 --file-prefix=ch13-logdp \
 *       --log-level=user.ch13:debug --log-timestamp=delta
 */
#include <rte_log.h>
#include "ch13_common.h"

/* a dynamic log type named "user.ch13", default level INFO */
RTE_LOG_REGISTER(ch13_logtype, user.ch13, INFO);
#define RTE_LOGTYPE_CH13 ch13_logtype      /* the 't' argument of RTE_LOG */

#define N 10000000
#define RUNS 5

static int
cmp_d(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;

	return x < y ? -1 : x > y;
}

int
main(int argc, char **argv)
{
	static const char *what[3] = {"empty loop",
		"+ RTE_LOG_DP(DEBUG) (gone)", "+ RTE_LOG(DEBUG) (run-time)"};
	double c[3][RUNS];
	volatile uint64_t sink = 0;
	unsigned int i, r, k;
	uint64_t t0;

	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");

	printf("RTE_LOG_DP_LEVEL = %d (INFO=%d DEBUG=%d), user.ch13 level now %d\n",
	       RTE_LOG_DP_LEVEL, RTE_LOG_INFO, RTE_LOG_DEBUG,
	       rte_log_get_level(ch13_logtype));
	fflush(stdout);

	RTE_LOG(INFO, CH13, "1: RTE_LOG    INFO  - printed\n");
	RTE_LOG(DEBUG, CH13, "2: RTE_LOG    DEBUG - printed only with user.ch13:debug\n");
	RTE_LOG_DP(INFO, CH13, "3: RTE_LOG_DP INFO  - printed\n");
	RTE_LOG_DP(DEBUG, CH13, "4: RTE_LOG_DP DEBUG - compiled out, never printed\n");
	RTE_LOG_LINE(NOTICE, CH13, "5: RTE_LOG_LINE adds the newline for you");

	/* What a disabled log line costs inside a loop. Lower the level to
	 * INFO first so that the DEBUG lines are filtered at run time. */
	rte_log_set_level(ch13_logtype, RTE_LOG_INFO);

	for (r = 0; r < RUNS; r++) {
		t0 = rte_rdtsc();
		for (i = 0; i < N; i++)
			sink += i;
		c[0][r] = (double)(rte_rdtsc() - t0) / N;

		t0 = rte_rdtsc();
		for (i = 0; i < N; i++) {
			sink += i;
			RTE_LOG_DP(DEBUG, CH13, "pkt %u\n", i);   /* compiled out */
		}
		c[1][r] = (double)(rte_rdtsc() - t0) / N;

		t0 = rte_rdtsc();
		for (i = 0; i < N; i++) {
			sink += i;
			RTE_LOG(DEBUG, CH13, "pkt %u\n", i);      /* run-time filter */
		}
		c[2][r] = (double)(rte_rdtsc() - t0) / N;
	}
	printf("cycles per iteration, %d iterations x %d runs (median [min..max]):\n",
	       N, RUNS);
	for (k = 0; k < 3; k++) {
		qsort(c[k], RUNS, sizeof(double), cmp_d);
		printf("  %-28s %5.2f [%.2f..%.2f]\n", what[k],
		       c[k][RUNS / 2], c[k][0], c[k][RUNS - 1]);
	}
	rte_eal_cleanup();
	return 0;
}
