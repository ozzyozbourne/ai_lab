/* SPDX-License-Identifier: BSD-3-Clause
 * Chapter 10, exercise 3 solution: mini_l2fwd_filter.c = mini_l2fwd.c plus a
 * destination-MAC filter: a frame is forwarded only if its dst MAC is the
 * broadcast address or the receiving port's own MAC; everything else is
 * counted in "filtered" and freed. The injector now sends 1/3 frames to
 * port 0's MAC, 1/3 to broadcast and 1/3 to a foreign unicast MAC.
 * (Diff against mini_l2fwd.c to see the change.)
 *
 * Original description:
 *
 * Two ports, port 0 <-> port 1. Every frame received on one port gets its
 * MAC addresses rewritten (dst = 02:00:00:00:00:<out port>, src = the out
 * port's MAC, exactly like l2fwd) and is queued in a per-port TX buffer
 * (rte_eth_tx_buffer). A buffer is sent when it holds MAX_PKT_BURST frames,
 * or when the TSC-based drain timer fires, whichever comes first.
 *
 * The ports are net_ring vdevs. A net_ring port created with --vdev=net_ringN
 * is a loopback: what you transmit on it comes back on its own RX queue. So
 * frames injected into port 0 bounce 0 -> 1 -> 0 -> ... forever, which is a
 * handy way to watch the TX buffer and the drain timer at work.
 *
 *   ./mini_l2fwd -l 0 --no-pci --no-huge -m 128 --file-prefix=ch10-mini \
 *       --vdev=net_ring0 --vdev=net_ring1 -- [--inject N] [--drain-us U] [--seconds S]
 *   --inject N    frames injected into port 0 at start (default 20)
 *   --drain-us U  drain period in microseconds, 0 = never (default 100)
 *   --seconds S   run time (default 2)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <signal.h>
#include <getopt.h>
#include <netinet/in.h>

#include <rte_eal.h>
#include <rte_cycles.h>
#include <rte_ethdev.h>
#include <rte_mbuf.h>
#include <rte_malloc.h>
#include <rte_ether.h>
#include <rte_ip4.h>
#include <rte_udp.h>

#include "ch10_port.h"

#define MAX_PKT_BURST 32
#define NB_PORTS 2

struct port_stats {
	uint64_t rx, tx, dropped;
	uint64_t flush_full;     /* rte_eth_tx_buffer() sent a full buffer */
	uint64_t flush_timer;    /* the drain timer sent a partial buffer */
	uint64_t filtered;       /* EXERCISE 3: dst MAC not for us */
};

static volatile bool force_quit;
static struct port_stats st[NB_PORTS];
static struct rte_eth_dev_tx_buffer *txb[NB_PORTS];
static struct rte_ether_addr port_mac[NB_PORTS];

static void
on_signal(int sig)
{
	(void)sig;
	force_quit = true;
}

/* l2fwd_mac_updating(), written with struct copies instead of a uint64 store */
static inline void
rewrite_macs(struct rte_mbuf *m, uint16_t out_port)
{
	struct rte_ether_hdr *eth = rte_pktmbuf_mtod(m, struct rte_ether_hdr *);
	struct rte_ether_addr dst = {{0x02, 0, 0, 0, 0, (uint8_t)out_port}};

	rte_ether_addr_copy(&dst, &eth->dst_addr);
	rte_ether_addr_copy(&port_mac[out_port], &eth->src_addr);
}

