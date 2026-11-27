/* SPDX-License-Identifier: BSD-3-Clause
 * failure_lab.c - four seeded faults and the counters each one moves.
 *
 *   --mode pool_dry   pool too small / app holds mbufs:
 *                     net_pcap (finite file) counts rx_nombuf; net_pcap
 *                     with infinite_rx silently returns 0 instead.
 *                     Recovers as soon as the app frees mbufs.
 *   --mode tx_full    a TX "wire" (rte_ring, 256 slots) drained slowly by
 *                     lcore 1; policies drop / retry / back-pressure, with
 *                     a second, fast port served by the same lcore to show
 *                     head-of-line blocking.
 *   --mode link_flap  net_tap; the program runs `ip link set <if> down/up`
 *                     like an operator pulling a cable. LSC callback vs
 *                     polling rte_eth_link_get_nowait().
 *   --mode reset      a simulated RTE_ETH_EVENT_INTR_RESET (raised from an
 *                     EAL alarm, i.e. the interrupt thread, like a real one)
 *                     and the recovery sequence; wrong orders shown failing.
 *
 * See run.sh for the vdevs each mode needs.
 */
#include <inttypes.h>
#include <stdatomic.h>
#include <rte_alarm.h>
#include <rte_cycles.h>
#include <rte_dev.h>
#include <rte_eth_ring.h>
#include <rte_launch.h>
#include <rte_lcore.h>
#include <rte_ring.h>
#include "ch12_common.h"

static uint64_t hz;

static double
ms_since(uint64_t t0)
{
	return (double)(rte_get_timer_cycles() - t0) * 1000.0 / hz;
}

static struct rte_mempool *
pool(const char *name, unsigned n, unsigned cache)
{
	struct rte_mempool *mp = rte_pktmbuf_pool_create(name, n, cache, 0,
			RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());

	if (!mp)
		rte_exit(EXIT_FAILURE, "pool %s: %s\n", name, rte_strerror(rte_errno));
	return mp;
}

/* ================= pool_dry ================= */
static void
pool_dry_port(uint16_t port, const char *label, unsigned extra)
{
	struct rte_mempool *mp;
	struct rte_mbuf *held[1024], *b[32];
	struct rte_eth_stats st;
	unsigned nheld = 0, i, freed;
	char pname[32];

	snprintf(pname, sizeof(pname), "dry%u", port);
	/* deliberately tiny, no cache. infinite_rx keeps a private copy of
	 * the whole file in mbufs from this pool, hence 'extra'. */
	mp = pool(pname, 255 + extra, 0);
	ch12_port_init(port, 1, 1, mp, NULL, NULL, 1);
	printf("\n%s (port %u, pool of %u mbufs)\n", label, port, mp->size);
	printf("  %-30s %9s %9s %10s %9s\n", "phase", "received", "ipackets",
	       "rx_nombuf", "in_use");
	/* phase 1: the app keeps every mbuf (a leak, or a slow consumer) */
	for (i = 0; i < 200; i++) {
		uint16_t n = rte_eth_rx_burst(port, 0, b, 32), k;

		for (k = 0; k < n && nheld < RTE_DIM(held); k++)
			held[nheld++] = b[k];
	}
	rte_eth_stats_get(port, &st);
	printf("  %-30s %9u %9" PRIu64 " %10" PRIu64 " %9u\n",
	       "200 polls, app holds mbufs", nheld, st.ipackets, st.rx_nombuf,
	       rte_mempool_in_use_count(mp));
	/* phase 2: the app releases them; RX recovers on the next poll */
	freed = nheld;
	rte_pktmbuf_free_bulk(held, nheld);
	nheld = 0;
	for (i = 0; i < 20; i++) {
		uint16_t n = rte_eth_rx_burst(port, 0, b, 32);

		nheld += n;
		rte_pktmbuf_free_bulk(b, n);
	}
	rte_eth_stats_get(port, &st);
	printf("  %-30s %9u %9" PRIu64 " %10" PRIu64 " %9u\n",
	       "app freed all, 20 more polls", nheld, st.ipackets, st.rx_nombuf,
	       rte_mempool_in_use_count(mp));
	printf("  (freed %u held mbufs)\n", freed);
	rte_eth_dev_stop(port);
	rte_eth_dev_close(port);
	rte_mempool_free(mp);
}

