/* compressdev demo: stateless DEFLATE compress then decompress on compress_zlib.
 * Run: ./comp_zlib_roundtrip --no-huge -m 256 --no-pci --file-prefix=ch08z --vdev=compress_zlib0 */
#include <stdio.h>
#include <inttypes.h>
#include <string.h>
#include <rte_eal.h>
#include <rte_mbuf.h>
#include <rte_compressdev.h>
#include <rte_comp.h>

static struct rte_comp_op *run(uint8_t dev, struct rte_mempool *opmp, void *xf,
			       struct rte_mbuf *src, struct rte_mbuf *dst, uint32_t len)
{
	struct rte_comp_op *op = rte_comp_op_alloc(opmp), *out = NULL;
	op->op_type = RTE_COMP_OP_STATELESS;
	op->private_xform = xf;
	op->m_src = src; op->m_dst = dst;
	op->src.offset = 0; op->src.length = len;
	op->dst.offset = 0;
	op->flush_flag = RTE_COMP_FLUSH_FINAL;
	rte_compressdev_enqueue_burst(dev, 0, &op, 1);
	while (rte_compressdev_dequeue_burst(dev, 0, &out, 1) == 0);
	return out;
}

int main(int argc, char **argv)
{
	if (rte_eal_init(argc, argv) < 0) rte_exit(1, "eal\n");
	int dev = rte_compressdev_get_dev_id("compress_zlib0");
	if (dev < 0) rte_exit(1, "no compress_zlib0\n");
	const struct rte_compressdev_capabilities *cap = rte_compressdev_capability_get(dev, RTE_COMP_ALGO_DEFLATE);
	printf("DEFLATE supported=%s, window sizes %u..%u, ff=0x%" PRIx64 "\n", cap ? "yes" : "no",
	       cap ? cap->window_size.min : 0, cap ? cap->window_size.max : 0, cap ? cap->comp_feature_flags : 0);
	struct rte_compressdev_config cfg = { .socket_id = rte_socket_id(), .nb_queue_pairs = 1,
					      .max_nb_priv_xforms = 2, .max_nb_streams = 0 };
	if (rte_compressdev_configure(dev, &cfg)) rte_exit(1, "configure\n");
	if (rte_compressdev_queue_pair_setup(dev, 0, 16, rte_socket_id())) rte_exit(1, "qp\n");
	if (rte_compressdev_start(dev)) rte_exit(1, "start\n");

	struct rte_comp_xform cx = { .type = RTE_COMP_COMPRESS, .compress = {
		.algo = RTE_COMP_ALGO_DEFLATE, .deflate.huffman = RTE_COMP_HUFFMAN_DYNAMIC,
		.level = RTE_COMP_LEVEL_PMD_DEFAULT, .window_size = 15, .chksum = RTE_COMP_CHECKSUM_NONE } };
	struct rte_comp_xform dx = { .type = RTE_COMP_DECOMPRESS, .decompress = {
		.algo = RTE_COMP_ALGO_DEFLATE, .window_size = 15, .chksum = RTE_COMP_CHECKSUM_NONE } };
	void *cxf, *dxf;
	if (rte_compressdev_private_xform_create(dev, &cx, &cxf) ||
	    rte_compressdev_private_xform_create(dev, &dx, &dxf)) rte_exit(1, "xform\n");

	struct rte_mempool *mb = rte_pktmbuf_pool_create("mb", 32, 0, 0, 8192, rte_socket_id());
	struct rte_mempool *opmp = rte_comp_op_pool_create("cops", 16, 0, 0, rte_socket_id());
	struct rte_mbuf *a = rte_pktmbuf_alloc(mb), *b = rte_pktmbuf_alloc(mb), *c = rte_pktmbuf_alloc(mb);
	uint32_t len = 4000; char *p = rte_pktmbuf_append(a, len);
	for (uint32_t i = 0; i < len; i++) p[i] = "DPDK accelerates packets. "[i % 26];
	rte_pktmbuf_append(b, 4096); rte_pktmbuf_append(c, 4096); /* dst space must be pre-sized */

	struct rte_comp_op *o = run(dev, opmp, cxf, a, b, len);
	printf("compress:   status=%u consumed=%u produced=%u ratio=%.1f%%\n", o->status, o->consumed, o->produced,
	       100.0 * o->produced / o->consumed);
	uint32_t clen = o->produced; rte_comp_op_free(o);
	o = run(dev, opmp, dxf, b, c, clen);
	printf("decompress: status=%u consumed=%u produced=%u match=%s\n", o->status, o->consumed, o->produced,
	       (o->produced == len && !memcmp(p, rte_pktmbuf_mtod(c, char *), len)) ? "yes" : "NO");
	rte_comp_op_free(o);
	rte_compressdev_private_xform_free(dev, cxf); rte_compressdev_private_xform_free(dev, dxf);
	rte_compressdev_stop(dev); rte_compressdev_close(dev); rte_eal_cleanup();
	return 0;
}
