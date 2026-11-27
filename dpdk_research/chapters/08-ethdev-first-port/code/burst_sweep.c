/* SPDX-License-Identifier: BSD-3-Clause
 *
 * burst_sweep.c - Chapter 8: how much does one rx_burst/tx_burst call cost,
 * and how much does each packet cost? Measures cycles per packet of a
 *     n = rte_eth_rx_burst(port, 0, pkts, B);
 *     rte_eth_tx_burst(port, 0, pkts, n);
 * loop on a net_null port for B = 1, 2, 4, ..., 128. net_null's rx allocates
 * B mbufs from the pool and its tx frees them, so the loop exercises the real
 * ethdev fast path (fp_ops lookup + indirect call) and the mempool, with no
 * wire and no NIC. Each burst size is run 5 times; we print the median, min
 * and max, then fit  cycles/pkt = a / B + c  (a = fixed cost per rx+tx call
 * pair, c = cost per packet) by least squares.
 *
 * These are software-PMD numbers on a VM: the *shape* (fixed cost amortised
 * by batching) is the lesson, not the absolute values. ch22 reuses this data.
 *
 * Run here:
 *   ./burst_sweep -l 0 --no-pci --no-huge -m 128 --file-prefix=ch08-sweep \
 *       --vdev=net_null0
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <inttypes.h>

#include <rte_eal.h>
#include <rte_errno.h>
#include <rte_ethdev.h>
#include <rte_cycles.h>
#include <rte_mbuf.h>

#define RUNS      5
#define PKTS_RUN  (2u * 1024 * 1024)   /* packets per measurement */
#define MAX_B     128

static int
cmp_double(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;
	return (x > y) - (x < y);
}

/* One measurement: cycles per packet for burst size b. */
static double
measure(uint16_t port, uint16_t b)
{
	struct rte_mbuf *pkts[MAX_B];
	uint64_t done = 0;

	/* warm-up: caches, branch predictors, mempool cache */
	for (int i = 0; i < 10000; i++) {
		uint16_t n = rte_eth_rx_burst(port, 0, pkts, b);
		uint16_t s = rte_eth_tx_burst(port, 0, pkts, n);
		if (s < n)
			rte_pktmbuf_free_bulk(&pkts[s], n - s);
	}

	uint64_t t0 = rte_rdtsc_precise();
	while (done < PKTS_RUN) {
		uint16_t n = rte_eth_rx_burst(port, 0, pkts, b);
		uint16_t s = rte_eth_tx_burst(port, 0, pkts, n);
		if (unlikely(s < n))                 /* never on net_null, but */
			rte_pktmbuf_free_bulk(&pkts[s], n - s);  /* always handle it */
		done += n;
	}
	uint64_t t1 = rte_rdtsc_precise();
	return (double)(t1 - t0) / done;
}

int
main(int argc, char **argv)
{
	static const uint16_t sizes[] = { 1, 2, 4, 8, 16, 32, 64, 128 };
	const int ns = RTE_DIM(sizes);
	double med[RTE_DIM(sizes)];
	uint16_t port = 0;

	int ret = rte_eal_init(argc, argv);
	if (ret < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed: %s\n", rte_strerror(rte_errno));
	if (rte_eth_dev_count_avail() < 1)
		rte_exit(EXIT_FAILURE, "need one port, e.g. --vdev=net_null0\n");

	struct rte_mempool *mp = rte_pktmbuf_pool_create("ch08_sweep", 4095, 256, 0,
			RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
	if (mp == NULL)
		rte_exit(EXIT_FAILURE, "pool: %s\n", rte_strerror(rte_errno));

	struct rte_eth_conf conf;
	memset(&conf, 0, sizeof(conf));
	if (rte_eth_dev_configure(port, 1, 1, &conf) != 0 ||
	    rte_eth_rx_queue_setup(port, 0, 1024, rte_eth_dev_socket_id(port), NULL, mp) != 0 ||
	    rte_eth_tx_queue_setup(port, 0, 1024, rte_eth_dev_socket_id(port), NULL) != 0 ||
	    rte_eth_dev_start(port) != 0)
		rte_exit(EXIT_FAILURE, "port setup failed\n");

	printf("TSC %.3f GHz, %u packets per run, %d runs per burst size, port %u (net_null)\n",
	       rte_get_tsc_hz() / 1e9, PKTS_RUN, RUNS, port);
	printf("%6s %12s %10s %10s %12s\n", "burst", "cyc/pkt med", "min", "max", "Mpps (med)");
	for (int i = 0; i < ns; i++) {
		double r[RUNS];
		for (int k = 0; k < RUNS; k++)
			r[k] = measure(port, sizes[i]);
		qsort(r, RUNS, sizeof(r[0]), cmp_double);
		med[i] = r[RUNS / 2];
		printf("%6u %12.2f %10.2f %10.2f %12.1f\n", sizes[i], med[i], r[0],
		       r[RUNS - 1], rte_get_tsc_hz() / med[i] / 1e6);
	}

	/* Least-squares fit of y = a*x + c with x = 1/B. */
	double sx = 0, sy = 0, sxx = 0, sxy = 0;
	for (int i = 0; i < ns; i++) {
		double x = 1.0 / sizes[i];
		sx += x; sy += med[i]; sxx += x * x; sxy += x * med[i];
	}
	double a = (ns * sxy - sx * sy) / (ns * sxx - sx * sx);
	double c = (sy - a * sx) / ns;
	printf("fit: cycles/pkt = %.1f / burst + %.1f   (fixed cost per rx+tx call pair ~%.0f cycles,"
	       " per-packet cost ~%.1f cycles)\n", a, c, a, c);
	printf("CSV burst,cyc_med\n");
	for (int i = 0; i < ns; i++)
		printf("CSV %u,%.2f\n", sizes[i], med[i]);

	rte_eth_dev_stop(port);
	rte_eth_dev_close(port);
	rte_mempool_free(mp);
	rte_eal_cleanup();
	return 0;
}
