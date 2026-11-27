/* SPDX-License-Identifier: BSD-3-Clause
 * Chapter 11, step 3: a keepalive watchdog for the forwarding lcore.
 *
 * A forwarding lcore that gets stuck (an endless loop, a deadlock, a driver
 * that never returns) does not crash: it just silently stops forwarding.
 * The keepalive library notices. Each watched lcore sets its flag to ALIVE
 * from its poll loop; a periodic "ping" clears it. A flag that stays cleared
 * for several pings means the lcore is stuck, and a failure callback fires.
 *
 * Layout (-l 0-2 -S 2):
 *   lcore 0 (main)    control: rte_timer_manage() runs the keepalive ping timer
 *   lcore 1 (worker)  forwarding loop, calls rte_keepalive_mark_alive()
 *   lcore 2 (service) the stats service from step 2
 *
 * --stall-after S makes the worker stop marking itself alive after S seconds,
 * exactly as if it were stuck. The failure callback then "recovers" it.
 *
 *   ./step3_keepalive -l 0-2 -S 2 --no-pci --no-huge -m 128 --file-prefix=ch11-s3 \
 *       --vdev=net_ring0 --vdev=net_ring1 -- --stall-after 3 [--seconds 6] [--ka-ms 250]
 */
#include "app_common.h"

#include <errno.h>
#include <getopt.h>
#include <rte_timer.h>
#include <rte_service.h>
#include <rte_service_component.h>
#include <rte_keepalive.h>
#include <rte_malloc.h>

static struct rte_keepalive *ka;
static struct rte_timer ka_tim, stop_tim;
static uint64_t hz, t0;
static unsigned int stall_after;                /* seconds, 0 = never */
static volatile bool stalled, resume;
static enum rte_keepalive_state ka_seen[RTE_MAX_LCORE];

static const char *
ka_name(enum rte_keepalive_state s)
{
	switch (s) {
	case RTE_KA_STATE_UNUSED:  return "UNUSED";
	case RTE_KA_STATE_ALIVE:   return "ALIVE";
	case RTE_KA_STATE_MISSING: return "MISSING";
	case RTE_KA_STATE_DEAD:    return "DEAD";
	case RTE_KA_STATE_GONE:    return "GONE";
	case RTE_KA_STATE_DOZING:  return "DOZING";
	case RTE_KA_STATE_SLEEP:   return "SLEEP";
	}
	return "?";
}

static double
since_start(void)
{
	return (double)(rte_get_timer_cycles() - t0) / hz;
}

/* ---------------- the stats service (unchanged from step 2) ---------------- */
static int32_t
stats_service(void *userdata)
{
	static uint64_t next;
	static unsigned int tick;
	char tag[24];

	(void)userdata;
	if (next == 0)
		next = t0 + hz;
	if (rte_get_timer_cycles() < next)
		return -EAGAIN;
	next += hz;
	snprintf(tag, sizeof(tag), "t=%us", ++tick);
	app_print_delta(tag, 1.0);
	return 0;
}

/* ---------------- the forwarding lcore ---------------- */
static int
fwd_main(void *arg)
{
	uint64_t stall_at = stall_after ? t0 + stall_after * hz : UINT64_MAX;

	(void)arg;
	while (!force_quit) {
		app_forward_once(32);
		/* One store into this lcore's own cache line: cheap enough for
		 * every loop pass. */
		rte_keepalive_mark_alive(ka);

		if (rte_get_timer_cycles() >= stall_at) {
			stall_at = UINT64_MAX;
			stalled = true;
			printf("[%.2fs] lcore %u: simulating a hang (no forwarding, no mark_alive)\n",
			       since_start(), rte_lcore_id());
			while (!resume && !force_quit)
				rte_pause();          /* stuck: nothing marks us alive */
			stalled = false;
			printf("[%.2fs] lcore %u: back to work\n", since_start(), rte_lcore_id());
		}
	}
	return 0;
}

/* ---------------- keepalive callbacks (run on the lcore that runs the ping timer) ---------------- */

/* Called once, when a core goes DEAD -> GONE (the third ping without a mark). */
static void
ka_dead(void *data, const int core)
{
	char where[64];

	(void)data;
	printf("[%.2fs] FAILURE CALLBACK: lcore %d is dead (callback runs in %s)\n",
	       since_start(), core, app_where(where, sizeof(where)));
	/* A real app would restart the lcore's work, fail over, or exit so a
	 * supervisor restarts it. Our "hang" can be lifted, so do that. */
	resume = true;
}

static bool
ka_healthy(enum rte_keepalive_state s)
{
	return s == RTE_KA_STATE_ALIVE || s == RTE_KA_STATE_MISSING;
}

/*
 * Called for every watched core on every ping, with the state AFTER the ping.
 * A healthy core shows up as MISSING (the ping just cleared its flag) or as
 * ALIVE (it re-marked itself between the ping and this call), so flips
 * between those two are normal and not printed.
 */
static void
ka_relay(void *data, const int core, enum rte_keepalive_state st, uint64_t last_seen)
{
	(void)data;
	if (st != ka_seen[core] && !(ka_healthy(st) && ka_healthy(ka_seen[core]))) {
		printf("[%.2fs] relay: lcore %d %s -> %s (last seen %.0f ms ago)\n",
		       since_start(), core, ka_name(ka_seen[core]), ka_name(st),
		       (double)(rte_get_timer_cycles() - last_seen) * 1000.0 / hz);
	}
	ka_seen[core] = st;
}

