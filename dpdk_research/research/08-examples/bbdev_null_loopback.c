/* bbdev lifecycle on baseband_null (a loopback: enqueued ops come straight back).
 * Shows: info/capabilities, setup_queues, queue_configure, op pools, enq/deq, stats.
 * Run: ./bbdev_null_loopback --no-huge -m 256 --no-pci --file-prefix=ch08bb --vdev=baseband_null0,max_nb_queues=2 */
#include <stdio.h>
#include <inttypes.h>
#include <rte_eal.h>
#include <rte_bbdev.h>
#include <rte_bbdev_op.h>

int main(int argc, char **argv)
{
	if (rte_eal_init(argc, argv) < 0) rte_exit(1, "eal\n");
	printf("bbdevs: %u\n", rte_bbdev_count());
	uint16_t dev = 0;
	struct rte_bbdev_info info; rte_bbdev_info_get(dev, &info);
	printf("dev %s driver=%s max_queues=%u\n", info.dev_name, info.drv.driver_name, info.drv.max_num_queues);
	for (const struct rte_bbdev_op_cap *c = info.drv.capabilities; c->type != RTE_BBDEV_OP_NONE; c++)
		printf("  capability: %s\n", rte_bbdev_op_type_str(c->type));
	printf("  (null driver advertises only RTE_BBDEV_OP_NONE: no LDPC/turbo/FFT, pure plumbing)\n");

	if (rte_bbdev_setup_queues(dev, 1, rte_socket_id())) rte_exit(1, "setup_queues\n");
	struct rte_bbdev_queue_conf qc = { .socket = rte_socket_id(), .queue_size = 64, .op_type = RTE_BBDEV_OP_NONE };
	if (rte_bbdev_queue_configure(dev, 0, &qc)) rte_exit(1, "queue_configure\n");
	if (rte_bbdev_start(dev)) rte_exit(1, "start\n");

	struct rte_mempool *mp;
	/* enc_op_alloc_bulk insists on a TURBO_ENC/LDPC_ENC pool type */
	mp = rte_bbdev_op_pool_create("bbops", RTE_BBDEV_OP_TURBO_ENC, 64, 0, rte_socket_id());
	struct rte_bbdev_enc_op *ops[16], *out[16];
	if (rte_bbdev_enc_op_alloc_bulk(mp, ops, 16)) rte_exit(1, "alloc\n");
	for (int i = 0; i < 16; i++) ops[i]->opaque_data = (void *)(uintptr_t)i;
	uint16_t e = rte_bbdev_enqueue_enc_ops(dev, 0, ops, 16);
	uint16_t d = rte_bbdev_dequeue_enc_ops(dev, 0, out, 16);
	printf("enqueued=%u dequeued=%u, first opaque=%" PRIuPTR " last=%" PRIuPTR "\n", e, d,
	       (uintptr_t)out[0]->opaque_data, (uintptr_t)out[d - 1]->opaque_data);
	struct rte_bbdev_stats st; rte_bbdev_stats_get(dev, &st);
	printf("stats enq=%" PRIu64 " deq=%" PRIu64 "\n", st.enqueued_count, st.dequeued_count);
	rte_bbdev_enc_op_free_bulk(out, d);
	rte_bbdev_stop(dev); rte_bbdev_close(dev); rte_eal_cleanup();
	return 0;
}