static void
mode_pool_dry(void)
{
	uint16_t p;

	RTE_ETH_FOREACH_DEV(p) {
		char name[RTE_ETH_NAME_MAX_LEN];

		rte_eth_dev_get_name_by_port(p, name, sizeof(name));
		if (strcmp(name, "net_pcap1") == 0)
			pool_dry_port(p, "net_pcap infinite_rx=1 (in.pcap: 2000 pkts kept in the pool)", 2000);
		else
			pool_dry_port(p, "net_pcap, finite file", 0);
	}
}

/* ================= tx_full ================= */
static struct rte_ring *slow_wire, *fast_wire;
static atomic_int consumer_run;

/* lcore 1: the "far end". Slow wire: 1 packet every ~2 us. Fast: all. */
static int
consumer(void *arg)
{
	void *o[64];
	unsigned n;

	(void)arg;
	while (atomic_load(&consumer_run)) {
		if (rte_ring_dequeue(slow_wire, o) == 0)
			rte_pktmbuf_free(o[0]);
		n = rte_ring_dequeue_burst(fast_wire, o, 64, NULL);
		rte_pktmbuf_free_bulk((struct rte_mbuf **)o, n);
		rte_delay_us_block(2);
	}
	return 0;
}

static void
mode_tx_full(void)
{
	static const char *pol[] = { "drop", "retry", "back-pressure" };
	struct rte_mempool *mp = pool("txf", 4095, 32);
	int slow, fast, p;

	slow_wire = rte_ring_create("slow_wire", 256, rte_socket_id(), 0);
	fast_wire = rte_ring_create("fast_wire", 4096, rte_socket_id(), 0);
	slow = rte_eth_from_ring(slow_wire);	/* TX into ring, RX unused */
	fast = rte_eth_from_ring(fast_wire);
	if (slow < 0 || fast < 0)
		rte_exit(EXIT_FAILURE, "from_ring\n");
	ch12_port_init(slow, 1, 1, mp, NULL, NULL, 1);
	ch12_port_init(fast, 1, 1, mp, NULL, NULL, 1);
	printf("slow port %d (256-slot wire, consumer ~1 pkt / 2 us), fast port %d\n",
	       slow, fast);
	printf("one lcore sends a burst of 32 to EACH port per loop, for 300 ms\n\n");
	printf("%-14s %10s %10s %10s %10s %12s\n", "policy", "slow sent",
	       "fast sent", "oerrors", "app drops", "loops/stalls");

	for (p = 0; p < 3; p++) {
		struct rte_mbuf *b[32], *pend[32];
		struct rte_eth_stats ss, fs;
		uint64_t t0, drops = 0, loops = 0, stalls = 0;
		unsigned npend = 0;

		rte_eth_stats_reset(slow);
		rte_eth_stats_reset(fast);
		atomic_store(&consumer_run, 1);
		rte_eal_remote_launch(consumer, NULL, 1);
		t0 = rte_get_timer_cycles();
		while (ms_since(t0) < 300) {
			uint16_t k;

			loops++;
			/* --- the slow port --- */
			if (p == 2 && npend) {
				/* back-pressure: do not take new input until the
				 * pending burst is gone (input waits upstream) */
				k = rte_eth_tx_burst(slow, 0, pend, npend);
				memmove(pend, pend + k, (npend - k) * sizeof(pend[0]));
				npend -= k;
				stalls++;
			} else if (rte_pktmbuf_alloc_bulk(mp, b, 32) == 0) {
				uint16_t i;

				for (i = 0; i < 32; i++)
					rte_pktmbuf_append(b[i], 60);
				k = rte_eth_tx_burst(slow, 0, b, 32);
				if (p == 0) {			/* drop */
					rte_pktmbuf_free_bulk(b + k, 32 - k);
					drops += 32 - k;
				} else if (p == 1) {		/* retry */
					while (k < 32) {
						k += rte_eth_tx_burst(slow, 0, b + k, 32 - k);
						stalls++;
					}
				} else {			/* back-pressure */
					npend = 32 - k;
					memcpy(pend, b + k, npend * sizeof(b[0]));
				}
			}
			/* --- the fast port, same lcore --- */
			if (rte_pktmbuf_alloc_bulk(mp, b, 32) == 0) {
				uint16_t i;

				for (i = 0; i < 32; i++)
					rte_pktmbuf_append(b[i], 60);
				k = rte_eth_tx_burst(fast, 0, b, 32);
				rte_pktmbuf_free_bulk(b + k, 32 - k);
			}
		}
		rte_pktmbuf_free_bulk(pend, npend);
		atomic_store(&consumer_run, 0);
		rte_eal_wait_lcore(1);
		rte_eth_stats_get(slow, &ss);
		rte_eth_stats_get(fast, &fs);
		printf("%-14s %10" PRIu64 " %10" PRIu64 " %10" PRIu64 " %10" PRIu64
		       " %6" PRIu64 "/%" PRIu64 "\n", pol[p], ss.opackets, fs.opackets,
		       ss.oerrors, drops, loops, stalls);
		{	/* empty the wires */
			void *o[64];
			unsigned n;

			while ((n = rte_ring_dequeue_burst(slow_wire, o, 64, NULL)))
				rte_pktmbuf_free_bulk((struct rte_mbuf **)o, n);
			while ((n = rte_ring_dequeue_burst(fast_wire, o, 64, NULL)))
				rte_pktmbuf_free_bulk((struct rte_mbuf **)o, n);
		}
	}
	printf("\nretry: the fast port is held hostage by the slow one (head-of-line\n"
	       "blocking). drop: both run at full speed; the losses appear ONLY in\n"
	       "the app's own counter (net_ring does not count oerrors, and a PMD\n"
	       "never counts what tx_burst did not accept). back-pressure: no loss\n"
	       "here, input waits upstream; on a real NIC its RX ring fills -> imissed.\n");
	rte_eth_dev_stop(slow);
	rte_eth_dev_stop(fast);
	rte_eth_dev_close(slow);
	rte_eth_dev_close(fast);
	rte_ring_free(slow_wire);
	rte_ring_free(fast_wire);
	printf("in use at exit: %u\n", rte_mempool_in_use_count(mp));
	rte_mempool_free(mp);
}

