/* Event timer adapter on event_sw: timers expire as events.
 * Both the sw eventdev scheduler and the sw timer adapter are *services*; we map
 * them to service lcore 1.
 * Run: ./event_timer_demo -l 0-1 --no-huge -m 256 --no-pci --file-prefix=ch08t --vdev=event_sw0 */
#include <stdio.h>
#include <inttypes.h>
#include <rte_eal.h>
#include <rte_lcore.h>
#include <rte_cycles.h>
#include <rte_mempool.h>
#include <rte_eventdev.h>
#include <rte_event_timer_adapter.h>
#include <rte_service.h>

#define NT 6
static void run_service_on(uint32_t sid, unsigned lcore)
{
	rte_service_map_lcore_set(sid, lcore, 1);
	rte_service_runstate_set(sid, 1);
}

int main(int argc, char **argv)
{
	if (rte_eal_init(argc, argv) < 0) rte_exit(1, "eal\n");
	unsigned slcore = 1;
	if (rte_service_lcore_add(slcore)) rte_exit(1, "need lcore 1 for services (-l 0-1)\n");
	uint8_t dev = 0;
	struct rte_event_dev_info info; rte_event_dev_info_get(dev, &info);
	struct rte_event_dev_config cfg = { .nb_event_queues = 1, .nb_event_ports = 1, .nb_events_limit = 1024,
		.nb_event_queue_flows = 4096, .nb_event_port_dequeue_depth = 16, .nb_event_port_enqueue_depth = 16,
		.dequeue_timeout_ns = info.min_dequeue_timeout_ns };
	/* the sw timer adapter will create its own producer port when it needs one */
	/* NOTE: do not reserve a port for it yourself: the default conf callback
	 * stops + reconfigures the device adding a port (nb_event_ports + 1). */
	if (rte_event_dev_configure(dev, &cfg)) rte_exit(1, "cfg\n");
	struct rte_event_queue_conf qc; rte_event_queue_default_conf_get(dev, 0, &qc);
	qc.schedule_type = RTE_SCHED_TYPE_ATOMIC;
	if (rte_event_queue_setup(dev, 0, &qc)) rte_exit(1, "queue (default conf must fit dev config)\n");
	struct rte_event_port_conf pc; rte_event_port_default_conf_get(dev, 0, &pc);
	if (rte_event_port_setup(dev, 0, &pc)) rte_exit(1, "port\n");
	uint8_t q = 0; rte_event_port_link(dev, 0, &q, NULL, 1);

	uint32_t caps; rte_event_timer_adapter_caps_get(dev, &caps);
	printf("timer adapter caps=0x%x (%s%s)\n", caps,
	       (caps & RTE_EVENT_TIMER_ADAPTER_CAP_INTERNAL_PORT) ? "HW internal port" : "SW service-based",
	       (caps & RTE_EVENT_TIMER_ADAPTER_CAP_PERIODIC) ? ", periodic" : "");
	struct rte_event_timer_adapter_conf tc = { .event_dev_id = dev, .timer_adapter_id = 0,
		.socket_id = rte_socket_id(), .clk_src = RTE_EVENT_TIMER_ADAPTER_CPU_CLK,
		.timer_tick_ns = 10 * 1000 * 1000 /* 10 ms */, .max_tmo_ns = 1000ULL * 1000 * 1000,
		.nb_timers = 64, .flags = RTE_EVENT_TIMER_ADAPTER_F_ADJUST_RES };
	struct rte_event_timer_adapter *ta = rte_event_timer_adapter_create(&tc);
	if (!ta) rte_exit(1, "timer adapter create\n");
	uint32_t sid;
	if (rte_event_timer_adapter_service_id_get(ta, &sid) == 0) run_service_on(sid, slcore);
	if (rte_event_dev_service_id_get(dev, &sid) == 0) run_service_on(sid, slcore);
	if (rte_event_dev_start(dev)) rte_exit(1, "start\n");
	if (rte_event_timer_adapter_start(ta)) rte_exit(1, "ta start\n");
	rte_service_lcore_start(slcore);

	struct rte_mempool *tp = rte_mempool_create("tim", 64, sizeof(struct rte_event_timer), 0, 0,
						    NULL, NULL, NULL, NULL, rte_socket_id(), 0);
	struct rte_event_timer *t[NT];
	rte_mempool_get_bulk(tp, (void **)t, NT);
	uint64_t hz = rte_get_timer_hz(), t0 = rte_get_timer_cycles();
	for (int i = 0; i < NT; i++) {
		*t[i] = (struct rte_event_timer){ .ev = { .op = RTE_EVENT_OP_NEW, .queue_id = 0,
			.sched_type = RTE_SCHED_TYPE_ATOMIC, .event_type = RTE_EVENT_TYPE_TIMER, .event_ptr = t[i] },
			.state = RTE_EVENT_TIMER_NOT_ARMED, .timeout_ticks = (NT - i) * 5 /* 300ms, 250ms ... 50ms */ };
	}
	int armed = rte_event_timer_arm_burst(ta, t, NT);
	printf("armed %d timers (ticks 30,25,...,5 x 10ms tick); state[0]=%d\n", armed, t[0]->state);
	/* cancel one before it fires */
	struct rte_event_timer *c = t[0];
	uint16_t nc = rte_event_timer_cancel_burst(ta, &c, 1);
	printf("cancel timer0: %u, state=%d (2=CANCELED)\n", nc, t[0]->state);

	int got = 0;
	while (got < NT - 1 && rte_get_timer_cycles() - t0 < 2 * hz) {
		struct rte_event ev;
		if (rte_event_dequeue_burst(dev, 0, &ev, 1, 0)) {
			struct rte_event_timer *et = ev.event_ptr;
			printf("  expiry event: timer ticks=%2" PRIu64 " fired at %6.1f ms (type=%u)\n", et->timeout_ticks,
			       (rte_get_timer_cycles() - t0) * 1000.0 / hz, ev.event_type);
			got++;
		}
	}
	struct rte_event_timer_adapter_stats st; rte_event_timer_adapter_stats_get(ta, &st);
	printf("adapter stats: expired=%" PRIu64 " ev_enq=%" PRIu64 " tick_count=%" PRIu64 "\n",
	       st.evtim_exp_count, st.ev_enq_count, st.adapter_tick_count);
	rte_service_lcore_stop(slcore); /* stop services before tearing down what they poll */
	rte_event_timer_adapter_stop(ta); rte_event_timer_adapter_free(ta);
	rte_event_dev_stop(dev); rte_event_dev_close(dev);
	rte_eal_cleanup();
	return 0;
}
