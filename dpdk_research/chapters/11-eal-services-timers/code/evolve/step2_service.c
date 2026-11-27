/* SPDX-License-Identifier: BSD-3-Clause
 * Chapter 11, step 2: move the stats work onto a SERVICE LCORE.
 *
 * Step 1 printed stats from a timer callback on the forwarding lcore: every
 * printf() stole time from the poll loop. Here the stats code becomes a
 * registered service, and the EAL runs it on a dedicated service lcore.
 *
 * New in this step:
 *   - rte_service_component_register(): the "component" side (a driver or
 *     library would do this) creates a service with a callback
 *   - the TWO runstates: component runstate and application runstate; the
 *     service runs only when both are 1 AND it is mapped to a running lcore
 *   - rte_service_map_lcore_set() + rte_service_lcore_start(): the
 *     "application" side decides WHERE the service runs
 *   - service statistics: calls, idle calls (-EAGAIN), cycles
 *
 * Lcores: -l 0,2 -S 2. Lcore 0 (main) forwards, lcore 2 is a service lcore.
 * A service lcore must also be listed in -l. The old "-s <coremask>" still
 * works but is deprecated; run.sh runs it once to show the warning.
 *
 *   ./step2_service -l 0,2 -S 2 --no-pci --no-huge -m 128 --file-prefix=ch11-s2 \
 *       --vdev=net_ring0 --vdev=net_ring1 -- [--seconds S]
 */
#include "app_common.h"

#include <errno.h>
#include <getopt.h>
#include <rte_timer.h>
#include <rte_service.h>
#include <rte_service_component.h>

static struct rte_timer stop_tim;

struct stats_svc {
	uint64_t hz;
	uint64_t next;          /* TSC of the next report */
	unsigned int tick;
};

/*
 * The service callback. The service lcore calls it in a tight loop, as fast
 * as it can. It must do a SMALL amount of work and return:
 *   0        "I did something useful"
 *   -EAGAIN  "nothing to do this time" (counted as an idle call)
 * It must never block or loop forever: other services mapped to the same
 * lcore would never run.
 */
static int32_t
stats_service(void *userdata)
{
	struct stats_svc *s = userdata;
	uint64_t now = rte_get_timer_cycles();
	char tag[24], where[64];

	if (now < s->next)
		return -EAGAIN;
	s->next += s->hz;
	snprintf(tag, sizeof(tag), "t=%us", ++s->tick);
	app_print_delta(tag, 1.0);
	if (s->tick == 1)
		printf("      (stats_service runs in %s)\n", app_where(where, sizeof(where)));
	return 0;
}

static void
stop_cb(struct rte_timer *tim, void *arg)
{
	(void)tim;
	(void)arg;
	force_quit = true;
}

static void
list_services(const char *when)
{
	uint32_t i, n = rte_service_get_count();

	printf("[%s] %u service(s) registered:\n", when, n);
	for (i = 0; i < n; i++)
		printf("  id %u  %-24s MT_SAFE=%d  app runstate=%d  mapped to lcore 2: %d\n",
		       i, rte_service_get_name(i),
		       rte_service_probe_capability(i, RTE_SERVICE_CAP_MT_SAFE),
		       rte_service_runstate_get(i), rte_service_map_lcore_get(i, 2));
}