/* rte_keepalive_dispatch_pings() has a (void *, void *) signature; wrap it
 * instead of casting the function pointer to rte_timer_cb_t. */
static void
ka_ping(struct rte_timer *tim, void *arg)
{
	rte_keepalive_dispatch_pings(tim, arg);
}

static void
stop_cb(struct rte_timer *tim, void *arg)
{
	(void)tim;
	(void)arg;
	force_quit = true;
}

int
main(int argc, char **argv)
{
	static const struct option lopts[] = {
		{"stall-after", required_argument, NULL, 'a'},
		{"seconds", required_argument, NULL, 's'},
		{"ka-ms", required_argument, NULL, 'k'},
		{NULL, 0, NULL, 0}
	};
	unsigned int seconds = 6, ka_ms = 250, fwd_lcore, svc_lcore;
	struct rte_service_spec spec;
	uint32_t svc_id, ids[RTE_MAX_LCORE];
	struct rte_mempool *pool;
	int ret, opt;

	ret = rte_eal_init(argc, argv);
	if (ret < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	argc -= ret;
	argv += ret;
	while ((opt = getopt_long(argc, argv, "", lopts, NULL)) != -1) {
		switch (opt) {
		case 'a': stall_after = atoi(optarg); break;
		case 's': seconds = atoi(optarg); break;
		case 'k': ka_ms = atoi(optarg); break;
		default: rte_exit(EXIT_FAILURE, "bad option\n");
		}
	}
	signal(SIGINT, app_on_signal);
	signal(SIGTERM, app_on_signal);

	/* worker lcores: the service lcore is NOT a worker (role SERVICE) */
	fwd_lcore = rte_get_next_lcore(-1, 1, 0);
	if (fwd_lcore >= RTE_MAX_LCORE || rte_service_lcore_list(ids, RTE_DIM(ids)) < 1)
		rte_exit(EXIT_FAILURE, "run with -l 0-2 -S 2\n");
	svc_lcore = ids[0];
	printf("main lcore %u = control, lcore %u = forwarding, lcore %u = service\n",
	       rte_get_main_lcore(), fwd_lcore, svc_lcore);

	pool = app_ports_init();
	printf("injected %u frames into port 0\n", app_inject(pool, 64));
	hz = rte_get_timer_hz();
	t0 = rte_get_timer_cycles();

	/* stats service, exactly as in step 2 */
	memset(&spec, 0, sizeof(spec));
	snprintf(spec.name, sizeof(spec.name), "ch11_stats");
	spec.callback = stats_service;
	spec.socket_id = rte_socket_id();
	if (rte_service_component_register(&spec, &svc_id) != 0)
		rte_exit(EXIT_FAILURE, "service register failed\n");
	rte_service_component_runstate_set(svc_id, 1);
	rte_service_map_lcore_set(svc_id, svc_lcore, 1);
	rte_service_runstate_set(svc_id, 1);

	/* NEW: keepalive. Create, register the cores to watch, ping from a timer. */
	ka = rte_keepalive_create(ka_dead, NULL);
	if (ka == NULL)
		rte_exit(EXIT_FAILURE, "rte_keepalive_create failed\n");
	rte_keepalive_register_relay_callback(ka, ka_relay, NULL);
	rte_keepalive_register_core(ka, fwd_lcore);
	rte_timer_subsystem_init();
	rte_timer_init(&ka_tim);
	rte_timer_init(&stop_tim);
	rte_timer_reset(&ka_tim, hz / 1000 * ka_ms, PERIODICAL, rte_lcore_id(), ka_ping, ka);
	rte_timer_reset(&stop_tim, seconds * hz + hz / 10, SINGLE, rte_lcore_id(), stop_cb, NULL);
	printf("keepalive: ping every %u ms; a core is declared dead after 3 pings without a mark\n",
	       ka_ms);

	rte_eal_remote_launch(fwd_main, NULL, fwd_lcore);

	/* The control lcore does not need to spin: sleeping 1 ms between
	 * rte_timer_manage() calls is plenty for a 250 ms ping. */
	while (!force_quit) {
		rte_timer_manage();
		rte_delay_us_sleep(1000);
	}

	rte_eal_wait_lcore(fwd_lcore);
	rte_service_runstate_set(svc_id, 0);
	rte_service_lcore_stop(svc_lcore);
	rte_eal_wait_lcore(svc_lcore);
	rte_service_map_lcore_set(svc_id, svc_lcore, 0);
	rte_service_component_runstate_set(svc_id, 0);
	rte_service_component_unregister(svc_id);
	rte_timer_stop(&ka_tim);
	printf("final keepalive state of lcore %u: %s (%s)\n", fwd_lcore,
	       ka_name(ka_seen[fwd_lcore]), ka_healthy(ka_seen[fwd_lcore]) ? "healthy" : "NOT healthy");
	rte_free(ka);      /* rte_keepalive_create() used rte_zmalloc() */
	rte_timer_subsystem_finalize();
	app_ports_close();
	rte_eal_cleanup();
	return 0;
}
