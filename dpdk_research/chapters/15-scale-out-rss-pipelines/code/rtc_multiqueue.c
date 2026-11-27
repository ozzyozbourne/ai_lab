/* SPDX-License-Identifier: BSD-3-Clause
 *
 * rtc_multiqueue.c - Chapter 15: run-to-completion, one queue per lcore.
 *
 * Every worker lcore owns RX queue i and TX queue i of port 0 and does the
 * whole job for each packet it receives (parse, work, transmit). Nothing is
 * shared on the fast path: no rings, no locks, no shared counters. The NIC
 * (here: the kernel's PACKET_FANOUT hash) decides which queue, and therefore
 * which lcore, sees each flow.
 *
 * Usage (app options after --):
 *   --seconds S   run time (default 3)
 *   --work C      synthetic work per packet in TSC cycles (default 0)
 *   --null        load mode for net_null: print Mpps instead of flow checks
 *
 * Real steering (veth ch15va created by run.sh, flows.py sends into ch15vb):
 *   ./rtc_multiqueue -l 0-2 --no-pci --no-huge -m 256 --file-prefix=ch15-rtc \
 *     --vdev=net_af_packet0,iface=ch15va,qpairs=2,fanout_mode=hash -- --seconds 4
 * Load number (net_null makes packets on whichever queue is polled):
 *   ./rtc_multiqueue -l 0-2 --no-pci --no-huge -m 256 --file-prefix=ch15-rtcn \
 *     --vdev=net_null0,size=64 -- --null --seconds 2 --work 200
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <getopt.h>
#include <inttypes.h>
#include <signal.h>

#include <rte_eal.h>
#include <rte_ethdev.h>
#include <rte_lcore.h>
#include <rte_launch.h>
#include <rte_cycles.h>
#include <rte_mbuf.h>
#include <rte_errno.h>
#include <rte_stdatomic.h>

#include "ch15_common.h"

#define BURST     32
#define MAX_FLOWS 1024
#define MAX_Q     8

/* One cache-line aligned stats block per lcore: no false sharing (ch14). */
struct __rte_cache_aligned lcore_stats {
	uint16_t queue;
	uint64_t rx, tx, dropped, ours, out_of_order;
	uint64_t busy_cycles;
	uint32_t last_seq[MAX_FLOWS];
	uint8_t seen[MAX_FLOWS];
};

static struct lcore_stats stats[RTE_MAX_LCORE];
/* stop flag: written by main, read by workers (relaxed is enough: ch14) */
static RTE_ATOMIC(int) stop;
static uint64_t work_cycles;
static int null_mode;
static unsigned int seconds = 3;

static int
worker(void *arg)
{
	const uint16_t port = 0;
	struct lcore_stats *st = &stats[rte_lcore_id()];
	const uint16_t q = st->queue;
	struct rte_mbuf *pkts[BURST];

	(void)arg;
	while (!rte_atomic_load_explicit(&stop, rte_memory_order_relaxed)) {
		uint16_t n = rte_eth_rx_burst(port, q, pkts, BURST), i, sent;
		uint64_t t0;

		if (n == 0)
			continue;
		t0 = rte_rdtsc();
		st->rx += n;
		for (i = 0; i < n; i++) {
			uint16_t flow;
			uint32_t seq;

			if (!null_mode && ch15_parse(pkts[i], &flow, &seq) == 0 &&
			    flow < MAX_FLOWS) {
				st->ours++;
				/* per-flow order check: a flow handled by one
				 * lcore keeps its order end to end */
				if (st->seen[flow] && seq != st->last_seq[flow] + 1)
					st->out_of_order++;
				st->seen[flow] = 1;
				st->last_seq[flow] = seq;
			}
			ch15_work(pkts[i], work_cycles);
		}
		/* same lcore transmits on its own TX queue: no TX lock needed */
		sent = rte_eth_tx_burst(port, q, pkts, n);
		st->tx += sent;
		if (sent < n) {
			st->dropped += n - sent;
			rte_pktmbuf_free_bulk(&pkts[sent], n - sent);
		}
		st->busy_cycles += rte_rdtsc() - t0;
	}
	return 0;
}

static void
parse_args(int argc, char **argv)
{
	static const struct option lo[] = {
		{ "seconds", required_argument, NULL, 's' },
		{ "work", required_argument, NULL, 'w' },
		{ "null", no_argument, NULL, 'n' },
		{ NULL, 0, NULL, 0 },
	};
	int c;

	while ((c = getopt_long(argc, argv, "", lo, NULL)) != -1) {
		switch (c) {
		case 's': seconds = atoi(optarg); break;
		case 'w': work_cycles = strtoull(optarg, NULL, 0); break;
		case 'n': null_mode = 1; break;
		default: rte_exit(EXIT_FAILURE, "bad option\n");
		}
	}
}

