/* SPDX-License-Identifier: BSD-3-Clause
 * Chapter 11: app_common.h - the part of the evolving app that does NOT change.
 *
 * This is chapter 10's mini_l2fwd boiled down to a few helpers:
 *   app_ports_init()   bring up port 0 and port 1 (1 RX + 1 TX queue each)
 *   app_inject()       put N IPv4/UDP frames into port 0
 *   app_forward_once() one pass of the poll loop: RX on each port, rewrite
 *                      the MACs, TX on the other port
 *   app_print_delta()  print per-port rx/tx/drop since the last call
 *
 * The ports are net_ring vdevs (--vdev=net_ring0 --vdev=net_ring1). A
 * net_ring port is a loopback: what you send on it comes back on its own RX
 * queue, so the injected frames bounce 0 -> 1 -> 0 ... for as long as the
 * forwarding loop runs. No NIC and no traffic generator are needed.
 *
 * Each step_N.c includes this header and adds ONE new EAL service on top:
 * step 1 a timer, step 2 a service core, step 3 keepalive, step 4 a shell,
 * step 5 proper options. Diff the step files to see exactly what each adds.
 */
#ifndef CH11_APP_COMMON_H
#define CH11_APP_COMMON_H

#ifndef _GNU_SOURCE
#define _GNU_SOURCE            /* pthread_getname_np() */
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <signal.h>
#include <pthread.h>
#include <inttypes.h>
#include <netinet/in.h>

#include <rte_eal.h>
#include <rte_common.h>
#include <rte_lcore.h>
#include <rte_cycles.h>
#include <rte_ethdev.h>
#include <rte_mbuf.h>
#include <rte_ether.h>
#include <rte_ip4.h>
#include <rte_udp.h>
#include <rte_errno.h>
#include <rte_stdatomic.h>

#define NB_PORTS      2
#define MAX_BURST     64       /* largest burst the app accepts */
#define RX_DESC       512
#define TX_DESC       512

/*
 * Per-port counters. ONE writer (the forwarding lcore) and one or more
 * readers (the stats timer / service / shell on other threads). The writer
 * uses a relaxed load + relaxed store instead of a locked add: with a single
 * writer that is enough, and it costs the same as a plain "+=". Chapter 14
 * explains memory ordering and why plain non-atomic counters would be a data
 * race in C even though x86 would "probably" be fine.
 */
struct __rte_cache_aligned port_ctr {
	RTE_ATOMIC(uint64_t) rx;
	RTE_ATOMIC(uint64_t) tx;
	RTE_ATOMIC(uint64_t) drop;
};

static struct port_ctr app_ctr[NB_PORTS];
static struct rte_ether_addr app_mac[NB_PORTS];
/* Where frames received on port p are sent. Step 5 reads it from app.ini. */
static uint16_t app_peer[NB_PORTS] = {1, 0};
static volatile bool force_quit;

static inline void
ctr_add(RTE_ATOMIC(uint64_t) *c, uint64_t n)
{
	rte_atomic_store_explicit(c,
		rte_atomic_load_explicit(c, rte_memory_order_relaxed) + n,
		rte_memory_order_relaxed);
}

static inline uint64_t
ctr_get(RTE_ATOMIC(uint64_t) *c)
{
	return rte_atomic_load_explicit(c, rte_memory_order_relaxed);
}

static void __rte_unused
app_on_signal(int sig)
{
	(void)sig;
	force_quit = true;
}

/* "Where am I running?" - thread name plus lcore id (LCORE_ID_ANY = not an lcore). */
static inline const char *
app_where(char *buf, size_t len)
{
	char name[32] = "?";
	unsigned int lc = rte_lcore_id();

	pthread_getname_np(pthread_self(), name, sizeof(name));
	if (lc == LCORE_ID_ANY)
		snprintf(buf, len, "thread '%s', not an lcore", name);
	else
		snprintf(buf, len, "thread '%s', lcore %u", name, lc);
	return buf;
}

/* Chapter 8's lifecycle: configure, queue setup, start. */
static inline int
app_port_init(uint16_t port, struct rte_mempool *pool)
{
	struct rte_eth_conf conf = {0};
	int ret;

	ret = rte_eth_dev_configure(port, 1, 1, &conf);
	if (ret < 0)
		return ret;
	ret = rte_eth_rx_queue_setup(port, 0, RX_DESC,
			rte_eth_dev_socket_id(port), NULL, pool);
	if (ret < 0)
		return ret;
	ret = rte_eth_tx_queue_setup(port, 0, TX_DESC,
			rte_eth_dev_socket_id(port), NULL);
	if (ret < 0)
		return ret;
	return rte_eth_dev_start(port);
}

