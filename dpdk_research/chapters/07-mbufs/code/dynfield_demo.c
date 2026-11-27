/* SPDX-License-Identifier: BSD-3-Clause
 *
 * Chapter 7, example 5: dynfield_demo.c
 *
 * struct rte_mbuf has 36 spare bytes (dynfield1[9]) and some spare bits
 * in ol_flags. Libraries, drivers and applications reserve pieces of them
 * at run time BY NAME:
 *   - rte_mbuf_dynfield_register()  -> a byte OFFSET inside struct rte_mbuf
 *   - rte_mbuf_dynflag_register()   -> a BIT NUMBER inside ol_flags
 * This program
 *   1. prints the empty map (rte_mbuf_dyn_dump)
 *   2. registers "ch07_latency_tsc" (uint64_t) and "ch07_sampled" (flag)
 *   3. registers the well-known Rx timestamp field+flag
 *   4. shows that registering the same name again returns the same offset,
 *      that a different size under the same name fails with EEXIST, and that
 *      lookup by name works
 *   5. stamps an mbuf and reads the values back through RTE_MBUF_DYNFIELD
 *   6. prints the map again
 *
 * Run: ./dynfield_demo -l 0 --no-pci --no-huge -m 64 --file-prefix=ch07-dyn
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <inttypes.h>

#include <rte_eal.h>
#include <rte_errno.h>
#include <rte_debug.h>
#include <rte_lcore.h>
#include <rte_cycles.h>
#include <rte_mbuf.h>
#include <rte_mbuf_dyn.h>

/* The registration results are runtime values: keep them in variables. */
static int      lat_off = -1;   /* byte offset of our uint64_t */
static uint64_t sampled_flag;   /* 1ULL << bit */
static int      ts_off = -1;    /* well-known timestamp field */
static uint64_t ts_rx_flag;

/* Typed accessors: the usual way to wrap RTE_MBUF_DYNFIELD */
static inline uint64_t *lat_field(struct rte_mbuf *m)
{
	return RTE_MBUF_DYNFIELD(m, lat_off, uint64_t *);
}

