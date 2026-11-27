/* SPDX-License-Identifier: BSD-3-Clause
 *
 * ring_cable.c - Chapter 8: two ethdev ports joined by a "cable" made of two
 * rte_rings, built with rte_eth_from_rings() (drivers/net/ring/rte_eth_ring.h).
 *
 *        port A  tx ---> ring "A2B" ---> rx  port B
 *        port A  rx <--- ring "B2A" <--- tx  port B
 *
 * Part 1: send 3 bursts of numbered packets A -> B, receive them on B and
 *         check that every sequence number arrives once and in order.
 * Part 2: fill the cable. The ring holds only CABLE_SLOTS-1 packets, so
 *         rte_eth_tx_burst() accepts fewer than asked. The unsent tail still
 *         belongs to the application, which must free (or retry) it.
 *         We print the mempool before and after to show nothing leaked.
 * Part 3 (--leak, exercise 2): do the same, but "forget" to free the unsent
 *         tail, round after round, and watch the pool drain until
 *         allocation fails.
 *
 * Run here:
 *   ./ring_cable -l 0 --no-pci --no-huge -m 128 --file-prefix=ch08-cable
 *   ./ring_cable -l 0 --no-pci --no-huge -m 128 --file-prefix=ch08-cable -- --leak
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <inttypes.h>

#include <rte_eal.h>
#include <rte_errno.h>
#include <rte_ethdev.h>
#include <rte_eth_ring.h>
#include <rte_ring.h>
#include <rte_mbuf.h>
#include <rte_ether.h>

#define CABLE_SLOTS 64      /* ring size: usable capacity is 63 */
#define NB_MBUFS    511
#define BURST       32

static uint32_t next_seq;

/* Allocate n frames and stamp a sequence number right after the Ethernet
 * header. Returns how many were made (0 if the pool is empty). */
static unsigned
make_numbered(struct rte_mempool *mp, struct rte_mbuf **pkts, unsigned n)
{
	if (rte_pktmbuf_alloc_bulk(mp, pkts, n) != 0)
		return 0;
	for (unsigned i = 0; i < n; i++) {
		char *p = rte_pktmbuf_append(pkts[i], 64);
		struct rte_ether_hdr *eh = (struct rte_ether_hdr *)p;
		memset(p, 0, 64);
		memset(&eh->dst_addr, 0xff, RTE_ETHER_ADDR_LEN);
		eh->ether_type = rte_cpu_to_be_16(0x88B5);
		uint32_t seq = next_seq++;
		memcpy(p + sizeof(*eh), &seq, sizeof(seq));
	}
	return n;
}

static uint32_t
seq_of(struct rte_mbuf *m)
{
	uint32_t seq;
	memcpy(&seq, rte_pktmbuf_mtod_offset(m, char *, sizeof(struct rte_ether_hdr)),
	       sizeof(seq));
	return seq;
}

static void
port_up(uint16_t port, struct rte_mempool *mp)
{
	struct rte_eth_conf conf;
	memset(&conf, 0, sizeof(conf));
	/* nb_desc is ignored by net_ring: the ring size was fixed at creation. */
	if (rte_eth_dev_configure(port, 1, 1, &conf) != 0 ||
	    rte_eth_rx_queue_setup(port, 0, CABLE_SLOTS, SOCKET_ID_ANY, NULL, mp) != 0 ||
	    rte_eth_tx_queue_setup(port, 0, CABLE_SLOTS, SOCKET_ID_ANY, NULL) != 0 ||
	    rte_eth_dev_start(port) != 0)
		rte_exit(EXIT_FAILURE, "port %u setup failed\n", port);
}

static void
pool_line(const char *when, struct rte_mempool *mp, struct rte_ring *cable)
{
	printf("  %-28s pool avail=%3u in-use=%3u   cable A2B holds %u\n", when,
	       rte_mempool_avail_count(mp), rte_mempool_in_use_count(mp),
	       rte_ring_count(cable));
}

