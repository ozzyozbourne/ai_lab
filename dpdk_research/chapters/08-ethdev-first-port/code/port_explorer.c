/* SPDX-License-Identifier: BSD-3-Clause
 *
 * port_explorer.c - Chapter 8: discover ports, read their capabilities and
 * walk each one through the ethdev lifecycle, printing what every call
 * returns, including the calls that are *supposed* to fail.
 *
 *   probe -> [unconfigured] -configure-> [configured] -queue_setup-> [ready]
 *        -start-> [started] -stop-> [stopped] -close-> [closed]
 *
 * For every port found it:
 *   1. prints identity (id <-> name) and the rte_eth_dev_info capabilities
 *   2. calls rte_eth_rx_burst() BEFORE start: the fast path still points at
 *      ethdev's dummy functions, so it returns 0 and sets rte_errno=ENOTSUP
 *   3. configure(1 rxq, 1 txq), adjust descriptors, queue setup, start
 *   4. calls rte_eth_dev_configure() while started: -EBUSY
 *   5. link, MAC, promiscuous, a short TX/RX exchange, rte_eth_stats_get and
 *      the per-queue xstats (in 26.11 per-queue counters live only there)
 *   6. stop, rx_burst after stop (dummy again), a deferred-start preview
 *      (queue started by hand with rte_eth_dev_rx_queue_start), close
 *
 * Application options (after "--"):
 *   --nb-desc N   number of Rx/Tx descriptors to ask for (default 1024).
 *                 Used by init_errors.sh to provoke the descriptor-limit check.
 *   --no-adjust   do NOT call rte_eth_dev_adjust_nb_rx_tx_desc(), so a bad
 *                 nb_desc reaches rte_eth_rx_queue_setup() unchanged.
 *
 * Run here (see run.sh):
 *   ./port_explorer -l 0 --no-pci --no-huge -m 128 --file-prefix=ch08-ports \
 *       --vdev=net_null0 --vdev=net_ring0 --vdev=net_tap0,iface=ch08tap0
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <inttypes.h>
#include <getopt.h>

#include <rte_eal.h>
#include <rte_errno.h>
#include <rte_ethdev.h>
#include <rte_mbuf.h>
#include <rte_ether.h>

#define NB_MBUFS   4095   /* 2^12 - 1: the best size for a ring-backed pool */
#define CACHE_SIZE 128
#define BURST      32

static uint16_t want_desc = 1024;
static int do_adjust = 1;

/* Print every bit set in an offload mask, by name (ethdev knows the names). */
static void
print_offloads(const char *title, uint64_t mask,
	       const char *(*name_of)(uint64_t))
{
	printf("  %-16s 0x%016" PRIx64, title, mask);
	if (mask == 0)
		printf(" (none)");
	for (int b = 0; b < 64; b++)
		if (mask & (UINT64_C(1) << b))
			printf(" %s", name_of(UINT64_C(1) << b));
	printf("\n");
}

/* Print "name -> ret (meaning)" for a call that returns 0 or -errno. */
static int
report(const char *what, int ret)
{
	if (ret < 0)
		printf("  %-34s -> %d (%s)\n", what, ret, rte_strerror(-ret));
	else
		printf("  %-34s -> %d\n", what, ret);
	return ret;
}

/* Build n small broadcast frames with an experimental EtherType (0x88B5). */
static unsigned
make_frames(struct rte_mempool *mp, struct rte_mbuf **pkts, unsigned n)
{
	if (rte_pktmbuf_alloc_bulk(mp, pkts, n) != 0)
		return 0;
	for (unsigned i = 0; i < n; i++) {
		struct rte_ether_hdr *eh = (struct rte_ether_hdr *)
			rte_pktmbuf_append(pkts[i], 60);
		memset(eh, 0, 60);
		memset(&eh->dst_addr, 0xff, RTE_ETHER_ADDR_LEN);
		eh->src_addr.addr_bytes[0] = 0x02;          /* locally administered */
		eh->src_addr.addr_bytes[5] = (uint8_t)i;
		eh->ether_type = rte_cpu_to_be_16(0x88B5);
	}
	return n;
}

