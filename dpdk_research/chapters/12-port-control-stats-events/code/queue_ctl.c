/* SPDX-License-Identifier: BSD-3-Clause
 * queue_ctl.c - per-queue control: deferred start, queue start/stop,
 * queue validity, runtime queue setup and the dev_capa bits.
 *
 * Part A, on every port (tap, pcap, null, ring, failsafe):
 *   configure 2 RX queues, queue 1 with rx_deferred_start = 1, start the
 *   port, and print the queue states the ethdev layer records
 *   (read from this process's telemetry: /ethdev/info,N -> rxq_state,
 *   because rte_eth_rx_queue_info_get() is -ENOTSUP on these PMDs).
 *   Then try queue start/stop, queue_is_valid and a queue setup on the
 *   started port, and print every dev_capa bit by name.
 * Part B, on the tap port with traffic from the kernel side:
 *   per-queue xstats while queue 1 is stopped and restarted. Shows that
 *   on net_tap a stopped queue is bookkeeping only: the PMD still hands
 *   out packets if you poll it, and the kernel keeps queueing frames for
 *   it, which arrive late after the restart.
 *
 * Run: ./queue_ctl -l 0 --no-pci --no-huge -m 128 --file-prefix=ch12-qc \
 *        --vdev=net_tap0,iface=ch12tap2 \
 *        --vdev=net_pcap0,rx_pcap=in.pcap,rx_pcap=in.pcap,tx_pcap=/dev/null \
 *        --vdev=net_null0 --vdev=net_ring0 \
 *        --vdev='net_failsafe0,dev(net_tap1,iface=ch12tap4)'
 */
#include <inttypes.h>
#include <rte_cycles.h>
#include "ch12_common.h"

#define TAPIF "ch12tap2"

static struct rte_mempool *mp;

static void
print_capa(uint64_t capa)
{
	unsigned bit;
	int any = 0;

	printf("    dev_capa 0x%" PRIx64 ":", capa);
	for (bit = 0; bit < 64; bit++)
		if (capa & RTE_BIT64(bit)) {
			printf(" %s", rte_eth_dev_capability_name(RTE_BIT64(bit)));
			any = 1;
		}
	printf("%s\n", any ? "" : " (none)");
}

static void
part_a(uint16_t port)
{
	struct rte_eth_dev_info di;
	struct rte_eth_rxconf rxc;
	char name[RTE_ETH_NAME_MAX_LEN];
	uint16_t q, ntxq;
	int rc;

	if (rte_eth_dev_info_get(port, &di) != 0)
		return;
	rte_eth_dev_get_name_by_port(port, name, sizeof(name));
	printf("\nport %u %s (%s), max_rx_queues %u\n", port, name,
	       di.driver_name, di.max_rx_queues);
	print_capa(di.dev_capa);

	/* tap wants as many TX as RX queues; pcap has one TX queue here */
	ntxq = RTE_MIN(2, di.max_tx_queues);
	rc = rte_eth_dev_configure(port, 2, ntxq, &(struct rte_eth_conf){0});
	if (rc < 0) {
		printf("    configure(2 rxq) -> %s, skipping\n", rcname(rc));
		return;
	}
	rxc = di.default_rxconf;
	rte_eth_rx_queue_setup(port, 0, 256, 0, &rxc, mp);
	rxc.rx_deferred_start = 1;		/* queue 1: do not start with the port */
	rc = rte_eth_rx_queue_setup(port, 1, 256, 0, &rxc, mp);
	printf("    rx_queue_setup(q1, rx_deferred_start=1) -> %s\n", rcname(rc));
	for (q = 0; q < ntxq; q++)
		rte_eth_tx_queue_setup(port, q, 256, 0, NULL);
	rc = rte_eth_dev_start(port);
	printf("    dev_start -> %-8s rxq_state %s  (q1 was set rx_deferred_start=1)\n",
	       rcname(rc), rxq_states(port));

	printf("    rx_queue_is_valid(q1) -> %s, (q7) -> %s\n",
	       rcname(rte_eth_rx_queue_is_valid(port, 1)),
	       rcname(rte_eth_rx_queue_is_valid(port, 7)));
	rc = rte_eth_dev_rx_queue_stop(port, 1);
	printf("    rx_queue_stop(q1)  -> %-8s rxq_state %s\n", rcname(rc),
	       rxq_states(port));
	rc = rte_eth_rx_queue_setup(port, 1, 512, 0, NULL, mp);
	printf("    rx_queue_setup(q1, port started, q1 %s) -> %s\n",
	       strcmp(rxq_states(port), "[1,0]") == 0 ? "stopped" : "not stopped",
	       rcname(rc));
	rc = rte_eth_dev_rx_queue_start(port, 1);
	printf("    rx_queue_start(q1) -> %-8s rxq_state %s\n", rcname(rc),
	       rxq_states(port));
	rc = rte_eth_dev_tx_queue_stop(port, 0);
	printf("    tx_queue_stop(q0)  -> %-8s", rcname(rc));
	rc = rte_eth_dev_tx_queue_start(port, 0);
	printf(" tx_queue_start(q0) -> %s\n", rcname(rc));
	rte_eth_dev_stop(port);
	rc = rte_eth_dev_rx_queue_start(port, 1);
	printf("    port stopped: rx_queue_start(q1) -> %s\n", rcname(rc));
}

