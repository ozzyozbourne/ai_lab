/* SPDX-License-Identifier: BSD-3-Clause
 *
 * my_skeleton.c - Chapter 8: a from-scratch, heavily commented version of
 * examples/skeleton/basicfwd.c. It forwards every packet received on port 0
 * out of port 1 and every packet received on port 1 out of port 0
 * (in general port p <-> port p^1), prints statistics once per second, and
 * exits cleanly on SIGINT/SIGTERM: stop and close every port, check that every
 * mbuf went back to the pool, clean up the EAL.
 *
 * Application options (after "--"):
 *   --burst N      Rx burst size (default 32, max 256)
 *   --tx-buffer    send through rte_eth_tx_buffer() (one packet at a time,
 *                  flushed when 32 are buffered or after 100 us) instead of
 *                  passing the whole Rx burst to rte_eth_tx_burst()
 *
 * Run here:
 *   timeout -s INT -k 5 8 stdbuf -oL ./my_skeleton -l 1 --no-pci --no-huge \
 *       -m 128 --file-prefix=ch08-skel --vdev=net_null0 --vdev=net_null1
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <inttypes.h>
#include <getopt.h>

#include <rte_eal.h>
#include <rte_errno.h>
#include <rte_ethdev.h>
#include <rte_cycles.h>
#include <rte_lcore.h>
#include <rte_mbuf.h>
#include <rte_malloc.h>

#define NB_RXD        1024    /* Rx descriptors per queue (we ask; PMD may adjust) */
#define NB_TXD        1024    /* Tx descriptors per queue */
#define CACHE_SIZE    250     /* per-lcore mempool cache (ch6) */
#define MAX_BURST     256
#define TXBUF_SIZE    32      /* packets held by rte_eth_tx_buffer before a flush */
#define DRAIN_US      100     /* ...or after this many microseconds */

static volatile int force_quit;   /* set by the signal handler */
static uint16_t burst = 32;
static int use_txbuf;

/* Per-port application counters (what *we* did, as opposed to rte_eth_stats,
 * which is what the PMD saw). */
struct app_stats {
	uint64_t rx, tx, dropped, tx_calls;
};
static struct app_stats st[RTE_MAX_ETHPORTS];
static struct rte_eth_dev_tx_buffer *txb[RTE_MAX_ETHPORTS];

static void
on_signal(int sig)
{
	/* timeout(1) signals the child and its process group, so the same
	 * SIGINT can arrive twice: report only the first. */
	if (!force_quit)
		printf("\nSignal %d received, stopping...\n", sig);
	force_quit = 1;
}

/* Error callback for the Tx buffer: called with the packets a flush could
 * not send. We must free them - the buffer gives them back to us. */
static void
txbuf_unsent(struct rte_mbuf **unsent, uint16_t count, void *userdata)
{
	uint64_t *dropped = userdata;
	*dropped += count;
	rte_pktmbuf_free_bulk(unsent, count);
}

/* ------------------------------------------------------------------------
 * port_init: the whole lifecycle up to "started", checking every return.
 * ---------------------------------------------------------------------- */
static int
port_init(uint16_t port, struct rte_mempool *mp)
{
	struct rte_eth_conf conf;
	struct rte_eth_dev_info info;
	struct rte_eth_txconf txconf;
	uint16_t nb_rxd = NB_RXD, nb_txd = NB_TXD;
	int ret;

	if (!rte_eth_dev_is_valid_port(port))
		return -EINVAL;

	ret = rte_eth_dev_info_get(port, &info);
	if (ret != 0)
		return ret;

	/* An all-zero rte_eth_conf means: no RSS, no offloads, default MTU. */
	memset(&conf, 0, sizeof(conf));
	/* MBUF_FAST_FREE: we promise all mbufs come from one pool and have
	 * refcnt 1, so the PMD may free them in bulk. Only ask if supported. */
	if (info.tx_offload_capa & RTE_ETH_TX_OFFLOAD_MBUF_FAST_FREE)
		conf.txmode.offloads |= RTE_ETH_TX_OFFLOAD_MBUF_FAST_FREE;

	/* 1 Rx queue and 1 Tx queue. */
	ret = rte_eth_dev_configure(port, 1, 1, &conf);
	if (ret != 0)
		return ret;

	/* Clamp the ring sizes to what the PMD supports. */
	ret = rte_eth_dev_adjust_nb_rx_tx_desc(port, &nb_rxd, &nb_txd);
	if (ret != 0)
		return ret;

	/* Rx queue 0: the PMD fills its descriptors with mbufs from mp. Put the
	 * queue memory on the NIC's NUMA node (SOCKET_ID_ANY if unknown). */
	ret = rte_eth_rx_queue_setup(port, 0, nb_rxd, rte_eth_dev_socket_id(port),
				     NULL, mp);
	if (ret < 0)
		return ret;

	/* Tx queue 0: start from the PMD's defaults, add our port offloads. */
	txconf = info.default_txconf;
	txconf.offloads = conf.txmode.offloads;
	ret = rte_eth_tx_queue_setup(port, 0, nb_txd, rte_eth_dev_socket_id(port),
				     &txconf);
	if (ret < 0)
		return ret;

	if (use_txbuf) {
		/* A Tx buffer for this port (it is the *destination* buffer). */
		txb[port] = rte_zmalloc_socket("txbuf", RTE_ETH_TX_BUFFER_SIZE(TXBUF_SIZE),
					       0, rte_eth_dev_socket_id(port));
		if (txb[port] == NULL)
			return -ENOMEM;
		rte_eth_tx_buffer_init(txb[port], TXBUF_SIZE);
		rte_eth_tx_buffer_set_err_callback(txb[port], txbuf_unsent,
						   &st[port].dropped);
	}

	/* Start: from here on rte_eth_fp_ops[port] points at the PMD. */
	ret = rte_eth_dev_start(port);
	if (ret < 0)
		return ret;

	struct rte_ether_addr mac;
	ret = rte_eth_macaddr_get(port, &mac);
	if (ret != 0)
		return ret;
	printf("Port %u (%s): MAC " RTE_ETHER_ADDR_PRT_FMT ", %u rxd, %u txd\n",
	       port, info.driver_name, RTE_ETHER_ADDR_BYTES(&mac), nb_rxd, nb_txd);

	/* Accept every frame, not only those for our MAC. Some PMDs (net_null)
	 * are always promiscuous and return -ENOTSUP for *disable*; enable is
	 * fine everywhere here. */
	return rte_eth_promiscuous_enable(port);
}

