/* SPDX-License-Identifier: BSD-3-Clause
 * runtime_reconf.c - what can change on a running port, what costs a
 * restart, how long the restart takes, and an ordered graceful shutdown.
 *
 * Part 1  "what needs a restart" table: on each STARTED port try every
 *         change and record the return code. -EBUSY = "stop the port first".
 * Part 2  outage of a full stop / configure / queue setup / start cycle,
 *         with a forwarding lcore that must be paused around it
 *         (median of 5, min..max, microseconds).
 * Part 3  run a small pipeline until SIGINT, then tear down IN ORDER and
 *         check rte_mempool_in_use_count() == 0 (PASS/FAIL).
 *         --sloppy skips the two drain steps to show the FAIL case.
 *
 *   worker lcore:  net_null0 RX --> app ring --> tx_buffer --> net_ring0 TX
 *   (net_ring0 is a loopback nobody polls: the "wire" itself holds mbufs)
 *
 * Run: timeout -s INT 6 ./runtime_reconf -l 0-1 --no-pci --no-huge -m 128 \
 *        --file-prefix=ch12-rr --vdev=net_null0 --vdev=net_ring0 \
 *        --vdev=net_tap0,iface=ch12tap3 [-- --sloppy]
 */
#include <inttypes.h>
#include <signal.h>
#include <stdatomic.h>
#include <rte_cycles.h>
#include <rte_launch.h>
#include <rte_lcore.h>
#include <rte_malloc.h>
#include <rte_ring.h>
#include "ch12_common.h"

static struct rte_mempool *mp;
static volatile sig_atomic_t got_sigint;
static atomic_int run_worker = 1;	/* 0 = leave the loop */
static atomic_int pause_req, paused;	/* pause handshake */
static atomic_uint_fast64_t fwd_pkts;
static uint16_t P_NULL, P_RING, P_TAP;
static struct rte_ring *app_ring;
static struct rte_eth_dev_tx_buffer *txb;

static void
on_sigint(int s)
{
	(void)s;
	got_sigint = 1;
}

/* ---------------- Part 1 ---------------- */
struct probe {
	const char *what;
	int rc[3];
};

static void
restart_table(void)
{
	uint16_t ports[3] = { P_NULL, P_RING, P_TAP };
	struct probe pr[] = {
		{ .what = "configure (queue count 1->2)" }, { .what = "rx offload change (configure)" },
		{ .what = "rx_queue_setup on started port" }, { .what = "default_mac_addr_set" },
		{ .what = "promiscuous_disable / enable" }, { .what = "set_mtu 1500 -> 1400" },
		{ .what = "rss_hash_update" }, { .what = "reta_update" }, { .what = "vlan offload set" },
		{ .what = "set_link_down / up" },
	};
	unsigned i, k;

	for (k = 0; k < 3; k++) {
		uint16_t p = ports[k];
		struct rte_eth_conf c = {0};
		struct rte_ether_addr mac = {{0x02, 0x12, 0, 0, 0x33, (uint8_t)k}};
		struct rte_eth_rss_conf rss = { .rss_hf = RTE_ETH_RSS_IP };
		int r;

		struct rte_eth_dev_info di;
		struct rte_eth_conf rssc = { .rxmode.mq_mode = RTE_ETH_MQ_RX_RSS };
		struct rte_eth_rss_reta_entry64 rt[8];

		if (rte_eth_dev_info_get(p, &di) != 0)
			continue;
		/* start in RSS mode (with the hash types the PMD claims) so the
		 * RSS/RETA rows test "live change", not "RSS not enabled" */
		rssc.rx_adv_conf.rss_conf.rss_hf = di.flow_type_rss_offloads;
		if (di.flow_type_rss_offloads == 0)
			rssc.rxmode.mq_mode = RTE_ETH_MQ_RX_NONE;
		ch12_port_init(p, 1, 1, mp, &rssc, NULL, 1);
		pr[0].rc[k] = rte_eth_dev_configure(p, 2, 2, &c);
		c.rxmode.offloads = RTE_ETH_RX_OFFLOAD_SCATTER;
		pr[1].rc[k] = rte_eth_dev_configure(p, 1, 1, &c);
		pr[2].rc[k] = rte_eth_rx_queue_setup(p, 0, 256, 0, NULL, mp);
		pr[3].rc[k] = rte_eth_dev_default_mac_addr_set(p, &mac);
		r = rte_eth_promiscuous_disable(p);
		pr[4].rc[k] = r ? r : rte_eth_promiscuous_enable(p);
		pr[5].rc[k] = rte_eth_dev_set_mtu(p, 1400);
		rss.rss_hf = di.flow_type_rss_offloads & RTE_ETH_RSS_IP;
		pr[6].rc[k] = rte_eth_dev_rss_hash_update(p, &rss);
		memset(rt, 0, sizeof(rt));
		rt[0].mask = 1;		/* change entry 0 only: point it at queue 0 */
		pr[7].rc[k] = rte_eth_dev_rss_reta_update(p, rt,
				di.reta_size ? di.reta_size : 64);
		pr[8].rc[k] = rte_eth_dev_set_vlan_offload(p, RTE_ETH_VLAN_STRIP_OFFLOAD);
		r = rte_eth_dev_set_link_down(p);
		pr[9].rc[k] = r ? r : rte_eth_dev_set_link_up(p);
		rte_eth_dev_set_mtu(p, RTE_ETHER_MTU);
		rte_eth_dev_stop(p);
	}
	printf("\n=== Part 1: change attempted while the port is STARTED ===\n");
	printf("%-34s %-9s %-9s %-9s\n", "change", "null", "ring", "tap");
	for (i = 0; i < RTE_DIM(pr); i++)
		printf("%-34s %-9s %-9s %-9s\n", pr[i].what, rcname(pr[i].rc[0]),
		       rcname(pr[i].rc[1]), rcname(pr[i].rc[2]));
	printf("-EBUSY = needs stop/reconfigure/start; -ENOTSUP/-ENOSYS = PMD or\n"
	       "offload missing; OK = changed live\n");
}

