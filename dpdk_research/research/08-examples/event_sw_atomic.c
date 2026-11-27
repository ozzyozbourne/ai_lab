/* event_sw demo: 1 producer (main lcore, also runs the sw scheduler service),
 * N workers on other lcores. Queue 0 schedule type chosen by argv after "--":
 *   atomic | ordered | parallel
 * Prints a flow x worker matrix: with ATOMIC each flow sticks to one worker at a time.
 * Run: ./event_sw_atomic -l 0-2 --no-huge -m 256 --no-pci --file-prefix=ch08e --vdev=event_sw0 -- atomic */
#include <stdio.h>
#include <inttypes.h>
#include <string.h>
#include <rte_eal.h>
#include <rte_lcore.h>
#include <rte_eventdev.h>
#include <rte_service.h>
#include <rte_cycles.h>
#include <rte_random.h>

#define NB_FLOWS 8
#define NB_EVENTS 20000
#define MAXW 4
static uint8_t dev;
static uint8_t sched = RTE_SCHED_TYPE_ATOMIC;
static volatile int done;
static uint64_t matrix[NB_FLOWS][MAXW];
static uint64_t collisions; /* two workers inside the same flow at once */
static volatile uint8_t in_flow[NB_FLOWS];
static uint64_t sink_reordered, sink_count;

static int worker(void *arg)
{
	uint8_t port = (uintptr_t)arg; /* port 1..N */
	struct rte_event ev[16];
	while (!done) {
		uint16_t n = rte_event_dequeue_burst(dev, port, ev, 16, 0);
		for (int i = 0; i < n; i++) {
			uint32_t f = ev[i].flow_id % NB_FLOWS;
			if (__atomic_exchange_n(&in_flow[f], 1, __ATOMIC_ACQUIRE)) __atomic_fetch_add(&collisions, 1, __ATOMIC_RELAXED);
			matrix[f][port - 1]++;
			rte_delay_us(rte_rand() % 4); /* pretend to work, variable cost */
			__atomic_store_n(&in_flow[f], 0, __ATOMIC_RELEASE);
			/* stage 2: forward to queue 1 (atomic), consumed by the sink port */
			ev[i].op = RTE_EVENT_OP_FORWARD; ev[i].queue_id = 1;
			ev[i].sched_type = RTE_SCHED_TYPE_ATOMIC;
		}
		uint16_t s = 0;
		while (s < n && !done) s += rte_event_enqueue_burst(dev, port, ev + s, n - s);
	}
	return 0;
}

static uint32_t sink_last[NB_FLOWS];
static void drain(uint8_t sink)
{
	struct rte_event ev[32];
	uint16_t n = rte_event_dequeue_burst(dev, sink, ev, 32, 0);
	for (int i = 0; i < n; i++) {
		uint32_t f = ev[i].flow_id % NB_FLOWS, seq = (uint32_t)ev[i].u64;
		if (sink_count && seq < sink_last[f]) sink_reordered++;
		if (seq > sink_last[f]) sink_last[f] = seq;
		sink_count++;
		ev[i].op = RTE_EVENT_OP_RELEASE;
	}
	if (n) rte_event_enqueue_burst(dev, sink, ev, n);
}