/* poll queue q for ms milliseconds, free everything, return the count */
static unsigned
poll_q(uint16_t port, uint16_t q, unsigned ms)
{
	struct rte_mbuf *b[32];
	uint64_t end = rte_get_timer_cycles() + rte_get_timer_hz() * ms / 1000;
	unsigned n = 0;

	do {
		uint16_t k = rte_eth_rx_burst(port, q, b, 32);

		n += k;
		rte_pktmbuf_free_bulk(b, k);
	} while (rte_get_timer_cycles() < end);
	return n;
}

static void
show(uint16_t port, const char *what)
{
	printf("  %-46s rx_q0_packets=%-4" PRIu64 " rx_q1_packets=%-4" PRIu64
	       " ipackets(total)=%" PRIu64 "\n", what,
	       xstat(port, "rx_q0_packets"), xstat(port, "rx_q1_packets"),
	       xstat(port, "rx_good_packets"));
}

static void
part_b(uint16_t port)
{
	struct rte_ether_addr me;
	unsigned n;

	printf("\n=== Part B: tap port %u, 2 RX queues, traffic from the kernel ===\n",
	       port);
	ch12_port_init(port, 2, 2, mp, NULL, NULL, 1);
	rte_eth_macaddr_get(port, &me);
	rte_eth_stats_reset(port);
	poll_q(port, 0, 10);
	poll_q(port, 1, 10);

	kernel_inject(TAPIF, &me, 200, 16);
	poll_q(port, 0, 30);
	poll_q(port, 1, 30);
	show(port, "200 frames, 16 flows, both queues polled:");

	/* The right way to take q1 out of service: stop POLLING it first,
	 * then tell the PMD. Here we only tell the PMD. */
	rte_eth_dev_rx_queue_stop(port, 1);
	kernel_inject(TAPIF, &me, 200, 16);
	poll_q(port, 0, 30);
	show(port, "q1 stopped, 200 more, only q0 polled:");
	printf("    rxq_state %s; frames for q1 wait in the kernel tap queue\n",
	       rxq_states(port));

	n = poll_q(port, 1, 30);
	show(port, "poll the STOPPED q1 anyway:");
	printf("    -> rx_burst on a stopped tap queue returned %u packets: the state\n"
	       "       is bookkeeping; the app must not poll a stopped queue\n", n);

	kernel_inject(TAPIF, &me, 200, 16);
	poll_q(port, 0, 30);
	rte_eth_dev_rx_queue_start(port, 1);
	n = poll_q(port, 1, 30);
	show(port, "q1 restarted after another 200 frames:");
	printf("    -> q1 delivered %u stale frames that queued while it was stopped\n", n);
	rte_eth_dev_stop(port);
}

int
main(int argc, char **argv)
{
	uint16_t port, tap = RTE_MAX_ETHPORTS;

	setvbuf(stdout, NULL, _IOLBF, 0);
	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	mp = rte_pktmbuf_pool_create("qc_pool", 8191, 64, 0,
				     RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
	if (!mp)
		rte_exit(EXIT_FAILURE, "pool\n");
	if_quiet(TAPIF);

	printf("=== Part A: deferred start, queue start/stop, runtime setup ===\n");
	printf("(rxq_state: 0 = STOPPED, 1 = STARTED, read via telemetry /ethdev/info)\n");
	RTE_ETH_FOREACH_DEV(port) {
		char name[RTE_ETH_NAME_MAX_LEN];

		part_a(port);
		rte_eth_dev_get_name_by_port(port, name, sizeof(name));
		if (strcmp(name, "net_tap0") == 0)
			tap = port;
	}
	if (tap != RTE_MAX_ETHPORTS)
		part_b(tap);

	RTE_ETH_FOREACH_DEV(port)
		rte_eth_dev_close(port);
	rte_mempool_free(mp);
	rte_eal_cleanup();
	return 0;
}
