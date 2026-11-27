/* SPDX-License-Identifier: BSD-3-Clause
 * bypass_bench.c - PEEK AHEAD for chapter 01 (you can write this yourself
 * after ch8). Run it and look at the numbers; do not worry about every API.
 *
 * Question: what does it cost to move ONE small packet
 *   (a) through the Linux kernel: sendto() + recv() of a 64-byte UDP
 *       datagram on the loopback interface (two system calls, two copies,
 *       the whole UDP/IP stack, socket queues), versus
 *   (b) through DPDK: rte_eth_rx_burst() + rte_eth_tx_burst() on a net_null
 *       port (no syscalls, no copies, packets handled in bursts)?
 *
 * HONEST CAVEAT: net_null is a software PMD that does no real I/O. Its Rx
 * just takes mbufs from the mempool and its Tx frees them. So (b) measures the
 * DPDK *framework* cost (burst dispatch + mempool), not a NIC. Real NIC
 * numbers come in ch22.
 *
 * Each measurement is repeated RUNS times; we print median, min and max.
 *
 * Usage: ./bypass_bench <EAL args> --vdev=net_null0 [-- burst1 burst2 ...]
 *        default burst list: 32
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/socket.h>

#include <rte_eal.h>
#include <rte_debug.h>
#include <rte_lcore.h>
#include <rte_ethdev.h>
#include <rte_mbuf.h>
#include <rte_cycles.h>

#define RUNS      5
#define KERNEL_N  200000    /* datagrams per kernel run */
#define DPDK_N    5000000   /* packets per DPDK run     */
#define MAX_BURST 256

static int cmp_double(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;
	return (x > y) - (x < y);
}

/* print "label: median ns/pkt (min..max), cycles/pkt, Mpps" */
static void report(const char *label, double ns[RUNS], double hz)
{
	qsort(ns, RUNS, sizeof(double), cmp_double);
	double med = ns[RUNS / 2];
	printf("%-34s %8.1f ns/pkt  (min %.1f, max %.1f)  %7.0f cycles/pkt  %7.2f Mpps\n",
	       label, med, ns[0], ns[RUNS - 1], med * hz / 1e9, 1e3 / med);
}

/* (a) kernel path: one sendto() and one recv() per 64-byte datagram */
static double kernel_run(int tx, int rx, struct sockaddr_in *dst, double hz)
{
	char buf[64] = {0}, in[2048];
	uint64_t t0 = rte_rdtsc();
	for (int i = 0; i < KERNEL_N; i++) {
		if (sendto(tx, buf, sizeof(buf), 0, (struct sockaddr *)dst,
			   sizeof(*dst)) != sizeof(buf))
			rte_exit(EXIT_FAILURE, "sendto failed\n");
		if (recv(rx, in, sizeof(in), 0) != sizeof(buf))
			rte_exit(EXIT_FAILURE, "recv failed\n");
	}
	return (rte_rdtsc() - t0) / hz * 1e9 / KERNEL_N;
}

/* (b) DPDK path: receive a burst from net_null, send the same burst back */
static double dpdk_run(uint16_t port, unsigned int burst, double hz)
{
	struct rte_mbuf *pkts[MAX_BURST];
	uint64_t rx = 0;
	uint64_t t0 = rte_rdtsc();
	while (rx < DPDK_N) {
		uint16_t n = rte_eth_rx_burst(port, 0, pkts, burst);
		uint16_t sent = rte_eth_tx_burst(port, 0, pkts, n);
		/* tx_burst may accept fewer than n: we still own the rest */
		if (sent < n)
			rte_pktmbuf_free_bulk(&pkts[sent], n - sent);
		rx += n;
	}
	return (rte_rdtsc() - t0) / hz * 1e9 / rx;
}

int main(int argc, char **argv)
{
	int ret = rte_eal_init(argc, argv);
	if (ret < 0)
		rte_exit(EXIT_FAILURE, "rte_eal_init failed\n");
	argc -= ret;
	argv += ret;
	double hz = rte_get_tsc_hz();
	double ns[RUNS];

	printf("TSC %.2f GHz, %d runs per measurement, 64-byte packets\n",
	       hz / 1e9, RUNS);

	/* ---------- (a) the kernel path ---------- */
	int rx = socket(AF_INET, SOCK_DGRAM, 0);
	int tx = socket(AF_INET, SOCK_DGRAM, 0);
	struct sockaddr_in a = { .sin_family = AF_INET,
				 .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
	socklen_t alen = sizeof(a);
	if (rx < 0 || tx < 0 || bind(rx, (struct sockaddr *)&a, sizeof(a)) ||
	    getsockname(rx, (struct sockaddr *)&a, &alen))  /* learn our port */
		rte_exit(EXIT_FAILURE, "socket setup failed\n");
	for (int r = 0; r < RUNS; r++)
		ns[r] = kernel_run(tx, rx, &a, hz);
	report("kernel sendto()+recv() 127.0.0.1", ns, hz);
	close(tx);
	close(rx);

	/* ---------- (b) the DPDK path ---------- */
	if (rte_eth_dev_count_avail() < 1)
		rte_exit(EXIT_FAILURE, "need a port: --vdev=net_null0\n");
	uint16_t port = 0;
	struct rte_mempool *mp = rte_pktmbuf_pool_create("bb_pool", 8191, 256,
				0, RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
	struct rte_eth_conf conf;
	memset(&conf, 0, sizeof(conf));
	if (mp == NULL ||
	    rte_eth_dev_configure(port, 1, 1, &conf) != 0 ||
	    rte_eth_rx_queue_setup(port, 0, 512, rte_socket_id(), NULL, mp) != 0 ||
	    rte_eth_tx_queue_setup(port, 0, 512, rte_socket_id(), NULL) != 0 ||
	    rte_eth_dev_start(port) != 0)
		rte_exit(EXIT_FAILURE, "port setup failed\n");

	int nb = argc > 1 ? argc - 1 : 1;
	for (int i = 0; i < nb; i++) {
		unsigned int burst = argc > 1 ? (unsigned int)atoi(argv[i + 1]) : 32;
		char label[64];
		if (burst < 1 || burst > MAX_BURST)
			rte_exit(EXIT_FAILURE, "burst must be 1..%d\n", MAX_BURST);
		dpdk_run(port, burst, hz);  /* warm-up: fill the mempool cache */
		for (int r = 0; r < RUNS; r++)
			ns[r] = dpdk_run(port, burst, hz);
		snprintf(label, sizeof(label), "dpdk rx+tx burst=%u (net_null)", burst);
		report(label, ns, hz);
	}

	rte_eth_dev_stop(port);
	rte_eth_dev_close(port);
	rte_mempool_free(mp);
	rte_eal_cleanup();
	return 0;
}