static inline struct rte_mempool *
app_ports_init(void)
{
	struct rte_mempool *pool;
	uint16_t p;

	if (rte_eth_dev_count_avail() != NB_PORTS)
		rte_exit(EXIT_FAILURE,
			 "need exactly 2 ports (--vdev=net_ring0 --vdev=net_ring1)\n");
	pool = rte_pktmbuf_pool_create("ch11_pool", 4095, 64, 0,
				       RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
	if (pool == NULL)
		rte_exit(EXIT_FAILURE, "mbuf pool: %s\n", rte_strerror(rte_errno));
	for (p = 0; p < NB_PORTS; p++) {
		/* net_ring has no MAC address: use a locally administered one */
		struct rte_ether_addr a = {{0x02, 0, 0, 0, 0x11, (uint8_t)p}};

		if (app_port_init(p, pool) < 0)
			rte_exit(EXIT_FAILURE, "port %u init failed\n", p);
		app_mac[p] = a;
	}
	return pool;
}

/* Put n IPv4/UDP frames into port 0 by sending them on port 0 (loopback). */
static inline unsigned int
app_inject(struct rte_mempool *pool, unsigned int n)
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
		if (eth == NULL) {     /* no tailroom: cannot happen for 64 B */
			rte_pktmbuf_free(m);
			break;
		}
		memset(eth, 0, len);
		ip = (struct rte_ipv4_hdr *)(eth + 1);
		udp = (struct rte_udp_hdr *)(ip + 1);
		eth->dst_addr = app_mac[0];
		eth->src_addr = app_mac[1];
		eth->ether_type = RTE_BE16(RTE_ETHER_TYPE_IPV4);
		ip->version_ihl = RTE_IPV4_VHL_DEF;
		ip->total_length = rte_cpu_to_be_16(len - sizeof(*eth));
		ip->time_to_live = 64;
		ip->next_proto_id = IPPROTO_UDP;
		ip->src_addr = RTE_BE32(RTE_IPV4(10, 11, 1, 1));
		ip->dst_addr = rte_cpu_to_be_32(RTE_IPV4(10, 11, 2, 1) + i);
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

/*
 * One pass of the poll loop: for each port, receive up to 'burst' frames,
 * rewrite the MACs like l2fwd and send them out of the peer port.
 * Returns the number of frames received (0 = this pass was idle).
 */
static inline unsigned int
app_forward_once(uint16_t burst)
{
	struct rte_mbuf *pkts[MAX_BURST];
	unsigned int total = 0;
	uint16_t p;

	for (p = 0; p < NB_PORTS; p++) {
		uint16_t out = app_peer[p], nb, sent, i;

		nb = rte_eth_rx_burst(p, 0, pkts, burst);
		if (nb == 0)
			continue;
		for (i = 0; i < nb; i++) {
			struct rte_ether_hdr *eth =
				rte_pktmbuf_mtod(pkts[i], struct rte_ether_hdr *);
			struct rte_ether_addr dst = {{0x02, 0, 0, 0, 0, (uint8_t)out}};

			eth->dst_addr = dst;
			eth->src_addr = app_mac[out];
		}
		sent = rte_eth_tx_burst(out, 0, pkts, nb);
		if (sent < nb)
			rte_pktmbuf_free_bulk(&pkts[sent], nb - sent);
		ctr_add(&app_ctr[p].rx, nb);
		ctr_add(&app_ctr[out].tx, sent);
		ctr_add(&app_ctr[out].drop, nb - sent);
		total += nb;
	}
	return total;
}

/* Print what happened since the previous call (keeps its own snapshot). */
static inline void
app_print_delta(const char *tag, double secs)
{
	static uint64_t last[NB_PORTS][3];
	uint16_t p;

	for (p = 0; p < NB_PORTS; p++) {
		uint64_t rx = ctr_get(&app_ctr[p].rx);
		uint64_t tx = ctr_get(&app_ctr[p].tx);
		uint64_t dr = ctr_get(&app_ctr[p].drop);

		printf("%s port %u: rx %9" PRIu64 " (+%.2f Mpps)  tx %9" PRIu64
		       "  drop %" PRIu64 "\n", tag, p, rx,
		       secs > 0 ? (rx - last[p][0]) / secs / 1e6 : 0.0, tx, dr);
		last[p][0] = rx;
		last[p][1] = tx;
		last[p][2] = dr;
	}
	fflush(stdout);
}

static inline void
app_ports_close(void)
{
	uint16_t p;

	for (p = 0; p < NB_PORTS; p++) {
		rte_eth_dev_stop(p);
		rte_eth_dev_close(p);
	}
}

#endif /* CH11_APP_COMMON_H */