/* ================= link_flap ================= */
static atomic_int lsc_events;

static int
on_lsc(uint16_t port, enum rte_eth_event_type ev, void *a, void *r)
{
	(void)port; (void)ev; (void)a; (void)r;
	atomic_fetch_add(&lsc_events, 1);
	return 0;
}

static void
mode_link_flap(const char *ifname)
{
	struct rte_mempool *mp = pool("flap", 2047, 32);
	struct rte_eth_conf conf = { .intr_conf.lsc = 1 };
	struct rte_eth_dev_info di;
	uint16_t port = 0;
	uint64_t t0, last_op = 0, last_oe = 0;
	int last = -1, step = 0;
	int rc;

	if (rte_eth_dev_info_get(port, &di) != 0)
		return;
	rc = rte_eth_dev_callback_register(port, RTE_ETH_EVENT_INTR_LSC, on_lsc, NULL);
	printf("tap port %u: dev_flags INTR_LSC=%d, LSC callback register -> %s\n",
	       port, !!(*di.dev_flags & RTE_ETH_DEV_INTR_LSC), rcname(rc));
	rc = ch12_port_init(port, 1, 1, mp, &conf, NULL, 1);
	printf("started with intr_conf.lsc=1 -> %s; polling link every 50 ms, "
	       "sending 32 pkts every 10 ms\n\n", rcname(rc));
	if_quiet(ifname);

	t0 = rte_get_timer_cycles();
	while (ms_since(t0) < 1500) {
		struct rte_eth_link l;
		struct rte_mbuf *b[32];
		double t = ms_since(t0);
		static double next_poll;

		if (step == 0 && t > 400) {
			printf("  %7.1f ms  operator: ip link set %s down\n", t, ifname);
			if (system("ip link set ch12tap5 down") != 0)
				printf("ip failed\n");
			step = 1;
		} else if (step == 1 && t > 900) {
			printf("  %7.1f ms  operator: ip link set %s up\n", t, ifname);
			if (system("ip link set ch12tap5 up") != 0)
				printf("ip failed\n");
			step = 2;
		}
		if (rte_pktmbuf_alloc_bulk(mp, b, 32) == 0) {
			uint16_t i, k;

			for (i = 0; i < 32; i++)
				rte_pktmbuf_append(b[i], 60);
			k = rte_eth_tx_burst(port, 0, b, 32);
			rte_pktmbuf_free_bulk(b + k, 32 - k);
		}
		if (t >= next_poll) {
			next_poll = t + 50;
			if (rte_eth_link_get_nowait(port, &l) == 0 &&
			    (int)l.link_status != last) {
				struct rte_eth_stats s;

				rte_eth_stats_get(port, &s);
				printf("  %7.1f ms  poll: link %-4s  (opackets +%" PRIu64
				       ", oerrors +%" PRIu64 " since last change)  LSC callbacks so far: %d\n",
				       t, l.link_status ? "UP" : "DOWN",
				       s.opackets - last_op, s.oerrors - last_oe,
				       atomic_load(&lsc_events));
				last = l.link_status;
				last_op = s.opackets;
				last_oe = s.oerrors;
			}
		}
		rte_delay_us_sleep(10 * 1000);
	}
	{
		struct rte_eth_stats s;

		rte_eth_stats_get(port, &s);
		printf("  %7.1f ms  end: opackets +%" PRIu64 ", oerrors +%" PRIu64
		       ", LSC callbacks: %d\n", ms_since(t0), s.opackets - last_op,
		       s.oerrors - last_oe, atomic_load(&lsc_events));
	}
	printf("\nnet_tap advertises RTE_ETH_DEV_INTR_LSC but never raises the event:\n"
	       "only polling saw the flap. While down, tx_burst failed (oerrors).\n");
	rte_eth_dev_stop(port);
	rte_eth_dev_close(port);
	rte_mempool_free(mp);
}