static void
explore_port(uint16_t port, struct rte_mempool *mp)
{
	struct rte_eth_dev_info info;
	struct rte_mbuf *pkts[BURST];
	char name[RTE_ETH_NAME_MAX_LEN];
	uint16_t back = UINT16_MAX;
	int ret;

	/* ---- 1. identity ------------------------------------------------ */
	/* 26.11: get_name_by_port takes the buffer size as a third argument. */
	rte_eth_dev_get_name_by_port(port, name, sizeof(name));
	rte_eth_dev_get_port_by_name(name, &back);
	printf("\n=== port %u: \"%s\" (get_port_by_name -> %u, valid=%d, socket=%d) ===\n",
	       port, name, back, rte_eth_dev_is_valid_port(port),
	       rte_eth_dev_socket_id(port));

	/* ---- capabilities ------------------------------------------------ */
	ret = rte_eth_dev_info_get(port, &info);
	if (ret != 0) {
		report("rte_eth_dev_info_get", ret);
		return;
	}
	printf("  driver           %s\n", info.driver_name);
	printf("  queues           max_rx=%u max_tx=%u\n",
	       info.max_rx_queues, info.max_tx_queues);
	printf("  rx_desc_lim      min=%u max=%u align=%u   tx_desc_lim min=%u max=%u align=%u\n",
	       info.rx_desc_lim.nb_min, info.rx_desc_lim.nb_max, info.rx_desc_lim.nb_align,
	       info.tx_desc_lim.nb_min, info.tx_desc_lim.nb_max, info.tx_desc_lim.nb_align);
	printf("  preferred        rx ring=%u burst=%u   tx ring=%u burst=%u  (0 = no preference)\n",
	       info.default_rxportconf.ring_size, info.default_rxportconf.burst_size,
	       info.default_txportconf.ring_size, info.default_txportconf.burst_size);
	printf("  mtu              min=%u max=%u   max_rx_pktlen=%u  min_rx_bufsize=%u\n",
	       info.min_mtu, info.max_mtu, info.max_rx_pktlen, info.min_rx_bufsize);
	print_offloads("rx_offload_capa", info.rx_offload_capa, rte_eth_dev_rx_offload_name);
	print_offloads("tx_offload_capa", info.tx_offload_capa, rte_eth_dev_tx_offload_name);
	printf("  rss              reta_size=%u key=%u B flow_type_rss_offloads=0x%" PRIx64 "\n",
	       info.reta_size, info.hash_key_size, info.flow_type_rss_offloads);

	/* ---- 2. the fast path before start --------------------------------- */
	/* rte_eth_fp_ops[port] still holds ethdev's dummy rx function. It logs
	 * once ("called rx_pkt_burst for not ready port"), dumps the stack,
	 * sets rte_errno = ENOTSUP and returns 0. Your app just sees "0". */
	rte_errno = 0;
	uint16_t n = rte_eth_rx_burst(port, 0, pkts, BURST);
	printf("  rx_burst before configure        -> %u, rte_errno=%d (%s)\n",
	       n, rte_errno, rte_strerror(rte_errno));

	/* ---- 3. configure -> queue setup -> start ---------------------------- */
	struct rte_eth_conf conf;
	memset(&conf, 0, sizeof(conf));       /* all defaults: 1 queue, no RSS */
	if (report("rte_eth_dev_configure(1,1)", rte_eth_dev_configure(port, 1, 1, &conf)) < 0)
		return;

	uint16_t nb_rxd = want_desc, nb_txd = want_desc;
	if (do_adjust) {
		/* Clamp to [nb_min, nb_max] and round to nb_align. */
		report("rte_eth_dev_adjust_nb_rx_tx_desc", rte_eth_dev_adjust_nb_rx_tx_desc(port, &nb_rxd, &nb_txd));
		printf("  descriptors asked %u -> using rx=%u tx=%u\n", want_desc, nb_rxd, nb_txd);
	}
	char what[64];
	snprintf(what, sizeof(what), "rte_eth_rx_queue_setup(q0, %u)", nb_rxd);
	/* NULL rxconf = dev_info.default_rxconf. The pool feeds the queue. */
	if (report(what, rte_eth_rx_queue_setup(port, 0, nb_rxd, rte_eth_dev_socket_id(port), NULL, mp)) < 0)
		goto close;
	snprintf(what, sizeof(what), "rte_eth_tx_queue_setup(q0, %u)", nb_txd);
	if (report(what, rte_eth_tx_queue_setup(port, 0, nb_txd, rte_eth_dev_socket_id(port), NULL)) < 0)
		goto close;
	if (report("rte_eth_dev_start", rte_eth_dev_start(port)) < 0)
		goto close;

	/* ---- 4. reconfiguring a started port is refused --------------------- */
	report("rte_eth_dev_configure while started", rte_eth_dev_configure(port, 1, 1, &conf));

	/* ---- 5. link, MAC, promiscuous ------------------------------------- */
	struct rte_eth_link link;
	char lstr[RTE_ETH_LINK_MAX_STR_LEN];
	if (rte_eth_link_get_nowait(port, &link) == 0) {  /* never blocks */
		rte_eth_link_to_str(lstr, sizeof(lstr), &link);
	} else {
		snprintf(lstr, sizeof(lstr), "unknown");
	}
	printf("  link             %s\n", lstr);
	struct rte_ether_addr mac;
	rte_eth_macaddr_get(port, &mac);
	printf("  mac              " RTE_ETHER_ADDR_PRT_FMT "\n", RTE_ETHER_ADDR_BYTES(&mac));
	report("rte_eth_promiscuous_enable", rte_eth_promiscuous_enable(port));

	/* A tiny exchange: send 8 frames, then poll a few times. */
	unsigned made = make_frames(mp, pkts, 8);
	uint16_t sent = rte_eth_tx_burst(port, 0, pkts, made);
	if (sent < made)                       /* the unsent tail is still ours */
		rte_pktmbuf_free_bulk(&pkts[sent], made - sent);
	unsigned got = 0;
	for (int i = 0; i < 4; i++) {
		uint16_t r = rte_eth_rx_burst(port, 0, pkts, BURST);
		got += r;
		rte_pktmbuf_free_bulk(pkts, r);     /* rx_burst gave us ownership */
	}
	printf("  tx_burst(8) accepted %u; 4 x rx_burst(32) returned %u in total\n", sent, got);

	struct rte_eth_stats st;
	rte_eth_stats_get(port, &st);
	printf("  stats            ipackets=%" PRIu64 " opackets=%" PRIu64 " ibytes=%" PRIu64
	       " obytes=%" PRIu64 " imissed=%" PRIu64 " ierrors=%" PRIu64 " oerrors=%" PRIu64
	       " rx_nombuf=%" PRIu64 "\n", st.ipackets, st.opackets, st.ibytes, st.obytes,
	       st.imissed, st.ierrors, st.oerrors, st.rx_nombuf);

	/* Per-queue counters: only xstats in 26.11. Print the rx_q0/tx_q0 ones. */
	int nx = rte_eth_xstats_get(port, NULL, 0);
	if (nx > 0) {
		struct rte_eth_xstat *xs = calloc(nx, sizeof(*xs));
		struct rte_eth_xstat_name *xn = calloc(nx, sizeof(*xn));
		rte_eth_xstats_get_names(port, xn, nx);
		rte_eth_xstats_get(port, xs, nx);
		printf("  xstats           %d counters; per-queue ones:", nx);
		for (int i = 0; i < nx; i++)
			if (strncmp(xn[xs[i].id].name, "rx_q0_", 6) == 0 ||
			    strncmp(xn[xs[i].id].name, "tx_q0_", 6) == 0)
				printf(" %s=%" PRIu64, xn[xs[i].id].name, xs[i].value);
		printf("\n");
		free(xs);
		free(xn);
	}

	/* ---- 6. stop: fast path goes back to the dummies -------------------- */
	report("rte_eth_dev_stop", rte_eth_dev_stop(port));
	rte_errno = 0;
	n = rte_eth_rx_burst(port, 0, pkts, BURST);
	printf("  rx_burst after stop              -> %u, rte_errno=%d (%s)\n",
	       n, rte_errno, rte_strerror(rte_errno));

	/* Preview of deferred start (full lab in ch12): set up queue 0 with
	 * rx_deferred_start=1, start the port, then start the queue by hand. */
	struct rte_eth_rxconf rxc = info.default_rxconf;
	rxc.rx_deferred_start = 1;
	if (report("rx_queue_setup(q0, deferred_start)",
		   rte_eth_rx_queue_setup(port, 0, nb_rxd, rte_eth_dev_socket_id(port), &rxc, mp)) == 0) {
		report("rte_eth_dev_start", rte_eth_dev_start(port));
		report("rte_eth_dev_rx_queue_start(q0)", rte_eth_dev_rx_queue_start(port, 0));
		report("rte_eth_dev_rx_queue_stop(q0)", rte_eth_dev_rx_queue_stop(port, 0));
		report("rte_eth_dev_stop", rte_eth_dev_stop(port));
	}
close:
	report("rte_eth_dev_close", rte_eth_dev_close(port));
}

