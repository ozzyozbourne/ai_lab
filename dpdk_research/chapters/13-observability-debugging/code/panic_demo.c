/* SPDX-License-Identifier: BSD-3-Clause
 * Chapter 13: panic_demo.c - a program that dies on purpose, for gdb and
 * for the core-dump post-mortem lab.
 *
 * What it does:
 *   1. starts a worker lcore that polls a net_null port (so gdb sees a
 *      "dpdk-worker1" thread and can break inside the PMD's eth_null_rx)
 *   2. allocates one mbuf, writes a recognisable payload, then CORRUPTS the
 *      header: data_len becomes larger than the buffer (a typical bug when
 *      someone adds a header without checking headroom/tailroom)
 *   3. asks rte_mbuf_check() what is wrong (it gives a reason string; the
 *      sibling rte_mbuf_sanity_check() would rte_panic itself)
 *   4. rte_panic(): prints the message and a backtrace (rte_dump_stack),
 *      then abort() -> SIGABRT -> a core file if ulimit -c allows it
 *
 * The interesting objects are globals so that gdb can find them by name in
 * a live process or in a core:  p *bad_mbuf,  p *bad_mbuf->pool,
 * x/16xb rte_pktmbuf_mtod(...)  ->  see crash_postmortem.sh.
 *
 *   ./panic_demo -l 0-1 --no-pci --no-huge -m 64 --file-prefix=ch13-gdb \
 *       --vdev=net_null0 [-- [--bursts N] [--no-panic] [--wait SECONDS]]
 */
#include <getopt.h>
#include <rte_debug.h>
#include "ch13_common.h"

/* globals on purpose: easy to find in gdb */
struct rte_mbuf *bad_mbuf;
struct rte_mempool *demo_pool;
static RTE_ATOMIC(uint64_t) worker_bursts;
static unsigned int want_bursts = 100;

static int
worker(void *arg __rte_unused)
{
	struct rte_mbuf *pkts[32];

	while (!ch13_quit) {
		uint16_t n = rte_eth_rx_burst(0, 0, pkts, 32);

		rte_pktmbuf_free_bulk(pkts, n);
		rte_atomic_fetch_add_explicit(&worker_bursts, 1,
					      rte_memory_order_relaxed);
	}
	return 0;
}

/* a separate, non-inlined function so it shows up as its own frame */
static void __rte_noinline
check_and_maybe_panic(struct rte_mbuf *m, bool do_panic)
{
	const char *reason = NULL;

	if (rte_mbuf_check(m, 1, &reason) == 0) {
		printf("mbuf %p passes rte_mbuf_check()\n", (void *)m);
		return;
	}
	printf("rte_mbuf_check(): %s (data_off=%u data_len=%u buf_len=%u pkt_len=%u)\n",
	       reason, m->data_off, m->data_len, m->buf_len, m->pkt_len);
	fflush(stdout);
	if (do_panic)
		rte_panic("corrupted mbuf %p from pool %s: %s\n",
			  (void *)m, m->pool->name, reason);
}

int
main(int argc, char **argv)
{
	static const struct option lo[] = {
		{"bursts", required_argument, NULL, 'b'},
		{"no-panic", no_argument, NULL, 'n'},
		{"wait", required_argument, NULL, 'w'},
		{NULL, 0, NULL, 0}
	};
	bool do_panic = true;
	unsigned int wait_s = 0;
	unsigned int lc;
	char *p;
	int ret, c;

	ret = rte_eal_init(argc, argv);
	if (ret < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	argc -= ret;
	argv += ret;
	while ((c = getopt_long(argc, argv, "", lo, NULL)) != -1) {
		if (c == 'b')
			want_bursts = atoi(optarg);
		else if (c == 'n')
			do_panic = false;
		else if (c == 'w')
			wait_s = atoi(optarg);
	}
	ch13_signals();

	demo_pool = rte_pktmbuf_pool_create("ch13_panic_pool", 511, 0, 0,
					    RTE_MBUF_DEFAULT_BUF_SIZE,
					    rte_socket_id());
	if (demo_pool == NULL || ch13_port_init(0, demo_pool, NULL, 128) < 0)
		rte_exit(EXIT_FAILURE, "pool/port init failed\n");

	lc = rte_get_next_lcore(-1, 1, 0);
	if (lc < RTE_MAX_LCORE)
		rte_eal_remote_launch(worker, NULL, lc);
	while (rte_atomic_load_explicit(&worker_bursts, rte_memory_order_relaxed)
	       < want_bursts && lc < RTE_MAX_LCORE)
		rte_pause();
	printf("worker on lcore %u did >= %u RX bursts\n", lc, want_bursts);

	/* a healthy mbuf with a payload we can recognise in a core dump */
	bad_mbuf = rte_pktmbuf_alloc(demo_pool);
	p = rte_pktmbuf_append(bad_mbuf, 64);
	memset(p, 0, 64);
	strcpy(p, "CH13-MARKER-PAYLOAD");
	printf("mbuf %p: pool=%s refcnt=%u data_len=%u, payload \"%s\"\n",
	       (void *)bad_mbuf, bad_mbuf->pool->name,
	       rte_mbuf_refcnt_read(bad_mbuf), bad_mbuf->data_len, p);
	check_and_maybe_panic(bad_mbuf, false);
	if (wait_s) {        /* time for a script to read /proc/<pid>/smaps */
		printf("pid %d waiting %u s\n", getpid(), wait_s);
		fflush(stdout);
		sleep(wait_s);
	}

	/* THE BUG: claim 4000 bytes in a 2176-byte buffer */
	bad_mbuf->data_len = 4000;
	bad_mbuf->pkt_len = 4000;
	check_and_maybe_panic(bad_mbuf, do_panic);

	/* only reached with --no-panic */
	ch13_quit = true;
	rte_eal_mp_wait_lcore();
	bad_mbuf->data_len = bad_mbuf->pkt_len = 64;
	rte_pktmbuf_free(bad_mbuf);
	rte_eth_dev_stop(0);
	rte_eth_dev_close(0);
	rte_eal_cleanup();
	return 0;
}