/* ================= reset ================= */
static atomic_int reset_pending, worker_run, pause_req, paused;
static atomic_uint_fast64_t fwd;
static atomic_uint_least16_t cur_port;

static int
on_reset(uint16_t port, enum rte_eth_event_type ev, void *a, void *r)
{
	(void)a; (void)r;
	/* In the callback: only record the request. Recovery runs later in
	 * the control thread, which first quiesces the data path. */
	printf("  [event] port %u INTR_RESET (callback only sets a flag)\n", port);
	if (ev == RTE_ETH_EVENT_INTR_RESET)
		atomic_store(&reset_pending, 1);
	return 0;
}

/* stands in for the PMD: real drivers call rte_eth_dev_callback_process()
 * from their interrupt handler; we call the app's callback from an alarm
 * so it runs in the same dpdk-intr thread */
static void
fake_pmd_irq(void *arg)
{
	on_reset((uintptr_t)arg, RTE_ETH_EVENT_INTR_RESET, NULL, NULL);
}

static int
fwd_worker(void *arg)
{
	struct rte_mbuf *b[32];

	(void)arg;
	while (atomic_load(&worker_run)) {
		uint16_t p, n, k;

		if (atomic_load(&pause_req)) {
			atomic_store(&paused, 1);
			while (atomic_load(&pause_req))
				rte_pause();
			atomic_store(&paused, 0);
		}
		p = atomic_load(&cur_port);
		n = rte_eth_rx_burst(p, 0, b, 32);
		k = rte_eth_tx_burst(p, 0, b, n);
		rte_pktmbuf_free_bulk(b + k, n - k);
		atomic_fetch_add(&fwd, k);
	}
	return 0;
}

