/* Event crypto adapter, OP_NEW mode, all-software: crypto_openssl + event_sw.
 * App enqueues crypto ops straight to the cryptodev; the adapter service dequeues
 * completed ops and injects them as RTE_EVENT_TYPE_CRYPTODEV events (response_info
 * comes from per-session event metadata). Services run on service lcore 1.
 * Run: ./event_crypto_adapter_new -l 0-1 --no-huge -m 256 --no-pci --file-prefix=ch08ca \
 *        --vdev=event_sw0 --vdev=crypto_openssl0 */
#include <stdio.h>
#include <inttypes.h>
#include <string.h>
#include <rte_eal.h>
#include <rte_mbuf.h>
#include <rte_cryptodev.h>
#include <rte_eventdev.h>
#include <rte_event_crypto_adapter.h>
#include <rte_service.h>

#define NOPS 32
#define IV_OFF (sizeof(struct rte_crypto_op) + sizeof(struct rte_crypto_sym_op))
static uint8_t key[16] = "0123456789abcdef";

static void svc(uint32_t sid) { rte_service_map_lcore_set(sid, 1, 1); rte_service_runstate_set(sid, 1); }

int main(int argc, char **argv)
{
	if (rte_eal_init(argc, argv) < 0) rte_exit(1, "eal\n");
	if (rte_service_lcore_add(1)) rte_exit(1, "need -l 0-1\n");
	uint8_t evdev = 0, cdev = rte_cryptodev_get_dev_id("crypto_openssl0");

	/* --- eventdev: 1 atomic queue, port 0 for the app --- */
	struct rte_event_dev_info ei; rte_event_dev_info_get(evdev, &ei);
	struct rte_event_dev_config ec = { .nb_event_queues = 1, .nb_event_ports = 1, .nb_events_limit = 1024,
		.nb_event_queue_flows = 4096, .nb_event_port_dequeue_depth = 16, .nb_event_port_enqueue_depth = 16,
		.dequeue_timeout_ns = ei.min_dequeue_timeout_ns };
	if (rte_event_dev_configure(evdev, &ec)) rte_exit(1, "ev cfg\n");
	struct rte_event_queue_conf qc; rte_event_queue_default_conf_get(evdev, 0, &qc);
	rte_event_queue_setup(evdev, 0, &qc);
	struct rte_event_port_conf pc; rte_event_port_default_conf_get(evdev, 0, &pc);
	rte_event_port_setup(evdev, 0, &pc);
	uint8_t q = 0; rte_event_port_link(evdev, 0, &q, NULL, 1);

	/* --- cryptodev --- */
	struct rte_cryptodev_config cc = { .socket_id = rte_socket_id(), .nb_queue_pairs = 1 };
	rte_cryptodev_configure(cdev, &cc);
	struct rte_mempool *smp = rte_cryptodev_sym_session_pool_create("sess", 8,
		rte_cryptodev_sym_get_private_session_size(cdev), 0,
		sizeof(union rte_event_crypto_metadata) /* user data: SW adapter keeps response_info here! */,
		rte_socket_id());
	struct rte_cryptodev_qp_conf qp = { .nb_descriptors = 128, .mp_session = smp };
	rte_cryptodev_queue_pair_setup(cdev, 0, &qp, rte_socket_id());

	/* --- adapter: caps tell us whether HW has an internal port (here: no -> SW service) --- */
	uint32_t caps; rte_event_crypto_adapter_caps_get(evdev, cdev, &caps);
	printf("crypto adapter caps=0x%x -> %s\n", caps,
	       (caps & RTE_EVENT_CRYPTO_ADAPTER_CAP_INTERNAL_PORT_OP_NEW) ? "HW internal port" : "SW service");
	if (rte_event_crypto_adapter_create(0, evdev, &pc, RTE_EVENT_CRYPTO_ADAPTER_OP_NEW))
		rte_exit(1, "adapter create\n");
	if (rte_event_crypto_adapter_queue_pair_add(0, cdev, -1, NULL)) rte_exit(1, "qp add\n");
	uint32_t sid;
	if (!rte_event_crypto_adapter_service_id_get(0, &sid)) svc(sid);
	if (!rte_event_dev_service_id_get(evdev, &sid)) svc(sid);
	if (rte_cryptodev_start(cdev) || rte_event_dev_start(evdev) || rte_event_crypto_adapter_start(0))
		rte_exit(1, "start\n");
	rte_service_lcore_start(1); /* only once everything the services poll is started */

	/* session + where completions should go (response_info) */
	struct rte_crypto_sym_xform x = { .type = RTE_CRYPTO_SYM_XFORM_CIPHER, .cipher = {
		.op = RTE_CRYPTO_CIPHER_OP_ENCRYPT, .algo = RTE_CRYPTO_CIPHER_AES_CTR,
		.key = { key, 16 }, .iv = { IV_OFF, 16 } } };
	void *sess = rte_cryptodev_sym_session_create(cdev, &x, smp);
	union rte_event_crypto_metadata md = { .response_info = { .queue_id = 0,
		.sched_type = RTE_SCHED_TYPE_ATOMIC, .flow_id = 7 } };
	if (rte_cryptodev_session_event_mdata_set(cdev, sess, RTE_CRYPTO_OP_TYPE_SYMMETRIC,
						 RTE_CRYPTO_OP_WITH_SESSION, &md, sizeof(md)))
		rte_exit(1, "mdata\n");

	struct rte_mempool *mb = rte_pktmbuf_pool_create("mb", 128, 0, 0, 2048, rte_socket_id());
	struct rte_mempool *opmp = rte_crypto_op_pool_create("ops", RTE_CRYPTO_OP_TYPE_SYMMETRIC, 128, 0, 16, rte_socket_id());
	struct rte_crypto_op *ops[NOPS];
	rte_crypto_op_bulk_alloc(opmp, RTE_CRYPTO_OP_TYPE_SYMMETRIC, ops, NOPS);
	for (int i = 0; i < NOPS; i++) {
		struct rte_mbuf *m = rte_pktmbuf_alloc(mb);
		snprintf(rte_pktmbuf_append(m, 64), 64, "message number %d", i);
		memset(rte_crypto_op_ctod_offset(ops[i], uint8_t *, IV_OFF), i, 16);
		rte_crypto_op_attach_sym_session(ops[i], sess);
		ops[i]->sym->m_src = m; ops[i]->sym->cipher.data.length = 64;
	}
	uint16_t enq = rte_cryptodev_enqueue_burst(cdev, 0, ops, NOPS); /* OP_NEW: app -> cryptodev directly */
	printf("app enqueued %u ops to cryptodev qp0\n", enq);

	int got = 0, ok = 0; uint64_t t0 = rte_get_timer_cycles();
	while (got < enq && rte_get_timer_cycles() - t0 < rte_get_timer_hz()) {
		struct rte_event ev[16];
		uint16_t n = rte_event_dequeue_burst(evdev, 0, ev, 16, 0);
		for (int i = 0; i < n; i++) {
			struct rte_crypto_op *op = ev[i].event_ptr;
			if (got == 0) printf("first event: type=%u (CRYPTODEV=%u) flow=%u queue=%u\n",
					     ev[i].event_type, RTE_EVENT_TYPE_CRYPTODEV, ev[i].flow_id, ev[i].queue_id);
			ok += op->status == RTE_CRYPTO_OP_STATUS_SUCCESS;
			rte_pktmbuf_free(op->sym->m_src); rte_crypto_op_free(op);
			got++;
		}
	}
	struct rte_event_crypto_adapter_stats st; rte_event_crypto_adapter_stats_get(0, &st);
	printf("received %d completion events, %d SUCCESS; adapter: deq_from_cdev=%" PRIu64 " ev_enq=%" PRIu64 "\n",
	       got, ok, st.crypto_deq_count, st.event_enq_count);
	/* teardown order matters: stop the services first, then adapter, then devices */
	rte_service_lcore_stop(1);
	rte_event_crypto_adapter_stop(0);
	rte_event_crypto_adapter_queue_pair_del(0, cdev, -1);
	rte_event_crypto_adapter_free(0);
	rte_event_dev_stop(evdev); rte_cryptodev_stop(cdev);
	rte_cryptodev_sym_session_free(cdev, sess);
	rte_eal_cleanup();
	return 0;
}
