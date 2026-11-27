/* SPDX-License-Identifier: BSD-3-Clause
 * Chapter 11, step 1: mini_l2fwd + rte_timer.
 *
 * New in this step:
 *   - a PERIODICAL timer that prints per-port stats once per second
 *   - a SINGLE (one-shot) timer that ends the run after --seconds
 *   - rte_timer_manage() called from the poll loop, at most every 100 us
 *   - a measurement of what rte_timer_manage() costs per call
 *
 * Everything runs on ONE lcore (-l 0): the timer callbacks run inside
 * rte_timer_manage(), i.e. on the forwarding lcore, between two bursts.
 *
 *   ./step1_timer -l 0 --no-pci --no-huge -m 128 --file-prefix=ch11-s1 \
 *       --vdev=net_ring0 --vdev=net_ring1 -- [--seconds S] [--inject N] [--manage-us U]
 */
#include <getopt.h>
#include <rte_timer.h>

#include "app_common.h"

static struct rte_timer stats_tim;   /* PERIODICAL, 1 s */
static struct rte_timer stop_tim;    /* SINGLE, --seconds */
static uint64_t hz;

/* Timer callbacks get the timer itself and the 'arg' given to rte_timer_reset(). */
static void
stats_cb(struct rte_timer *tim, void *arg)
{
	unsigned int *tick = arg;
	char tag[24], where[64];

	(void)tim;
	snprintf(tag, sizeof(tag), "t=%us", ++*tick);
	app_print_delta(tag, 1.0);
	if (*tick == 1)
		printf("      (stats_cb runs in %s)\n", app_where(where, sizeof(where)));
}

static void
stop_cb(struct rte_timer *tim, void *arg)
{
	(void)tim;
	(void)arg;
	printf("stop timer fired (SINGLE): state now %s\n",
	       rte_timer_pending(&stop_tim) ? "PENDING" : "not pending");
	force_quit = true;
}

int
main(int argc, char **argv)
{
	static const struct option lopts[] = {
		{"seconds", required_argument, NULL, 's'},
		{"inject", required_argument, NULL, 'i'},
		{"manage-us", required_argument, NULL, 'm'},
		{NULL, 0, NULL, 0}
	};
	unsigned int seconds = 3, n_inject = 64, manage_us = 100, tick = 0;
	uint64_t manage_period, prev_manage, manage_calls = 0, manage_cycles = 0;
	struct rte_mempool *pool;
	int ret, opt;

	ret = rte_eal_init(argc, argv);
	if (ret < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	argc -= ret;
	argv += ret;
	/* chapter 2's getopt, for now; step 5 replaces it with rte_argparse */
	while ((opt = getopt_long(argc, argv, "", lopts, NULL)) != -1) {
		switch (opt) {
		case 's': seconds = atoi(optarg); break;
		case 'i': n_inject = atoi(optarg); break;
		case 'm': manage_us = atoi(optarg); break;
		default: rte_exit(EXIT_FAILURE, "bad option\n");
		}
	}
	signal(SIGINT, app_on_signal);
	signal(SIGTERM, app_on_signal);

	pool = app_ports_init();
	printf("injected %u frames into port 0\n", app_inject(pool, n_inject));

	/* 1. once per process, after rte_eal_init() */
	ret = rte_timer_subsystem_init();
	if (ret < 0)
		rte_exit(EXIT_FAILURE, "rte_timer_subsystem_init: %d\n", ret);

	/* 2. a timer must be initialised before its first reset */
	rte_timer_init(&stats_tim);
	rte_timer_init(&stop_tim);

	/* 3. arm them. Ticks are TSC cycles; tim_lcore = the lcore whose
	 *    rte_timer_manage() will run the callback (here: ourselves). */
	hz = rte_get_timer_hz();
	ret = rte_timer_reset(&stats_tim, hz, PERIODICAL, rte_lcore_id(),
			      stats_cb, &tick);
	if (ret == 0)
		ret = rte_timer_reset(&stop_tim, seconds * hz, SINGLE,
				      rte_lcore_id(), stop_cb, NULL);
	if (ret != 0)
		rte_exit(EXIT_FAILURE, "rte_timer_reset failed\n");
	printf("timer hz %" PRIu64 ", stats every 1 s (PERIODICAL), stop after %u s (SINGLE), "
	       "rte_timer_manage every %u us\n", hz, seconds, manage_us);

	manage_period = hz / 1000000 * manage_us;
	prev_manage = rte_get_timer_cycles();

	while (!force_quit) {
		uint64_t now;

		app_forward_once(32);

		/* 4. drive the timers. Calling rte_timer_manage() on every loop
		 *    pass would work too, but it reads the clock and touches the
		 *    skiplist head each time: rate-limit it with one TSC compare. */
		now = rte_get_timer_cycles();
		if (now - prev_manage >= manage_period) {
			rte_timer_manage();
			manage_cycles += rte_get_timer_cycles() - now;
			manage_calls++;
			prev_manage = now;
		}
	}

	printf("rte_timer_manage(): %" PRIu64 " calls, average %.0f cycles per call "
	       "(includes the callbacks that ran)\n",
	       manage_calls, manage_calls ? (double)manage_cycles / manage_calls : 0.0);
	printf("stats timer still pending: %s\n",
	       rte_timer_pending(&stats_tim) ? "yes (PERIODICAL re-arms itself)" : "no");
	rte_timer_stop(&stats_tim);
	printf("after rte_timer_stop(): pending=%d\n", rte_timer_pending(&stats_tim));
	/* Prints per-lcore counters only when DPDK was built with
	 * RTE_LIBRTE_TIMER_DEBUG; a default build prints just a header. */
	rte_timer_dump_stats(stdout);

	rte_timer_subsystem_finalize();
	app_ports_close();
	rte_eal_cleanup();
	return 0;
}
