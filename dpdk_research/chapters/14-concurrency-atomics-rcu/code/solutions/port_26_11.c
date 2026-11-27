/* SPDX-License-Identifier: BSD-3-Clause
 *
 * Chapter 14, exercise 1 solution: port pre-26.11 atomics and barriers.
 *
 * The "before" code (it no longer compiles in 26.11):
 *
 *     static rte_atomic32_t pkts;
 *     rte_atomic32_inc(&pkts);                      // (a) statistics
 *
 *     ring->slot[i] = m;                            // (b) hand a buffer to
 *     rte_smp_wmb();                                //     another lcore
 *     ring->tail = i + 1;
 *
 *     txd->addr = iova; txd->len = len;             // (c) give a descriptor
 *     rte_smp_wmb();                                //     to the NIC and ring
 *     *doorbell = tail;                             //     its doorbell
 *
 * The rule: who reads the data after the barrier?
 *   another CPU  -> C11 ordering: a release store (or rte_atomic_thread_fence)
 *   a device     -> rte_io_wmb() before the MMIO write, or rte_write32(),
 *                   which is rte_io_wmb() + rte_write32_relaxed()
 *
 * The "device" here is a plain memory word standing in for a BAR register,
 * so the program runs anywhere; on real hardware 'doorbell' would point
 * into the mapped PCI BAR (see ch23).
 *
 * Run: ./port_26_11 -l 0-1 --no-pci --no-huge -m 64 --file-prefix=ch14-port
 */
#include <stdio.h>
#include <stdlib.h>
#include <inttypes.h>

#include <rte_eal.h>
#include <rte_lcore.h>
#include <rte_launch.h>
#include <rte_pause.h>
#include <rte_debug.h>
#include <rte_atomic.h>
#include <rte_stdatomic.h>
#include <rte_io.h>

#define N 1000000

/* (a) a counter: if several lcores add to it, an atomic RMW (better: one
 * counter per lcore, see counters.c) */
static RTE_ATOMIC(uint32_t) pkts;

/* (b) a single-producer single-consumer hand-off between two lcores */
static struct {
	uint64_t slot[64];
	RTE_ATOMIC(uint32_t) tail;	/* written by producer only */
	RTE_ATOMIC(uint32_t) head;	/* written by consumer only */
} ring;

/* (c) a fake TX descriptor ring and doorbell register */
struct txd { uint64_t addr; uint32_t len; uint32_t flags; };
static struct txd txr[16];
static volatile uint32_t fake_bar_doorbell;	/* MMIO stand-in */

static int
consumer(void *arg)
{
	uint64_t sum = 0;
	(void)arg;
	for (uint32_t h = 0; h < N; h++) {
		/* acquire pairs with the producer's release store of tail */
		while (rte_atomic_load_explicit(&ring.tail, rte_memory_order_acquire) == h)
			rte_pause();
		sum += ring.slot[h % 64];	/* guaranteed to see the value */
		rte_atomic_store_explicit(&ring.head, h + 1, rte_memory_order_release);
	}
	printf("consumer: sum of %d items = %" PRIu64 " (expected %" PRIu64 ")\n",
	       N, sum, (uint64_t)N * (N - 1) / 2);
	return 0;
}

int
main(int argc, char **argv)
{
	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	unsigned int c = rte_get_next_lcore(-1, 1, 0);
	if (c >= RTE_MAX_LCORE)
		rte_exit(EXIT_FAILURE, "need 2 lcores\n");
	rte_eal_remote_launch(consumer, NULL, c);

	for (uint32_t i = 0; i < N; i++) {
		/* (a) rte_atomic32_inc(&pkts) becomes: */
		rte_atomic_fetch_add_explicit(&pkts, 1, rte_memory_order_relaxed);

		/* (b) wait for space, write the slot, publish with a RELEASE store
		 * (was: rte_smp_wmb(); ring->tail = i + 1;) */
		while (i - rte_atomic_load_explicit(&ring.head, rte_memory_order_acquire) >= 64)
			rte_pause();
		ring.slot[i % 64] = i;
		rte_atomic_store_explicit(&ring.tail, i + 1, rte_memory_order_release);
	}
	rte_eal_wait_lcore(c);

	/* (c) descriptor writes must reach memory before the device is told:
	 * a CPU-to-DEVICE barrier, not a CPU-to-CPU one */
	for (uint32_t t = 0; t < 4; t++) {
		txr[t].addr = 0x100000 + t * 2048;
		txr[t].len = 64;
		txr[t].flags = 1;
	}
	rte_write32(4, &fake_bar_doorbell);	/* = rte_io_wmb() + relaxed MMIO write */
	/* equivalent, spelled out:
	 *   rte_io_wmb();
	 *   rte_write32_relaxed(4, &fake_bar_doorbell);              */

	printf("pkts=%u, doorbell=%u, desc[3].addr=0x%" PRIx64 "\n",
	       rte_atomic_load_explicit(&pkts, rte_memory_order_relaxed),
	       rte_read32(&fake_bar_doorbell), txr[3].addr);
	rte_eal_cleanup();
	return 0;
}