int
main(int argc, char **argv)
{
	struct rte_mbuf *pkts[128], *rx[BURST];
	int leak = 0;

	int ret = rte_eal_init(argc, argv);
	if (ret < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed: %s\n", rte_strerror(rte_errno));
	for (int i = ret + 1; i < argc; i++)
		if (strcmp(argv[i], "--leak") == 0)
			leak = 1;

	/* Cache 0 so avail_count is exact (no mbufs parked in lcore caches). */
	struct rte_mempool *mp = rte_pktmbuf_pool_create("ch08_cable", NB_MBUFS, 0, 0,
			RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
	/* Single producer / single consumer: one lcore drives both ends. */
	struct rte_ring *a2b = rte_ring_create("A2B", CABLE_SLOTS, rte_socket_id(),
					       RING_F_SP_ENQ | RING_F_SC_DEQ);
	struct rte_ring *b2a = rte_ring_create("B2A", CABLE_SLOTS, rte_socket_id(),
					       RING_F_SP_ENQ | RING_F_SC_DEQ);
	if (mp == NULL || a2b == NULL || b2a == NULL)
		rte_exit(EXIT_FAILURE, "create failed: %s\n", rte_strerror(rte_errno));

	/* Port A receives from B2A and transmits into A2B; port B the reverse. */
	int pa = rte_eth_from_rings("cableA", &b2a, 1, &a2b, 1, rte_socket_id());
	int pb = rte_eth_from_rings("cableB", &a2b, 1, &b2a, 1, rte_socket_id());
	if (pa < 0 || pb < 0)
		rte_exit(EXIT_FAILURE, "rte_eth_from_rings failed\n");
	printf("ports: A=%d (cableA)  B=%d (cableB), cable capacity %u packets\n",
	       pa, pb, rte_ring_get_capacity(a2b));
	port_up(pa, mp);
	port_up(pb, mp);

	/* ---------------- Part 1: in-order delivery ------------------------- */
	printf("\nPart 1: 3 bursts of %d numbered packets A -> B\n", BURST);
	uint32_t expect = 0, bad = 0, got = 0;
	for (int b = 0; b < 3; b++) {
		unsigned n = make_numbered(mp, pkts, BURST);
		uint16_t sent = rte_eth_tx_burst(pa, 0, pkts, n);
		if (sent < n)
			rte_pktmbuf_free_bulk(&pkts[sent], n - sent);
		uint16_t r = rte_eth_rx_burst(pb, 0, rx, BURST);
		for (uint16_t i = 0; i < r; i++) {
			if (seq_of(rx[i]) != expect)
				bad++;
			expect = seq_of(rx[i]) + 1;
		}
		printf("  burst %d: tx_burst accepted %u/%u, B rx_burst got %u (seq %u..%u)\n",
		       b, sent, n, r, r ? seq_of(rx[0]) : 0, r ? seq_of(rx[r - 1]) : 0);
		got += r;
		rte_pktmbuf_free_bulk(rx, r);
	}
	printf("  received %u, out-of-order %u\n", got, bad);

	/* ---------------- Part 2: a full cable --------------------------- */
	printf("\nPart 2: send 100 packets without reading the other end\n");
	pool_line("before:", mp, a2b);
	unsigned n = make_numbered(mp, pkts, 100);
	uint16_t sent = rte_eth_tx_burst(pa, 0, pkts, n);
	printf("  tx_burst(100) accepted %u; pkts[%u..%u] are still OURS\n",
	       sent, sent, n - 1);
	pool_line("after tx, before free:", mp, a2b);
	rte_pktmbuf_free_bulk(&pkts[sent], n - sent);     /* the correct thing */
	pool_line("after freeing the tail:", mp, a2b);
	/* Drain the cable on B so its mbufs go home too. */
	unsigned drained = 0;
	uint16_t r;
	while ((r = rte_eth_rx_burst(pb, 0, rx, BURST)) > 0) {
		drained += r;
		rte_pktmbuf_free_bulk(rx, r);
	}
	printf("  B drained %u packets\n", drained);
	pool_line("after draining B:", mp, a2b);

	/* ---------------- Part 3: the leak (exercise 2) -------------------- */
	if (leak) {
		printf("\nPart 3 (--leak): same as part 2 but never free the unsent tail\n");
		for (int round = 1; round <= 20; round++) {
			n = make_numbered(mp, pkts, 100);
			if (n == 0) {
				printf("  round %2d: rte_pktmbuf_alloc_bulk(100) FAILED - pool exhausted\n",
				       round);
				break;
			}
			sent = rte_eth_tx_burst(pa, 0, pkts, n);
			/* BUG on purpose: pkts[sent..n-1] are dropped on the floor. */
			while ((r = rte_eth_rx_burst(pb, 0, rx, BURST)) > 0)
				rte_pktmbuf_free_bulk(rx, r);
			printf("  round %2d: sent %u, leaked %2u   pool avail=%3u in-use=%3u\n",
			       round, sent, n - sent, rte_mempool_avail_count(mp),
			       rte_mempool_in_use_count(mp));
		}
	}

	/* Shutdown. net_ring does not free mbufs still sitting in a ring on
	 * stop, so drain first (done above). */
	rte_eth_dev_stop(pa);
	rte_eth_dev_stop(pb);
	rte_eth_dev_close(pa);
	rte_eth_dev_close(pb);
	printf("\nend: pool avail=%u of %u%s\n", rte_mempool_avail_count(mp), NB_MBUFS,
	       rte_mempool_avail_count(mp) == NB_MBUFS ? " (no leak)" : " (LEAK)");
	rte_ring_free(a2b);
	rte_ring_free(b2a);
	rte_mempool_free(mp);
	rte_eal_cleanup();
	return 0;
}