static void
mode_reset(void)
{
	static const char *mode_name[] = { "NONE", "PASSIVE", "PROACTIVE" };
	struct rte_mempool *mp = pool("rst", 4095, 32);
	struct rte_eth_dev_info di;
	char devargs[64] = "net_null0";
	uint16_t port = 0;
	uint64_t t0, before;
	int rc;

	if (rte_eth_dev_info_get(port, &di) != 0)
		return;
	printf("port %u %s: err_handle_mode = %s\n", port, di.driver_name,
	       mode_name[di.err_handle_mode]);
	printf("  (PASSIVE PMDs e.g. iavf/ena/igb raise INTR_RESET and wait for the app;\n"
	       "   PROACTIVE ones e.g. bnxt raise ERR_RECOVERING, recover, then\n"
	       "   RECOVERY_SUCCESS or RECOVERY_FAILED)\n");
	rte_eth_dev_callback_register(RTE_ETH_ALL, RTE_ETH_EVENT_INTR_RESET, on_reset, NULL);
	ch12_port_init(port, 1, 1, mp, NULL, NULL, 1);
	atomic_store(&cur_port, port);
	atomic_store(&worker_run, 1);
	rte_eal_remote_launch(fwd_worker, NULL, 1);
	rte_delay_ms(50);
	printf("forwarding on lcore 1: %" PRIu64 " pkts in 50 ms\n",
	       (uint64_t)atomic_load(&fwd));

	rte_eal_alarm_set(1000, fake_pmd_irq, (void *)(uintptr_t)port);
	while (!atomic_load(&reset_pending))
		rte_delay_us_sleep(100);

	printf("\nwrong order 1: reconfigure while the port is still started\n");
	rc = rte_eth_dev_configure(port, 1, 1, &(struct rte_eth_conf){0});
	printf("  rte_eth_dev_configure -> %s\n", rcname(rc));

	printf("\nright order:\n");
	t0 = rte_get_timer_cycles();
	atomic_store(&pause_req, 1);		/* 1. quiesce the data path */
	while (!atomic_load(&paused))
		rte_pause();
	before = atomic_load(&fwd);
	printf("  1. data path paused\n");
	rc = rte_eth_dev_stop(port);		/* 2. stop */
	printf("  2. rte_eth_dev_stop -> %s\n", rcname(rc));
	rc = rte_eth_dev_reset(port);		/* 3. reset */
	printf("  3. rte_eth_dev_reset -> %s\n", rcname(rc));
	if (rc == -ENOTSUP) {
		/* 3b. no dev_reset op (every vdev here): emulate it by hot
		 * re-plugging the device; the port id may change */
		struct rte_device *dev = di.device;

		rte_eth_dev_close(port);
		rc = rte_dev_remove(dev);
		printf("  3b. fallback: close + rte_dev_remove -> %s", rcname(rc));
		rc = rte_dev_probe(devargs);
		rte_eth_dev_get_port_by_name("net_null0", &port);
		printf(", rte_dev_probe(\"%s\") -> %s, new port id %u\n", devargs,
		       rcname(rc), port);
	}
	/* (queue setup before configure is the other classic wrong order;
	 * on net_null it crashes, see ch08 lifecycle_rules) */
	rc = ch12_port_init(port, 1, 1, mp, NULL, NULL, 1);	/* 4. */
	printf("  4. configure + queue setup + start -> %s\n", rcname(rc));
	atomic_store(&cur_port, port);
	atomic_store(&reset_pending, 0);
	atomic_store(&pause_req, 0);		/* 5. resume */
	printf("  5. data path resumed after %.3f ms outage\n", ms_since(t0));
	rte_delay_ms(50);
	printf("  forwarded %" PRIu64 " pkts in the 50 ms after recovery\n",
	       (uint64_t)(atomic_load(&fwd) - before));

	atomic_store(&worker_run, 0);
	rte_eal_wait_lcore(1);
	rte_eth_dev_stop(port);
	rte_eth_dev_close(port);
	printf("in use at exit: %u\n", rte_mempool_in_use_count(mp));
	rte_mempool_free(mp);
}

int
main(int argc, char **argv)
{
	const char *mode = NULL;
	int ret, i;

	setvbuf(stdout, NULL, _IOLBF, 0);
	ret = rte_eal_init(argc, argv);
	if (ret < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	hz = rte_get_timer_hz();
	for (i = ret + 1; i < argc - 1; i++)
		if (strcmp(argv[i], "--mode") == 0)
			mode = argv[i + 1];
	if (!mode)
		rte_exit(EXIT_FAILURE, "-- --mode pool_dry|tx_full|link_flap|reset\n");
	printf("=== failure_lab --mode %s ===\n", mode);
	if (strcmp(mode, "pool_dry") == 0)
		mode_pool_dry();
	else if (strcmp(mode, "tx_full") == 0 && rte_lcore_count() >= 2)
		mode_tx_full();
	else if (strcmp(mode, "link_flap") == 0)
		mode_link_flap("ch12tap5");
	else if (strcmp(mode, "reset") == 0 && rte_lcore_count() >= 2)
		mode_reset();
	else
		printf("unknown mode or not enough lcores (-l 0-1)\n");
	rte_eal_cleanup();
	return 0;
}