/* ---------------- worker ---------------- */
static int
worker(void *arg)
{
	struct rte_mbuf *b[32];
	uint16_t port = *(uint16_t *)arg;
	int pipeline = port == RTE_MAX_ETHPORTS;	/* Part 3 mode */

	if (pipeline)
		port = P_NULL;
	while (atomic_load(&run_worker)) {
		uint16_t n, k;

		if (atomic_load(&pause_req)) {		/* control plane wants the port */
			atomic_store(&paused, 1);
			while (atomic_load(&pause_req))
				rte_pause();
			atomic_store(&paused, 0);
			continue;
		}
		n = rte_eth_rx_burst(port, 0, b, 32);
		if (!pipeline) {
			k = rte_eth_tx_burst(port, 0, b, n);
			rte_pktmbuf_free_bulk(b + k, n - k);
			atomic_fetch_add(&fwd_pkts, n);
			continue;
		}
		/* Part 3: rx -> app ring -> tx_buffer -> net_ring0 */
		k = rte_ring_enqueue_burst(app_ring, (void **)b, n, NULL);
		rte_pktmbuf_free_bulk(b + k, n - k);
		if (rte_ring_count(app_ring) > 512) {	/* consumer is slower */
			n = rte_ring_dequeue_burst(app_ring, (void **)b, 8, NULL);
			for (k = 0; k < n; k++)
				rte_eth_tx_buffer(P_RING, 0, txb, b[k]);
		}
		atomic_fetch_add(&fwd_pkts, n);
	}
	return 0;
}

/* ---------------- Part 2 ---------------- */
static int
cmpd(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;

	return x < y ? -1 : x > y;
}

static void
outage(uint16_t port, const char *name)
{
	static uint16_t arg;
	double us[5], hz = rte_get_timer_hz();
	uint64_t before, after;
	unsigned i;

	arg = port;
	ch12_port_init(port, 1, 1, mp, NULL, NULL, 1);
	atomic_store(&run_worker, 1);
	rte_eal_remote_launch(worker, &arg, 1);
	rte_delay_ms(50);
	for (i = 0; i < 5; i++) {
		uint64_t t0, t1;

		/* 1. ask the data path to stop touching the port and WAIT */
		atomic_store(&pause_req, 1);
		while (!atomic_load(&paused))
			rte_pause();
		before = atomic_load(&fwd_pkts);
		t0 = rte_get_timer_cycles();
		/* 2. the restart itself */
		rte_eth_dev_stop(port);
		ch12_port_init(port, 1, 1, mp, NULL, NULL, 1);
		t1 = rte_get_timer_cycles();
		after = atomic_load(&fwd_pkts);
		/* 3. let the data path go again */
		atomic_store(&pause_req, 0);
		us[i] = (t1 - t0) * 1e6 / hz;
		if (after != before)
			printf("  BUG: worker forwarded during the restart\n");
		rte_delay_ms(20);
	}
	atomic_store(&run_worker, 0);
	rte_eal_wait_lcore(1);
	rte_eth_dev_stop(port);
	qsort(us, 5, sizeof(us[0]), cmpd);
	printf("  %-6s stop+configure+setup+start: median %8.1f us  (min %.1f, max %.1f)"
	       "  forwarded %" PRIu64 " pkts total\n", name, us[2], us[0], us[4],
	       (uint64_t)atomic_load(&fwd_pkts));
	atomic_store(&fwd_pkts, 0);
}