/* ------------------------------------------------------------------------
 * Print one line per port per second: app counters and PMD counters.
 * ---------------------------------------------------------------------- */
static void
print_stats(double secs)
{
	static struct app_stats last[RTE_MAX_ETHPORTS];
	uint16_t port;

	RTE_ETH_FOREACH_DEV(port) {
		struct rte_eth_stats es;
		struct app_stats *s = &st[port], *l = &last[port];
		uint64_t calls = s->tx_calls - l->tx_calls;
		uint64_t tx = s->tx - l->tx;

		if (rte_eth_stats_get(port, &es) != 0)
			memset(&es, 0, sizeof(es));
		printf("[%5.1fs] port %u: rx %8.2f Mpps  tx %8.2f Mpps  drop %" PRIu64
		       "  pkts/tx_burst %5.1f | PMD ipackets=%" PRIu64 " opackets=%" PRIu64
		       " rx_nombuf=%" PRIu64 "\n",
		       secs, port, (s->rx - l->rx) / 1e6, tx / 1e6, s->dropped,
		       calls ? (double)tx / calls : 0.0, es.ipackets, es.opackets,
		       es.rx_nombuf);
		*l = *s;
	}
}

/* ------------------------------------------------------------------------
 * The forwarding loop: poll every port, forward to its pair. Never blocks;
 * this lcore shows 100% CPU in top even with no traffic - by design.
 * ---------------------------------------------------------------------- */
static void
lcore_main(void)
{
	struct rte_mbuf *bufs[MAX_BURST];
	const uint64_t hz = rte_get_tsc_hz();
	const uint64_t drain = hz * DRAIN_US / 1000000;
	uint64_t start = rte_get_tsc_cycles(), next_print = start + hz, last_drain = start;
	uint16_t port;

	printf("\nlcore %u forwarding (burst %u, %s). Ctrl+C to quit.\n",
	       rte_lcore_id(), burst, use_txbuf ? "tx buffer" : "direct tx_burst");

	while (!force_quit) {
		RTE_ETH_FOREACH_DEV(port) {
			uint16_t dst = port ^ 1;      /* 0<->1, 2<->3, ... */

			/* rx_burst returns 0..burst mbufs that are now OURS. */
			uint16_t nb_rx = rte_eth_rx_burst(port, 0, bufs, burst);
			if (unlikely(nb_rx == 0))
				continue;
			st[port].rx += nb_rx;

			if (!use_txbuf) {
				/* tx_burst may accept fewer than asked. It now
				 * owns bufs[0..nb_tx-1]; we still own the rest. */
				uint16_t nb_tx = rte_eth_tx_burst(dst, 0, bufs, nb_rx);
				st[dst].tx += nb_tx;
				st[dst].tx_calls++;
				if (unlikely(nb_tx < nb_rx)) {
					st[dst].dropped += nb_rx - nb_tx;
					rte_pktmbuf_free_bulk(&bufs[nb_tx], nb_rx - nb_tx);
				}
			} else {
				/* One packet at a time into the buffer; a flush
				 * (= one tx_burst) happens when it is full. The
				 * return value is how many that flush sent. */
				for (uint16_t i = 0; i < nb_rx; i++) {
					uint16_t sent = rte_eth_tx_buffer(dst, 0, txb[dst], bufs[i]);
					if (sent) {
						st[dst].tx += sent;
						st[dst].tx_calls++;
					}
				}
			}
		}

		uint64_t now = rte_get_tsc_cycles();
		/* Drain timer: never leave packets in a half-full buffer for long. */
		if (use_txbuf && now - last_drain > drain) {
			RTE_ETH_FOREACH_DEV(port) {
				uint16_t sent = rte_eth_tx_buffer_flush(port, 0, txb[port]);
				if (sent) {
					st[port].tx += sent;
					st[port].tx_calls++;
				}
			}
			last_drain = now;
		}
		if (now >= next_print) {
			print_stats((double)(now - start) / hz);
			next_print += hz;
		}
	}
}