int
main(int argc, char **argv)
{
	static const struct option lopts[] = {
		{"seconds", required_argument, NULL, 's'},
		{NULL, 0, NULL, 0}
	};
	struct rte_service_spec spec;
	static struct stats_svc svc;
	uint32_t ids[RTE_MAX_LCORE], svc_id, svc_lcore;
	uint64_t calls, idle, cycles, loops;
	unsigned int seconds = 3;
	struct rte_mempool *pool;
	int ret, opt, n;

	ret = rte_eal_init(argc, argv);
	if (ret < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	argc -= ret;
	argv += ret;
	while ((opt = getopt_long(argc, argv, "", lopts, NULL)) != -1) {
		if (opt == 's')
			seconds = atoi(optarg);
		else
			rte_exit(EXIT_FAILURE, "bad option\n");
	}
	signal(SIGINT, app_on_signal);
	signal(SIGTERM, app_on_signal);

	/* Which lcores did -S turn into service lcores? */
	n = rte_service_lcore_list(ids, RTE_DIM(ids));
	if (n < 1)
		rte_exit(EXIT_FAILURE, "no service lcore: run with -l 0,2 -S 2\n");
	svc_lcore = ids[0];
	printf("service lcores: %d (first = lcore %u, role %s)\n", n, svc_lcore,
	       rte_eal_lcore_role(svc_lcore) == ROLE_SERVICE ? "SERVICE" : "other");

	pool = app_ports_init();
	printf("injected %u frames into port 0\n", app_inject(pool, 64));
	list_services("before register");

	/* ---- component side: create the service ---- */
	memset(&spec, 0, sizeof(spec));
	snprintf(spec.name, sizeof(spec.name), "ch11_stats");
	spec.callback = stats_service;
	spec.callback_userdata = &svc;
	spec.capabilities = 0;           /* NOT MT-safe: run on one lcore at a time */
	spec.socket_id = rte_socket_id();
	svc.hz = rte_get_timer_hz();
	if (rte_service_component_register(&spec, &svc_id) != 0)
		rte_exit(EXIT_FAILURE, "service register failed\n");
	/* The component says "I am ready to be run". */
	rte_service_component_runstate_set(svc_id, 1);

	/* ---- application side: where and whether it runs ---- */
	ret = rte_service_map_lcore_set(svc_id, svc_lcore, 1);
	printf("map service %u -> lcore %u: %d\n", svc_id, svc_lcore, ret);
	rte_service_set_stats_enable(svc_id, 1);   /* needed for the cycle counter */
	/* rte_eal_init() already called rte_service_start_with_defaults(),
	 * which started every -S lcore, so this normally says -EALREADY. */
	ret = rte_service_lcore_start(svc_lcore);
	printf("rte_service_lcore_start(%u): %d%s\n", svc_lcore, ret,
	       ret == -EALREADY ? " (-EALREADY: rte_eal_init() started it already)" : "");
	list_services("after register+map");

	/* App runstate is still 0, so the service lcore loops but never calls it. */
	rte_delay_ms(200);
	rte_service_attr_get(svc_id, RTE_SERVICE_ATTR_CALL_COUNT, &calls);
	printf("app runstate=0 for 200 ms: service calls = %" PRIu64 "\n", calls);

	/* Now the application flips its switch, and reporting starts. */
	svc.next = rte_get_timer_cycles() + svc.hz;
	rte_service_runstate_set(svc_id, 1);
	printf("app runstate=1: service is now running on lcore %u\n", svc_lcore);

	/* The forwarding loop on the main lcore no longer prints anything. */
	rte_timer_subsystem_init();
	rte_timer_init(&stop_tim);
	rte_timer_reset(&stop_tim, seconds * svc.hz + svc.hz / 10, SINGLE,
			rte_lcore_id(), stop_cb, NULL);
	while (!force_quit) {
		app_forward_once(32);
		rte_timer_manage();
	}

	/* ---- shutdown order matters ---- */
	ret = rte_service_lcore_stop(svc_lcore);
	printf("lcore_stop while service still running: %d (%s)\n", ret,
	       ret == -EBUSY ? "-EBUSY: it is the only lcore for a running service" : "ok");
	rte_service_runstate_set(svc_id, 0);
	ret = rte_service_lcore_stop(svc_lcore);
	printf("lcore_stop after runstate_set(0): %d\n", ret);
	rte_eal_wait_lcore(svc_lcore);

	/* ---- what did the service cost? (read after it stopped) ---- */
	rte_service_attr_get(svc_id, RTE_SERVICE_ATTR_CALL_COUNT, &calls);
	rte_service_attr_get(svc_id, RTE_SERVICE_ATTR_IDLE_CALL_COUNT, &idle);
	rte_service_attr_get(svc_id, RTE_SERVICE_ATTR_CYCLES, &cycles);
	rte_service_lcore_attr_get(svc_lcore, RTE_SERVICE_LCORE_ATTR_LOOPS, &loops);
	printf("service: %" PRIu64 " calls, %" PRIu64 " idle (-EAGAIN), %" PRIu64
	       " busy; %" PRIu64 " cycles in busy calls (%.0f per report)\n",
	       calls, idle, calls - idle, cycles,
	       calls - idle ? (double)cycles / (calls - idle) : 0.0);
	printf("service lcore %u ran its loop %" PRIu64 " times\n", svc_lcore, loops);
	rte_service_dump(stdout, svc_id);

	rte_service_map_lcore_set(svc_id, svc_lcore, 0);
	rte_service_component_runstate_set(svc_id, 0);
	printf("unregister: %d\n", rte_service_component_unregister(svc_id));

	rte_timer_subsystem_finalize();
	app_ports_close();
	rte_eal_cleanup();
	return 0;
}