int main(int argc, char **argv)
{
	int r = rte_eal_init(argc, argv);
	if (r < 0) rte_exit(1, "eal\n");
	argc -= r; argv += r;
	if (argc > 1 && !strcmp(argv[1], "ordered")) sched = RTE_SCHED_TYPE_ORDERED;
	if (argc > 1 && !strcmp(argv[1], "parallel")) sched = RTE_SCHED_TYPE_PARALLEL;
	int nw = rte_lcore_count() - 1;
	if (nw < 1 || nw > MAXW) rte_exit(1, "need 2..5 lcores\n");

	struct rte_event_dev_info info; rte_event_dev_info_get(dev, &info);
	printf("eventdev %s: max_queues=%u max_ports=%u max_events=%d caps=0x%x\n", info.driver_name,
	       info.max_event_queues, info.max_event_ports, info.max_num_events, info.event_dev_cap);
	struct rte_event_dev_config cfg = {
		.nb_event_queues = 2, .nb_event_ports = nw + 2,
		.nb_events_limit = 4096, .nb_event_queue_flows = 1024,
		.nb_event_port_dequeue_depth = 16, .nb_event_port_enqueue_depth = 16,
		.dequeue_timeout_ns = info.min_dequeue_timeout_ns };
	if (rte_event_dev_configure(dev, &cfg)) rte_exit(1, "configure\n");
	struct rte_event_queue_conf qc = { .schedule_type = sched, .priority = RTE_EVENT_DEV_PRIORITY_NORMAL,
		.nb_atomic_flows = 1024, .nb_atomic_order_sequences = 1024 };
	if (rte_event_queue_setup(dev, 0, &qc)) rte_exit(1, "queue\n");
	qc.schedule_type = RTE_SCHED_TYPE_ATOMIC;
	if (rte_event_queue_setup(dev, 1, &qc)) rte_exit(1, "queue1\n");
	struct rte_event_port_conf pc; rte_event_port_default_conf_get(dev, 0, &pc);
	for (int p = 0; p <= nw + 1; p++) if (rte_event_port_setup(dev, p, &pc)) rte_exit(1, "port\n");
	uint8_t q = 0;
	for (int p = 1; p <= nw; p++) rte_event_port_link(dev, p, &q, NULL, 1); /* port 0 = producer only */
	uint8_t q1 = 1; uint8_t sink = nw + 1; rte_event_port_link(dev, sink, &q1, NULL, 1);

	uint32_t sid; rte_event_dev_service_id_get(dev, &sid);
	rte_service_runstate_set(sid, 1);
	rte_service_set_runstate_mapped_check(sid, 0); /* we run it by hand on main lcore */
	if (rte_event_dev_start(dev)) rte_exit(1, "start\n");

	unsigned lc; uintptr_t port = 1;
	RTE_LCORE_FOREACH_WORKER(lc) rte_eal_remote_launch(worker, (void *)port++, lc);

	uint64_t t0 = rte_rdtsc();
	for (uint32_t i = 0; i < NB_EVENTS; ) {
		struct rte_event ev = { .op = RTE_EVENT_OP_NEW, .queue_id = 0, .sched_type = sched,
			.flow_id = i % NB_FLOWS, .event_type = RTE_EVENT_TYPE_CPU, .u64 = i };
		if (rte_event_enqueue_burst(dev, 0, &ev, 1) == 1) i++;
		rte_service_run_iter_on_app_lcore(sid, 0); /* drive the SW scheduler */
		drain(sink);
	}
	for (int k = 0; k < 200000 && sink_count < NB_EVENTS; k++) { rte_service_run_iter_on_app_lcore(sid, 0); drain(sink); }
	done = 1; rte_eal_mp_wait_lcore();
	printf("sched=%s workers=%d time=%.1f ms\n", argc > 1 ? argv[1] : "atomic", nw,
	       (rte_rdtsc() - t0) * 1000.0 / rte_get_tsc_hz());
	printf("flow  "); for (int w = 0; w < nw; w++) printf("  worker%d", w); printf("\n");
	for (int f = 0; f < NB_FLOWS; f++) {
		printf("f%-4d", f); for (int w = 0; w < nw; w++) printf(" %8" PRIu64, matrix[f][w]); printf("\n");
	}
	printf("same-flow concurrent processing (collisions): %" PRIu64 "\n", collisions);
	printf("sink received %" PRIu64 " events, %" PRIu64 " arrived out of per-flow order\n", sink_count, sink_reordered);
	rte_event_dev_dump(dev, stdout);
	rte_event_dev_stop(dev); rte_event_dev_close(dev);
	rte_eal_cleanup();
	return 0;
}
