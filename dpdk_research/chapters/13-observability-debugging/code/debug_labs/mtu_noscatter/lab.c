/* SPDX-License-Identifier: BSD-3-Clause
 * Chapter 13 debug lab 2: mtu_noscatter - "big packets arrive broken".
 *
 * Story: the network now carries 9000-byte jumbo frames. Our port was left
 * at the default MTU (1500), the mbuf pool has the default 2 KB data room
 * (RTE_MBUF_DEFAULT_BUF_SIZE) and the SCATTER RX offload is off, so one
 * frame must fit in ONE 2 KB mbuf. Here the peer is the kernel side of a
 * tap interface whose MTU we raise to 9000 (that is "the wire").
 * What the driver does with a frame that does not fit is driver specific:
 * net_tap drops it and counts it in ierrors (seen below); other drivers
 * truncate it or count it as rx_length_errors in xstats.
 *
 * Build with -DFIXED: check dev_info, enable RTE_ETH_RX_OFFLOAD_SCATTER and
 * set the MTU to 9000 (rxmode.mtu at configure time). Then each frame
 * arrives complete as a chain of 5 mbufs.
 * Note: with rxmode.mtu = 9000 but WITHOUT scatter, net_tap only warns
 * ("MTU 9000 requires 5 scatter segments, but offload not set") and
 * scatters anyway; a real NIC may refuse the queue or drop the frames.
 *
 *   ./lab -l 0 --no-pci --no-huge -m 128 --file-prefix=ch13-dbg-mtu \
 *       --vdev=net_tap0,iface=ch13tap2
 */
#include "../../ch13_common.h"

#define TAPIF "ch13tap2"

int
main(int argc, char **argv)
{
	struct rte_eth_conf conf = {0};
	struct rte_eth_dev_info di;
	struct rte_eth_stats st;
	struct rte_ether_addr me;
	struct rte_mempool *mp;
	struct rte_mbuf *pkts[32];
	unsigned int got = 0, segs = 0, bytes = 0;
	uint16_t mtu = 0;
	int ret, sent;

	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	mp = rte_pktmbuf_pool_create("lab_pool", 2047, 32, 0,
				     RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
	if (mp == NULL || rte_eth_dev_info_get(0, &di) != 0)
		rte_exit(EXIT_FAILURE, "init failed\n");
	printf("dev_info: max_rx_pktlen=%u max_mtu=%u, SCATTER %s, mbuf data room %u\n",
	       di.max_rx_pktlen, di.max_mtu,
	       (di.rx_offload_capa & RTE_ETH_RX_OFFLOAD_SCATTER) ?
			"supported" : "not supported",
	       rte_pktmbuf_data_room_size(mp) - RTE_PKTMBUF_HEADROOM);
#ifdef FIXED
	conf.rxmode.mtu = 9000;
	if (di.rx_offload_capa & RTE_ETH_RX_OFFLOAD_SCATTER)
		conf.rxmode.offloads |= RTE_ETH_RX_OFFLOAD_SCATTER;
#endif
	ret = ch13_port_init(0, mp, &conf, 256);
	rte_eth_dev_get_mtu(0, &mtu);
	printf("port init: mtu=%u offloads=0x%" PRIx64 " -> %d\n", mtu,
	       conf.rxmode.offloads, ret);
	if (ret < 0)
		rte_exit(EXIT_FAILURE, "port init failed\n");

	/* "the wire" carries jumbo frames: raise the kernel side's MTU */
	if (system("ip link set dev " TAPIF " mtu 9000") != 0)
		printf("could not raise the kernel MTU\n");
	rte_eth_macaddr_get(0, &me);
	sent = kernel_inject(TAPIF, &me, 10, 9000 + 14);
	{
		uint64_t end = rte_rdtsc() + rte_get_tsc_hz() / 2;

		while (rte_rdtsc() < end) {
			uint16_t i, n = rte_eth_rx_burst(0, 0, pkts, 32);

			for (i = 0; i < n; i++) {
				segs += pkts[i]->nb_segs;
				bytes += pkts[i]->pkt_len;
			}
			got += n;
			rte_pktmbuf_free_bulk(pkts, n);
		}
	}
	rte_eth_stats_get(0, &st);
	printf("kernel sent %d frames of 9014 bytes; app received %u frames, "
	       "%u bytes (%u per frame), %.1f mbufs per frame; ierrors=%" PRIu64 "\n",
	       sent, got, bytes, got ? bytes / got : 0,
	       got ? (double)segs / got : 0.0, st.ierrors);
	printf("%s\n", got == 10 && bytes == 10 * 9014 ? "PASS: frames complete"
						      : "FAIL: frames lost or truncated");
	fflush(stdout);
	sleep(2);                       /* time for a telemetry query */
	rte_eth_dev_stop(0);
	rte_eth_dev_close(0);
	rte_eal_cleanup();
	return 0;
}
