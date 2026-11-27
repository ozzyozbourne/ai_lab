/* SPDX-License-Identifier: BSD-3-Clause
 * Chapter 11, exercise 1 solution: step 1, but the timers are driven by a
 * service on a service lcore instead of the forwarding loop.
 *
 * Changes against evolve/step1_timer.c:
 *   - the stats timer is armed with tim_lcore = the service lcore
 *   - a service "ch11_timers" calls rte_timer_manage() on that lcore
 *   - the forwarding loop on lcore 0 contains NOTHING but forwarding
 *
 *   ./ex1_timer_service -l 0,2 -S 2 --no-pci --no-huge -m 128 --file-prefix=ch11-ex1 \
 *       --vdev=net_ring0 --vdev=net_ring1
 */
#include "app_common.h"

#include <errno.h>
#include <rte_timer.h>
#include <rte_service.h>
#include <rte_service_component.h>

static struct rte_timer stats_tim;
static unsigned int ticks;

static void
stats_cb(struct rte_timer *tim, void *arg)
{
	char tag[24], where[64];

	(void)tim;
	(void)arg;
	snprintf(tag, sizeof(tag), "t=%us", ++ticks);
	app_print_delta(tag, 1.0);
	if (ticks == 1)
		printf("      (stats_cb runs in %s)\n", app_where(where, sizeof(where)));
	if (ticks == 3)
		force_quit = true;
}

/* The whole "timer service": run the timers of THIS lcore. */
static int32_t
timer_service(void *arg)
{
	(void)arg;
	if (rte_timer_next_ticks() > 0)
		return -EAGAIN;
	rte_timer_manage();
	return 0;
}

int
main(int argc, char **argv)
{
	struct rte_service_spec spec = { .name = "ch11_timers", .callback = timer_service };
	uint32_t ids[RTE_MAX_LCORE], id, svc_lcore;
	uint64_t calls, idle;
	struct rte_mempool *pool;

	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	if (rte_service_lcore_list(ids, RTE_DIM(ids)) < 1)
		rte_exit(EXIT_FAILURE, "run with -l 0,2 -S 2\n");
	svc_lcore = ids[0];
	pool = app_ports_init();
	printf("injected %u frames\n", app_inject(pool, 64));

	rte_timer_subsystem_init();
	rte_timer_init(&stats_tim);
	rte_timer_reset(&stats_tim, rte_get_timer_hz(), PERIODICAL, svc_lcore, stats_cb, NULL);

	spec.socket_id = rte_socket_id();
	rte_service_component_register(&spec, &id);
	rte_service_component_runstate_set(id, 1);
	rte_service_set_stats_enable(id, 1);
	rte_service_map_lcore_set(id, svc_lcore, 1);
	rte_service_runstate_set(id, 1);

	while (!force_quit)
		app_forward_once(32);         /* no timer code in the data path */

	rte_service_runstate_set(id, 0);
	rte_service_lcore_stop(svc_lcore);
	rte_eal_wait_lcore(svc_lcore);
	rte_service_attr_get(id, RTE_SERVICE_ATTR_CALL_COUNT, &calls);
	rte_service_attr_get(id, RTE_SERVICE_ATTR_IDLE_CALL_COUNT, &idle);
	printf("timer service: %" PRIu64 " calls, %" PRIu64 " ran rte_timer_manage()\n",
	       calls, calls - idle);
	rte_service_map_lcore_set(id, svc_lcore, 0);
	rte_service_component_runstate_set(id, 0);
	rte_service_component_unregister(id);
	rte_timer_stop(&stats_tim);
	rte_timer_subsystem_finalize();
	app_ports_close();
	rte_eal_cleanup();
	return 0;
}
