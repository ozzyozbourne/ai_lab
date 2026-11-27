/* SPDX-License-Identifier: BSD-3-Clause
 *
 * solutions/skeleton_pairs.c - Chapter 8, exercise 1 (easy).
 *
 * my_skeleton (and examples/skeleton) pair port p with port p^1. That only
 * works while port ids are contiguous: 0,1,2,3... As soon as a port id is
 * missing (a port was closed, detached, or is owned by bonding/failsafe and
 * hidden from RTE_ETH_FOREACH_DEV) p^1 can name a port that does not exist,
 * or the wrong one.
 *
 * This version builds an explicit peer table from the ports that are really
 * available, in RTE_ETH_FOREACH_DEV order: 1st<->2nd, 3rd<->4th, ...
 * Option "--exclude N" closes port N before pairing to create a gap, which is
 * exactly the case where p^1 goes wrong.
 *
 * Run (see run.sh):
 *   ./skeleton_pairs -l 1 --no-pci --no-huge -m 128 --file-prefix=ch08-pairs \
 *       --vdev=net_null0 ... --vdev=net_null4 -- --exclude 2
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <inttypes.h>

#include <rte_eal.h>
#include <rte_errno.h>
#include <rte_ethdev.h>
#include <rte_cycles.h>
#include <rte_mbuf.h>

#define NB_DESC 512
#define BURST   32

static volatile int quit;
static uint16_t peer[RTE_MAX_ETHPORTS];
static uint64_t rx_cnt[RTE_MAX_ETHPORTS], tx_cnt[RTE_MAX_ETHPORTS];

static void on_signal(int s) { (void)s; quit = 1; }

static int
port_init(uint16_t port, struct rte_mempool *mp)
{
	struct rte_eth_conf conf;
	memset(&conf, 0, sizeof(conf));
	int ret = rte_eth_dev_configure(port, 1, 1, &conf);
	if (ret == 0)
		ret = rte_eth_rx_queue_setup(port, 0, NB_DESC, rte_eth_dev_socket_id(port), NULL, mp);
	if (ret == 0)
		ret = rte_eth_tx_queue_setup(port, 0, NB_DESC, rte_eth_dev_socket_id(port), NULL);
	if (ret == 0)
		ret = rte_eth_dev_start(port);
	if (ret == 0)
		ret = rte_eth_promiscuous_enable(port);
	return ret;
}

int
main(int argc, char **argv)
{
	int ret = rte_eal_init(argc, argv);
	if (ret < 0)
		rte_exit(EXIT_FAILURE, "EAL init: %s\n", rte_strerror(rte_errno));
	for (int i = ret + 1; i + 1 < argc; i++)
		if (strcmp(argv[i], "--exclude") == 0) {
			uint16_t x = (uint16_t)atoi(argv[i + 1]);
			printf("closing port %u to leave a gap in the port ids\n", x);
			rte_eth_dev_close(x);
		}
	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);

	/* Build the pairing from the ports that really exist. */
	uint16_t ids[RTE_MAX_ETHPORTS], n = 0, p;
	RTE_ETH_FOREACH_DEV(p)
		ids[n++] = p;
	if (n < 2 || (n & 1))
		rte_exit(EXIT_FAILURE, "need an even number of ports, found %u\n", n);
	for (uint16_t i = 0; i < n; i += 2) {
		peer[ids[i]] = ids[i + 1];
		peer[ids[i + 1]] = ids[i];
		printf("pair: port %u <-> port %u   (p^1 would have given %u <-> %u)\n",
		       ids[i], ids[i + 1], ids[i], ids[i] ^ 1);
	}

	struct rte_mempool *mp = rte_pktmbuf_pool_create("ch08_pairs",
			rte_align32pow2(n * 2 * NB_DESC + 512) - 1, 250, 0,
			RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
	if (mp == NULL)
		rte_exit(EXIT_FAILURE, "pool: %s\n", rte_strerror(rte_errno));
	for (uint16_t i = 0; i < n; i++)
		if ((ret = port_init(ids[i], mp)) != 0)
			rte_exit(EXIT_FAILURE, "port %u: %s\n", ids[i], rte_strerror(-ret));

	struct rte_mbuf *bufs[BURST];
	uint64_t end = rte_get_tsc_cycles() + rte_get_tsc_hz();   /* run 1 s */
	while (!quit && rte_get_tsc_cycles() < end) {
		for (uint16_t i = 0; i < n; i++) {
			uint16_t src = ids[i], dst = peer[src];
			uint16_t nb = rte_eth_rx_burst(src, 0, bufs, BURST);
			if (nb == 0)
				continue;
			uint16_t s = rte_eth_tx_burst(dst, 0, bufs, nb);
			rx_cnt[src] += nb;
			tx_cnt[dst] += s;
			if (s < nb)
				rte_pktmbuf_free_bulk(&bufs[s], nb - s);
		}
	}
	for (uint16_t i = 0; i < n; i++) {
		printf("port %u: rx %" PRIu64 "  tx %" PRIu64 "  (peer %u)\n",
		       ids[i], rx_cnt[ids[i]], tx_cnt[ids[i]], peer[ids[i]]);
		rte_eth_dev_stop(ids[i]);
		rte_eth_dev_close(ids[i]);
	}
	printf("pool avail after close: %u of %u\n", rte_mempool_avail_count(mp), mp->size);
	rte_mempool_free(mp);
	rte_eal_cleanup();
	return 0;
}