/* Inject n IPv4/UDP frames by transmitting them on port 0 (loops to RX 0). */
static unsigned int
inject(struct rte_mempool *pool, unsigned int n)
{
	unsigned int i, done = 0;

	for (i = 0; i < n; i++) {
		struct rte_mbuf *m = rte_pktmbuf_alloc(pool);
		struct rte_ether_hdr *eth;
		struct rte_ipv4_hdr *ip;
		struct rte_udp_hdr *udp;
		uint16_t len = sizeof(*eth) + sizeof(*ip) + sizeof(*udp) + 18;

		if (m == NULL)
			break;
		eth = (struct rte_ether_hdr *)rte_pktmbuf_append(m, len);
		memset(eth, 0, len);
		ip = (struct rte_ipv4_hdr *)(eth + 1);
		udp = (struct rte_udp_hdr *)(ip + 1);
		rte_eth_random_addr(eth->src_addr.addr_bytes); /* some sender */
		if (i % 3 == 0)
			eth->dst_addr = port_mac[0];          /* for us */
		else if (i % 3 == 1)
			memset(&eth->dst_addr, 0xff, 6);      /* broadcast */
		else
			rte_eth_random_addr(eth->dst_addr.addr_bytes); /* someone else */
		eth->ether_type = RTE_BE16(RTE_ETHER_TYPE_IPV4);
		ip->version_ihl = RTE_IPV4_VHL_DEF;
		ip->total_length = rte_cpu_to_be_16(len - sizeof(*eth));
		ip->time_to_live = 64;
		ip->next_proto_id = IPPROTO_UDP;
		ip->src_addr = RTE_BE32(RTE_IPV4(10, 10, 1, 1));
		ip->dst_addr = rte_cpu_to_be_32(RTE_IPV4(10, 10, 2, 1) + i);
		ip->hdr_checksum = rte_ipv4_cksum(ip);
		udp->src_port = rte_cpu_to_be_16(1000 + i);
		udp->dst_port = RTE_BE16(2000);
		udp->dgram_len = rte_cpu_to_be_16(sizeof(*udp) + 18);
		if (rte_eth_tx_burst(0, 0, &m, 1) == 1)
			done++;
		else
			rte_pktmbuf_free(m);
	}
	return done;
}

static void
print_stats(const char *tag)
{
	uint16_t p;

	for (p = 0; p < NB_PORTS; p++)
		printf("%-6s port %u: rx=%-9" PRIu64 " tx=%-9" PRIu64
		       " dropped=%-3" PRIu64 " full-flushes=%-8" PRIu64
		       " timer-flushes=%-8" PRIu64 " buffered=%u filtered=%" PRIu64 "\n",
		       tag, p, st[p].rx, st[p].tx, st[p].dropped,
		       st[p].flush_full, st[p].flush_timer, txb[p]->length,
		       st[p].filtered);
}