static void
parse_app_args(int argc, char **argv)
{
	static const struct option opts[] = {
		{ "burst", required_argument, NULL, 'b' },
		{ "tx-buffer", no_argument, NULL, 't' },
		{ NULL, 0, NULL, 0 }
	};
	int c;
	while ((c = getopt_long(argc, argv, "", opts, NULL)) != -1) {
		if (c == 'b') {
			int b = atoi(optarg);
			if (b < 1 || b > MAX_BURST)
				rte_exit(EXIT_FAILURE, "--burst must be 1..%d\n", MAX_BURST);
			burst = (uint16_t)b;
		} else if (c == 't') {
			use_txbuf = 1;
		} else {
			rte_exit(EXIT_FAILURE, "usage: [--burst N] [--tx-buffer]\n");
		}
	}
}

int
main(int argc, char **argv)
{
	uint16_t port, nb_ports;
	int ret;

	ret = rte_eal_init(argc, argv);
	if (ret < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed: %s\n", rte_strerror(rte_errno));
	parse_app_args(argc - ret, argv + ret);

	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);

	/* We forward p <-> p^1, so we need an even, non-zero number of ports. */
	nb_ports = rte_eth_dev_count_avail();
	if (nb_ports < 2 || (nb_ports & 1))
		rte_exit(EXIT_FAILURE, "need an even number of ports (>= 2), found %u\n",
			 nb_ports);

	/* Pool sizing: every descriptor can hold an mbuf, plus each lcore's
	 * cache and one burst in flight. Rounded up to 2^n - 1 for the ring. */
	unsigned need = nb_ports * (NB_RXD + NB_TXD) +
			rte_lcore_count() * (CACHE_SIZE + MAX_BURST) +
			(use_txbuf ? nb_ports * TXBUF_SIZE : 0);
	unsigned nb_mbufs = rte_align32pow2(need + 1) - 1;
	printf("mbuf pool: need %u -> creating %u mbufs (%u ports)\n",
	       need, nb_mbufs, nb_ports);
	struct rte_mempool *mp = rte_pktmbuf_pool_create("ch08_skel", nb_mbufs,
			CACHE_SIZE, 0, RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
	if (mp == NULL)
		rte_exit(EXIT_FAILURE, "cannot create mbuf pool: %s\n",
			 rte_strerror(rte_errno));

	RTE_ETH_FOREACH_DEV(port) {
		ret = port_init(port, mp);
		if (ret != 0)
			rte_exit(EXIT_FAILURE, "port %u init failed: %s\n",
				 port, rte_strerror(-ret));
	}

	if (rte_lcore_count() > 1)
		printf("note: only the main lcore forwards; other lcores idle.\n");

	lcore_main();

	/* Graceful shutdown: flush buffers, stop (fast path -> dummies), close.
	 * Stopping a port makes the PMD give back the mbufs held by its rings. */
	uint16_t ids[RTE_MAX_ETHPORTS], cnt = 0;
	RTE_ETH_FOREACH_DEV(port)
		ids[cnt++] = port;
	for (uint16_t i = 0; i < cnt; i++) {
		port = ids[i];
		if (use_txbuf) {
			rte_eth_tx_buffer_flush(port, 0, txb[port]);
			rte_free(txb[port]);
		}
		printf("port %u: app rx=%" PRIu64 " tx=%" PRIu64 " dropped=%" PRIu64
		       " tx_burst calls=%" PRIu64 "\n", port, st[port].rx, st[port].tx,
		       st[port].dropped, st[port].tx_calls);
		ret = rte_eth_dev_stop(port);
		if (ret != 0)
			printf("rte_eth_dev_stop(%u): %s\n", port, rte_strerror(-ret));
		rte_eth_dev_close(port);
	}
	printf("mbufs back in pool: %u of %u%s\n", rte_mempool_avail_count(mp),
	       nb_mbufs, rte_mempool_avail_count(mp) == nb_mbufs ? " (no leak)" : " (LEAK!)");
	rte_mempool_free(mp);
	rte_eal_cleanup();
	return 0;
}
