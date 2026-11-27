/* eal_tour.c - exercises many EAL APIs on vdev-only setup */
#include <stdio.h>
#include <inttypes.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <unistd.h>
#include <rte_eal.h>
#include <rte_lcore.h>
#include <rte_launch.h>
#include <rte_lcore_var.h>
#include <rte_log.h>
#include <rte_cycles.h>
#include <rte_alarm.h>
#include <rte_service.h>
#include <rte_service_component.h>
#include <rte_dev.h>
#include <rte_bus.h>
#include <rte_errno.h>
#include <rte_atomic.h>
#include <rte_memory.h>

RTE_LOG_REGISTER(tour_logtype, user.tour, INFO);
#define RTE_LOGTYPE_TOUR tour_logtype
#define TOUR_LOG(l, ...) RTE_LOG_LINE(l, TOUR, __VA_ARGS__)

struct counter { uint64_t n; };
static RTE_LCORE_VAR_HANDLE(struct counter, counters);
RTE_LCORE_VAR_INIT(counters);

static volatile int alarm_fired;
static void alarm_cb(void *arg) { (void)arg; alarm_fired = 1; }

static int worker(void *arg)
{
	uint64_t end = rte_get_tsc_cycles() + rte_get_tsc_hz() / 10; /* 100 ms */
	struct counter *c = RTE_LCORE_VAR(counters);
	(void)arg;
	while (rte_get_tsc_cycles() < end)
		c->n++;
	TOUR_LOG(INFO, "lcore %u (cpu %d, socket %u) did %" PRIu64 " loops",
		 rte_lcore_id(), rte_lcore_to_cpu_id(rte_lcore_id()), rte_socket_id(), c->n);
	return (int)rte_lcore_id() * 10;
}

static uint64_t svc_calls;
static int32_t my_service(void *arg) { (void)arg; svc_calls++; return 0; }

static void *non_eal(void *arg)
{
	(void)arg;
	printf("non-EAL thread before register: lcore_id=%d\n", (int)rte_lcore_id());
	if (rte_thread_register() == 0)
		printf("non-EAL thread after register: lcore_id=%u role=%d\n",
		       rte_lcore_id(), rte_eal_lcore_role(rte_lcore_id()));
	rte_thread_unregister();
	return NULL;
}

int main(int argc, char **argv)
{
	int ret = rte_eal_init(argc, argv);
	unsigned int id;
	if (ret < 0) { fprintf(stderr, "init failed: %s\n", rte_strerror(rte_errno)); return 1; }
	argc -= ret; argv += ret; /* app args follow "--" */

	printf("process type=%s iova=%s main lcore=%u count=%u hugepages=%d\n",
	       rte_eal_process_type() == RTE_PROC_PRIMARY ? "primary" : "secondary",
	       rte_eal_iova_mode() == RTE_IOVA_VA ? "VA" : "PA",
	       rte_get_main_lcore(), rte_lcore_count(), rte_eal_has_hugepages());
	printf("TSC hz=%" PRIu64 " runtime dir=%s\n", rte_get_tsc_hz(), rte_eal_get_runtime_dir());

	/* 1. launch on every worker, collect return codes */
	RTE_LCORE_FOREACH_WORKER(id)
		rte_eal_remote_launch(worker, NULL, id);
	RTE_LCORE_FOREACH_WORKER(id)
		printf("lcore %u returned %d\n", id, rte_eal_wait_lcore(id));

	/* 2. lcore variables: main reads every lcore's value (rare non-owner access) */
	struct counter *c;
	RTE_LCORE_VAR_FOREACH(id, c, counters)
		if (c->n) printf("lcore_var[%u].n = %" PRIu64 "\n", id, c->n);

	/* 3. register a non-EAL thread */
	pthread_t t; pthread_create(&t, NULL, non_eal, NULL); pthread_join(t, NULL);

	/* 4. alarm (runs in EAL interrupt thread) */
	rte_eal_alarm_set(50 * 1000, alarm_cb, NULL);
	rte_delay_ms(100);
	printf("alarm fired=%d\n", alarm_fired);

	/* 5. a service run on the app lcore (no service core needed) */
	struct rte_service_spec spec = { .callback = my_service, .socket_id = SOCKET_ID_ANY };
	uint32_t sid;
	snprintf(spec.name, sizeof(spec.name), "tour_svc");
	rte_service_component_register(&spec, &sid);
	rte_service_component_runstate_set(sid, 1);
	rte_service_runstate_set(sid, 1);
	for (int i = 0; i < 1000; i++)
		rte_service_run_iter_on_app_lcore(sid, 1);
	printf("service '%s' id=%u ran %" PRIu64 " times on app lcore\n", spec.name, sid, svc_calls);

	/* 6. hotplug a vdev and list devices on the vdev bus */
	ret = rte_dev_probe("net_null7");
	printf("rte_dev_probe(net_null7) = %d\n", ret);
	struct rte_dev_iterator it; struct rte_device *dev;
	RTE_DEV_FOREACH(dev, "bus=vdev", &it)
		printf("vdev bus device: %s\n", rte_dev_name(dev));

	rte_lcore_dump(stdout);
	rte_service_component_unregister(sid);
	ret = rte_eal_cleanup();
	printf("cleanup=%d\n", ret);
	return 0;
}