int main(int argc, char **argv)
{
	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");

	printf("== 1. before any registration ==\n");
	rte_mbuf_dyn_dump(stdout);

	printf("\n== 2. register our own field and flag ==\n");
	static const struct rte_mbuf_dynfield lat_desc = {
		.name  = "ch07_latency_tsc",      /* app names must not start with rte_ */
		.size  = sizeof(uint64_t),
		.align = alignof(uint64_t),
	};
	lat_off = rte_mbuf_dynfield_register(&lat_desc);
	if (lat_off < 0)
		rte_exit(EXIT_FAILURE, "dynfield: %s\n", rte_strerror(rte_errno));

	static const struct rte_mbuf_dynflag sampled_desc = { .name = "ch07_sampled" };
	int bit = rte_mbuf_dynflag_register(&sampled_desc);
	if (bit < 0)
		rte_exit(EXIT_FAILURE, "dynflag: %s\n", rte_strerror(rte_errno));
	sampled_flag = RTE_BIT64(bit);
	printf("ch07_latency_tsc -> offset %d (inside dynfield1, which starts at %zu)\n",
	       lat_off, offsetof(struct rte_mbuf, dynfield1));
	printf("ch07_sampled     -> ol_flags bit %d (mask 0x%016" PRIx64 ")\n",
	       bit, sampled_flag);

	printf("\n== 3. the well-known Rx timestamp (used by PMDs, ch19/ch22) ==\n");
	if (rte_mbuf_dyn_rx_timestamp_register(&ts_off, &ts_rx_flag) != 0)
		rte_exit(EXIT_FAILURE, "ts: %s\n", rte_strerror(rte_errno));
	printf("%s -> offset %d, %s -> mask 0x%016" PRIx64 " (bit %d)\n",
	       RTE_MBUF_DYNFIELD_TIMESTAMP_NAME, ts_off,
	       RTE_MBUF_DYNFLAG_RX_TIMESTAMP_NAME, ts_rx_flag,
	       rte_ctz64(ts_rx_flag));
	/* The Tx timestamp (time a PMD should send the packet at) SHARES the
	 * same field but gets its own flag. */
	int tx_off = -1;
	uint64_t ts_tx_flag = 0;
	if (rte_mbuf_dyn_tx_timestamp_register(&tx_off, &ts_tx_flag) != 0)
		rte_exit(EXIT_FAILURE, "tx ts: %s\n", rte_strerror(rte_errno));
	printf("tx timestamp   -> offset %d (same field), %s -> bit %d\n",
	       tx_off, RTE_MBUF_DYNFLAG_TX_TIMESTAMP_NAME, rte_ctz64(ts_tx_flag));

	printf("\n== 4. same name again / conflicting / lookup ==\n");
	int again = rte_mbuf_dynfield_register(&lat_desc);
	printf("register same name+params again -> %d (same offset)\n", again);
	struct rte_mbuf_dynfield bad = lat_desc;
	bad.size = 4;
	int r = rte_mbuf_dynfield_register(&bad);
	printf("same name, size 4               -> %d, rte_errno=%s\n",
	       r, r < 0 ? rte_strerror(rte_errno) : "-");
	struct rte_mbuf_dynfield found;
	/* separate statement: found.size must be read AFTER the call fills it
	 * (inside one printf the argument order is unspecified) */
	r = rte_mbuf_dynfield_lookup("ch07_latency_tsc", &found);
	printf("lookup(\"ch07_latency_tsc\")      -> %d (size %zu)\n", r, found.size);
	r = rte_mbuf_dynfield_lookup("no_such_field", NULL);
	printf("lookup(\"no_such_field\")         -> %d, rte_errno=%s\n",
	       r, rte_strerror(rte_errno));

	printf("\n== 5. use them on an mbuf ==\n");
	struct rte_mempool *mp = rte_pktmbuf_pool_create("ch07_dyn", 63, 0, 0,
			RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
	if (mp == NULL)
		rte_exit(EXIT_FAILURE, "pool: %s\n", rte_strerror(rte_errno));
	struct rte_mbuf *m = rte_pktmbuf_alloc(mp);

	uint64_t t0 = rte_rdtsc();
	*lat_field(m) = t0;                       /* "stamped at RX" */
	m->ol_flags |= sampled_flag;              /* mark it */
	*RTE_MBUF_DYNFIELD(m, ts_off, rte_mbuf_timestamp_t *) = 123456789;
	m->ol_flags |= ts_rx_flag;

	rte_delay_us_block(50);                    /* "processing" */

	if (m->ol_flags & sampled_flag)
		printf("sampled packet: %" PRIu64 " TSC cycles since stamp "
		       "(~%.0f us at %" PRIu64 " Hz)\n",
		       rte_rdtsc() - *lat_field(m),
		       (double)(rte_rdtsc() - *lat_field(m)) * 1e6 / rte_get_tsc_hz(),
		       rte_get_tsc_hz());
	if (m->ol_flags & ts_rx_flag)
		printf("rx timestamp field = %" PRIu64 "\n",
		       *RTE_MBUF_DYNFIELD(m, ts_off, rte_mbuf_timestamp_t *));

	/* rte_pktmbuf_reset clears ol_flags but NOT the dynfield bytes:
	 * the flag is what says whether the field is valid. */
	rte_pktmbuf_reset(m);
	printf("after reset: sampled flag=%d, field bytes still %s\n",
	       (m->ol_flags & sampled_flag) != 0,
	       *lat_field(m) == t0 ? "hold the old value (stale!)" : "changed");

	printf("\n== 6. after registration ==\n");
	rte_mbuf_dyn_dump(stdout);

	rte_pktmbuf_free(m);
	rte_mempool_free(mp);
	rte_eal_cleanup();
	return 0;
}