int
main(int argc, char **argv)
{
	struct rte_eth_conf conf;
	struct rte_eth_dev_info info;
	struct rte_mempool *mp;
	unsigned int lcore, nq = 0, f, cross = 0;
	uint64_t hz, total = 0;
	int ret;

	ret = rte_eal_init(argc, argv);
	if (ret < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	parse_args(argc - ret, argv + ret);

	if (rte_eth_dev_count_avail() < 1)
		rte_exit(EXIT_FAILURE, "need one port (--vdev=...)\n");
	nq = rte_lcore_count() - 1;	/* one queue per worker lcore */
	if (nq < 1 || nq > MAX_Q)
		rte_exit(EXIT_FAILURE, "use 2..%d lcores (-l)\n", MAX_Q + 1);

	mp = rte_pktmbuf_pool_create("ch15_rtc_pool", 8191, 256, 0,
				     RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
	if (mp == NULL)
		rte_exit(EXIT_FAILURE, "pool: %s\n", rte_strerror(rte_errno));

	if (rte_eth_dev_info_get(0, &info) != 0)
		rte_exit(EXIT_FAILURE, "dev_info failed\n");
	memset(&conf, 0, sizeof(conf));
	/* Ask for RSS only if the port can hash. af_packet reports
	 * flow_type_rss_offloads = 0 (the kernel spreads flows instead) and
	 * ethdev would refuse RSS with more than one queue. */
	if (info.flow_type_rss_offloads != 0 && nq > 1) {
		conf.rxmode.mq_mode = RTE_ETH_MQ_RX_RSS;
		conf.rx_adv_conf.rss_conf.rss_hf =
			(RTE_ETH_RSS_IP | RTE_ETH_RSS_UDP) & info.flow_type_rss_offloads;
	}
	printf("port 0 (%s): %u RX/TX queue pairs, mq_mode %s\n", info.driver_name, nq,
	       conf.rxmode.mq_mode == RTE_ETH_MQ_RX_RSS ? "RSS" : "NONE (device spreads)");
	if (rte_eth_dev_configure(0, nq, nq, &conf) != 0)
		rte_exit(EXIT_FAILURE, "configure failed\n");
	for (unsigned int q = 0; q < nq; q++) {
		if (rte_eth_rx_queue_setup(0, q, 512, rte_socket_id(), NULL, mp) != 0 ||
		    rte_eth_tx_queue_setup(0, q, 512, rte_socket_id(), NULL) != 0)
			rte_exit(EXIT_FAILURE, "queue %u setup failed\n", q);
	}
	if (rte_eth_dev_start(0) != 0)
		rte_exit(EXIT_FAILURE, "start failed\n");

	/* queue i <-> i-th worker lcore: the l3fwd --config idea */
	nq = 0;
	RTE_LCORE_FOREACH_WORKER(lcore) {
		stats[lcore].queue = nq++;
		rte_eal_remote_launch(worker, NULL, lcore);
	}
	printf("ready: %u workers polling for %u s\n", nq, seconds);
	fflush(stdout);
	rte_delay_ms(seconds * 1000);
	rte_atomic_store_explicit(&stop, 1, rte_memory_order_relaxed);
	rte_eal_mp_wait_lcore();

	hz = rte_get_tsc_hz();
	RTE_LCORE_FOREACH_WORKER(lcore) {
		struct lcore_stats *st = &stats[lcore];
		unsigned int flows = 0;

		for (f = 0; f < MAX_FLOWS; f++)
			flows += st->seen[f];
		total += st->rx;
		if (null_mode)
			printf("lcore %u queue %u: rx %" PRIu64 " (%.2f Mpps)  busy %.0f%%\n",
			       lcore, st->queue, st->rx, st->rx / (seconds * 1e6),
			       100.0 * st->busy_cycles / (seconds * hz));
		else
			printf("lcore %u queue %u: rx %" PRIu64 " (test frames %" PRIu64
			       ") tx %" PRIu64 " flows %u out-of-order %" PRIu64 "\n",
			       lcore, st->queue, st->rx, st->ours, st->tx, flows,
			       st->out_of_order);
	}
	if (null_mode) {
		printf("RESULT model=rtc work=%" PRIu64 " mpps=%.3f\n", work_cycles,
		       total / (seconds * 1e6));
	} else {
		/* did any flow show up on two lcores? (it must not) */
		for (f = 0; f < MAX_FLOWS; f++) {
			unsigned int on = 0;
			RTE_LCORE_FOREACH_WORKER(lcore)
				on += stats[lcore].seen[f];
			cross += on > 1;
		}
		printf("flows seen on more than one lcore: %u\n", cross);
	}
	rte_eth_dev_stop(0);
	rte_eth_dev_close(0);
	rte_eal_cleanup();
	return 0;
}