int
main(int argc, char **argv)
{
	static const struct option lopts[] = {
		{"inject", required_argument, NULL, 'i'},
		{"drain-us", required_argument, NULL, 'd'},
		{"seconds", required_argument, NULL, 's'},
		{NULL, 0, NULL, 0}
	};
	unsigned int n_inject = 20, drain_us = 100, seconds = 2, injected;
	struct rte_mempool *pool;
	struct rte_mbuf *pkts[MAX_PKT_BURST];
	uint64_t hz, drain_tsc, prev_tsc, next_print, deadline;
	uint16_t p;
	int ret, opt, tick = 0;

	ret = rte_eal_init(argc, argv);
	if (ret < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	argc -= ret;
	argv += ret;
	while ((opt = getopt_long(argc, argv, "", lopts, NULL)) != -1) {
		switch (opt) {
		case 'i': n_inject = atoi(optarg); break;
		case 'd': drain_us = atoi(optarg); break;
		case 's': seconds = atoi(optarg); break;
		default: rte_exit(EXIT_FAILURE, "bad option\n");
		}
	}
	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);

	if (rte_eth_dev_count_avail() != NB_PORTS)
		rte_exit(EXIT_FAILURE, "need exactly 2 ports (--vdev=net_ring0 --vdev=net_ring1)\n");
	pool = rte_pktmbuf_pool_create("ch10_filt", 4095, 64, 0,
				       RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
	if (pool == NULL)
		rte_exit(EXIT_FAILURE, "mbuf pool: %s\n", rte_strerror(rte_errno));

	for (p = 0; p < NB_PORTS; p++) {
		char mac[RTE_ETHER_ADDR_FMT_SIZE];

		if (ch10_port_init(p, pool) < 0)
			rte_exit(EXIT_FAILURE, "port %u init failed\n", p);
		rte_eth_macaddr_get(p, &port_mac[p]);
		if (rte_is_zero_ether_addr(&port_mac[p])) {
			/* net_ring has no MAC; pick a locally administered one */
			struct rte_ether_addr a = {{0x02, 0, 0, 0, 0x10, (uint8_t)p}};

			ret = rte_eth_dev_default_mac_addr_set(p, &a);
			printf("port %u has MAC 00:00:00:00:00:00; default_mac_addr_set -> %d (%s), "
			       "using 02:00:00:00:10:%02u in software\n", p, ret,
			       ret ? rte_strerror(-ret) : "ok", p);
			port_mac[p] = a;
		}
		rte_ether_format_addr(mac, sizeof(mac), &port_mac[p]);
		printf("port %u MAC %s\n", p, mac);

		/* A TX buffer is a small array of mbuf pointers + a callback. */
		txb[p] = rte_zmalloc_socket("txb", RTE_ETH_TX_BUFFER_SIZE(MAX_PKT_BURST),
					    0, rte_eth_dev_socket_id(p));
		if (txb[p] == NULL)
			rte_exit(EXIT_FAILURE, "tx buffer alloc failed\n");
		rte_eth_tx_buffer_init(txb[p], MAX_PKT_BURST);
		/* Unsent frames are freed and counted (default: freed only). */
		rte_eth_tx_buffer_set_err_callback(txb[p],
			rte_eth_tx_buffer_count_callback, &st[p].dropped);
	}

	hz = rte_get_tsc_hz();
	/* the same rounding l2fwd uses: ceil(hz / 1e6) * drain_us */
	drain_tsc = (hz + US_PER_S - 1) / US_PER_S * drain_us;
	printf("TSC %.2f GHz, drain period %u us = %" PRIu64 " cycles%s\n",
	       hz / 1e9, drain_us, drain_tsc, drain_us ? "" : " (drain timer OFF)");

	injected = inject(pool, n_inject);
	printf("injected %u frames into port 0\n", injected);

	prev_tsc = rte_rdtsc();
	next_print = prev_tsc + hz;
	deadline = prev_tsc + seconds * hz;

	while (!force_quit) {
		uint64_t cur = rte_rdtsc();

		/* 1. drain: a partially filled buffer must not wait forever */
		if (drain_tsc != 0 && cur - prev_tsc > drain_tsc) {
			for (p = 0; p < NB_PORTS; p++) {
				uint16_t sent = rte_eth_tx_buffer_flush(p, 0, txb[p]);

				if (sent) {
					st[p].tx += sent;
					st[p].flush_timer++;
				}
			}
			prev_tsc = cur;
		}
		if (cur >= next_print) {
			char tag[16];

			snprintf(tag, sizeof(tag), "t=%ds", ++tick);
			print_stats(tag);
			next_print += hz;
		}
		if (cur >= deadline)
			break;

		/* 2. receive, rewrite, buffer */
		for (p = 0; p < NB_PORTS; p++) {
			uint16_t out = p ^ 1, nb, i;

			nb = rte_eth_rx_burst(p, 0, pkts, MAX_PKT_BURST);
			st[p].rx += nb;
			for (i = 0; i < nb; i++) {
				uint16_t sent;
				const struct rte_ether_hdr *eh =
					rte_pktmbuf_mtod(pkts[i], const struct rte_ether_hdr *);

				/* EXERCISE 3: accept broadcast or our own MAC only */
				if (!rte_is_broadcast_ether_addr(&eh->dst_addr) &&
				    !rte_is_same_ether_addr(&eh->dst_addr, &port_mac[p])) {
					st[p].filtered++;
					rte_pktmbuf_free(pkts[i]);
					continue;
				}
				rewrite_macs(pkts[i], out);
				/* returns 0 while buffering, or the number sent
				 * when this frame filled the buffer */
				sent = rte_eth_tx_buffer(out, 0, txb[out], pkts[i]);
				if (sent) {
					st[out].tx += sent;
					st[out].flush_full++;
				}
			}
		}
	}

	print_stats("final");

	/* Look at one frame waiting in each loopback ring: MACs rewritten? */
	for (p = 0; p < NB_PORTS; p++) {
		uint16_t nb = rte_eth_rx_burst(p, 0, pkts, 1), i;

		if (nb == 1) {
			struct rte_ether_hdr *eth =
				rte_pktmbuf_mtod(pkts[0], struct rte_ether_hdr *);
			char s[RTE_ETHER_ADDR_FMT_SIZE], d[RTE_ETHER_ADDR_FMT_SIZE];

			rte_ether_format_addr(s, sizeof(s), &eth->src_addr);
			rte_ether_format_addr(d, sizeof(d), &eth->dst_addr);
			printf("frame waiting on port %u: src %s dst %s\n", p, s, d);
			rte_pktmbuf_free(pkts[0]);
		} else {
			printf("frame waiting on port %u: none\n", p);
		}
		/* The TX buffer OWNS its mbufs: free them or they leak. */
		for (i = 0; i < txb[p]->length; i++)
			rte_pktmbuf_free(txb[p]->pkts[i]);
		txb[p]->length = 0;
	}

	for (p = 0; p < NB_PORTS; p++) {
		rte_eth_dev_stop(p);
		rte_eth_dev_close(p);
		rte_free(txb[p]);
	}
	rte_eal_cleanup();
	return 0;
}