static void
parse_app_args(int argc, char **argv)
{
	static const struct option opts[] = {
		{ "nb-desc", required_argument, NULL, 'n' },
		{ "no-adjust", no_argument, NULL, 'a' },
		{ NULL, 0, NULL, 0 }
	};
	int c;
	while ((c = getopt_long(argc, argv, "", opts, NULL)) != -1) {
		if (c == 'n')
			want_desc = (uint16_t)atoi(optarg);
		else if (c == 'a')
			do_adjust = 0;
		else
			rte_exit(EXIT_FAILURE, "usage: [--nb-desc N] [--no-adjust]\n");
	}
}

int
main(int argc, char **argv)
{
	int ret = rte_eal_init(argc, argv);
	if (ret < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed: %s\n", rte_strerror(rte_errno));
	parse_app_args(argc - ret, argv + ret);

	uint16_t nb = rte_eth_dev_count_avail();
	printf("rte_eth_dev_count_avail() = %u\n", nb);
	if (nb == 0)
		rte_exit(EXIT_FAILURE, "No Ethernet ports - add --vdev=net_null0 (or bind a NIC)\n");

	struct rte_mempool *mp = rte_pktmbuf_pool_create("ch08_explore", NB_MBUFS,
			CACHE_SIZE, 0, RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
	if (mp == NULL)
		rte_exit(EXIT_FAILURE, "mbuf pool: %s\n", rte_strerror(rte_errno));

	/* Collect the ids first: closing a port while iterating would change
	 * what RTE_ETH_FOREACH_DEV sees. */
	uint16_t ids[RTE_MAX_ETHPORTS], cnt = 0, p;
	RTE_ETH_FOREACH_DEV(p)
		ids[cnt++] = p;
	for (uint16_t i = 0; i < cnt; i++)
		explore_port(ids[i], mp);

	printf("\nafter close: rte_eth_dev_count_avail() = %u, mbufs in pool %u/%u\n",
	       rte_eth_dev_count_avail(), rte_mempool_avail_count(mp), NB_MBUFS);
	rte_mempool_free(mp);
	rte_eal_cleanup();
	return 0;
}