/* ---------------- Part 3 ---------------- */
static void
teardown(int sloppy)
{
	struct rte_mbuf *b[64];
	unsigned n, total;
	uint16_t p;
	int rc;

	printf("\n=== Part 3: ordered teardown%s ===\n", sloppy ? " (SLOPPY)" : "");
	printf("  in use before teardown: %u of %u mbufs\n",
	       rte_mempool_in_use_count(mp), mp->size);
	/* 1. stop RX polling: the worker leaves its loop, then we join it */
	atomic_store(&run_worker, 0);
	rte_eal_wait_lcore(1);
	printf("  1. worker stopped and joined\n");
	/* 2. drain application rings */
	if (!sloppy) {
		for (total = 0; (n = rte_ring_dequeue_burst(app_ring, (void **)b, 64,
							    NULL)) > 0; total += n)
			rte_pktmbuf_free_bulk(b, n);
		printf("  2. app ring drained: %u mbufs freed\n", total);
	} else {
		printf("  2. (skipped) app ring still holds %u mbufs\n",
		       rte_ring_count(app_ring));
	}
	/* 3. flush buffered TX */
	n = rte_eth_tx_buffer_flush(P_RING, 0, txb);
	printf("  3. tx_buffer flushed: %u sent\n", n);
	/* 4. ask the PMD to free completed TX mbufs */
	rc = rte_eth_tx_done_cleanup(P_RING, 0, 0);
	printf("  4. rte_eth_tx_done_cleanup -> %s\n", rc >= 0 ? "OK" : rcname(rc));
	/* 5. a software 'wire' (net_ring loopback) holds mbufs: drain it */
	if (!sloppy) {
		for (total = 0; (n = rte_eth_rx_burst(P_RING, 0, b, 64)) > 0; total += n)
			rte_pktmbuf_free_bulk(b, n);
		printf("  5. net_ring0 loopback drained: %u mbufs\n", total);
	} else {
		printf("  5. (skipped) net_ring0 loopback not drained\n");
	}
	/* 6. stop and close every port: PMDs free their RX ring mbufs */
	RTE_ETH_FOREACH_DEV(p) {
		rte_eth_dev_stop(p);
		rte_eth_dev_close(p);
	}
	printf("  6. all ports stopped and closed\n");
	/* 7. the check */
	n = rte_mempool_in_use_count(mp);
	printf("  7. rte_mempool_in_use_count = %u -> %s\n", n, n == 0 ? "PASS" : "FAIL");
	/* 8. only now free the pool and clean up the EAL */
	rte_ring_free(app_ring);
	rte_free(txb);
	rte_mempool_free(mp);
	printf("  8. pool freed, calling rte_eal_cleanup()\n");
}

int
main(int argc, char **argv)
{
	static uint16_t pipe_arg = RTE_MAX_ETHPORTS;
	int ret, sloppy = 0;

	setvbuf(stdout, NULL, _IOLBF, 0);
	ret = rte_eal_init(argc, argv);
	if (ret < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	if (argc - ret > 1 && strcmp(argv[ret + 1], "--sloppy") == 0)
		sloppy = 1;
	signal(SIGINT, on_sigint);
	if (rte_lcore_count() < 2)
		rte_exit(EXIT_FAILURE, "need -l 0-1\n");
	if (rte_eth_dev_get_port_by_name("net_null0", &P_NULL) ||
	    rte_eth_dev_get_port_by_name("net_ring0", &P_RING) ||
	    rte_eth_dev_get_port_by_name("net_tap0", &P_TAP))
		rte_exit(EXIT_FAILURE, "need net_null0, net_ring0, net_tap0\n");
	mp = rte_pktmbuf_pool_create("rr_pool", 8191, 64, 0,
				     RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
	app_ring = rte_ring_create("app_ring", 1024, rte_socket_id(),
				   RING_F_SP_ENQ | RING_F_SC_DEQ);
	txb = rte_zmalloc("txb", RTE_ETH_TX_BUFFER_SIZE(32), 0);
	if (!mp || !app_ring || !txb)
		rte_exit(EXIT_FAILURE, "alloc failed\n");
	rte_eth_tx_buffer_init(txb, 32);	/* default: drop (free) unsent */

	restart_table();

	printf("\n=== Part 2: outage of a full restart (worker paused around it) ===\n");
	outage(P_NULL, "null");
	outage(P_TAP, "tap");

	printf("\n(Part 3 pipeline running until SIGINT)\n");
	ch12_port_init(P_NULL, 1, 1, mp, NULL, NULL, 1);
	ch12_port_init(P_RING, 1, 1, mp, NULL, NULL, 1);
	atomic_store(&run_worker, 1);
	rte_eal_remote_launch(worker, &pipe_arg, 1);
	while (!got_sigint)
		rte_delay_us_sleep(100 * 1000);
	printf("SIGINT received\n");
	teardown(sloppy);
	rte_eal_cleanup();
	return 0;
}
