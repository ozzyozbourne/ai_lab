/* SPDX-License-Identifier: BSD-3-Clause
 * Chapter 13: latency_metrics.c - latency, bitrate and your own metrics,
 * published through rte_metrics and read back through a telemetry endpoint.
 *
 * Three libraries cooperate here:
 *
 *   lib/metrics       a small name -> value table in shared memory (a
 *                     memzone), one row per port plus one "global" row.
 *                     Producers call rte_metrics_update_value(s); consumers
 *                     call rte_metrics_get_names/get_values.
 *   lib/latencystats  installs an RX callback that stamps a sample packet
 *                     with the TSC, and a TX callback that computes
 *                     "now - stamp" when that packet leaves. It writes
 *                     min/avg/max/jitter (ns) into the GLOBAL metrics row
 *                     when you call rte_latencystats_update().
 *   lib/bitratestats  rte_stats_bitrate_calc() reads rte_eth_stats_get()
 *                     and writes ewma/mean/peak bits per second into the
 *                     port's metrics row. You call it once per second.
 *
 * In 26.11 rte_metrics has no telemetry glue any more (rte_metrics_tel_*
 * and rte_metrics_telemetry.h were removed), so this program registers its
 * own endpoint, /ch13/latency, that dumps the metrics table as JSON.
 *
 * Traffic: two net_null ports. net_null RX hands out a burst of FRESH mbufs
 * on every call and net_null TX frees them, like a NIC on a busy wire. The
 * loop forwards p0 -> p1 and p1 -> p0. --work-ns N spins N ns per received
 * burst to simulate packet processing: the measured latency grows by N.
 *
 * The same binary also runs on two net_ring ports (a loopback: TX comes back
 * on its own RX). It then injects 256 frames that circulate forever. That
 * is the "pitfall" run of the chapter: the SAME mbuf is re-received with
 * its timestamp flag still set, so latencystats measures the packet's age
 * since its first RX, and the "latency" grows with the run time.
 *
 *   ./latency_metrics -l 0 --no-pci --no-huge -m 128 --file-prefix=ch13-lat \
 *       --vdev=net_null0 --vdev=net_null1 -- [--seconds N] [--work-ns N]
 */
#include <getopt.h>
#include <rte_metrics.h>
#include <rte_latencystats.h>
#include <rte_bitrate.h>
#include <rte_telemetry.h>
#include "ch13_common.h"

#define BURST 32
#define MAX_M RTE_METRICS_MAX_METRICS

static unsigned int seconds = 3;
static uint64_t work_ns;
static int app_key;            /* key of our own metric "ch13_work_ns" */

/* ---- /ch13/latency: the metrics table as JSON ------------------------ */
/* One dict per metrics row ("global", "port0", "port1"), skipping zeros
 * so the reply stays short. Runs on the telemetry thread; the metrics
 * library protects its table with a spinlock, so this is safe. */
static void
add_row(struct rte_tel_data *d, const char *row, int port,
	const struct rte_metric_name *names, int nnames)
{
	struct rte_metric_value vals[MAX_M];
	struct rte_tel_data *rd = rte_tel_data_alloc();
	int i, n;

	if (rd == NULL)
		return;
	rte_tel_data_start_dict(rd);
	n = rte_metrics_get_values(port, vals, MAX_M);
	for (i = 0; i < n; i++)
		if (vals[i].key < nnames && vals[i].value != 0)
			rte_tel_data_add_dict_uint(rd, names[vals[i].key].name,
						   vals[i].value);
	rte_tel_data_add_dict_container(d, row, rd, 0);
}

static int
tel_latency(const char *cmd __rte_unused, const char *params __rte_unused,
	    struct rte_tel_data *d)
{
	static struct rte_metric_name names[MAX_M];
	int n = rte_metrics_get_names(names, MAX_M);
	uint16_t p;

	if (n < 0)
		return n;
	rte_tel_data_start_dict(d);
	add_row(d, "global", RTE_METRICS_GLOBAL, names, n);
	RTE_ETH_FOREACH_DEV(p) {
		char row[16];

		snprintf(row, sizeof(row), "port%u", p);
		add_row(d, row, p, names, n);
	}
	return 0;
}

/* Print the same table from the application side. */
static void
print_metrics(void)
{
	struct rte_metric_name names[MAX_M];
	struct rte_metric_value vals[MAX_M];
	int n = rte_metrics_get_names(names, MAX_M), i, k;
	int port;

	printf("rte_metrics: %d names registered\n", n);
	for (port = RTE_METRICS_GLOBAL; port < 2; port++) {
		k = rte_metrics_get_values(port, vals, MAX_M);
		printf("  %-7s", port < 0 ? "global" : port ? "port1" : "port0");
		for (i = 0; i < k; i++)
			if (vals[i].value)
				printf(" %s=%" PRIu64, names[vals[i].key].name,
				       vals[i].value);
		printf("\n");
	}
}

static void
spin_ns(uint64_t ns)
{
	uint64_t end = rte_rdtsc() + ns * rte_get_tsc_hz() / 1000000000ULL;

	while (rte_rdtsc() < end)
		rte_pause();
}

int
main(int argc, char **argv)
{
	static const struct option lo[] = {
		{"seconds", required_argument, NULL, 's'},
		{"work-ns", required_argument, NULL, 'w'},
		{NULL, 0, NULL, 0}
	};
	struct rte_stats_bitrates *br;
	struct rte_mempool *pool;
	struct rte_mbuf *pkts[BURST];
	uint64_t hz, next_lat, next_br, end;
	uint16_t p;
	int ret, c;

	ret = rte_eal_init(argc, argv);
	if (ret < 0)
		rte_exit(EXIT_FAILURE, "EAL init: %s\n", rte_strerror(rte_errno));
	argc -= ret;
	argv += ret;
	while ((c = getopt_long(argc, argv, "", lo, NULL)) != -1) {
		if (c == 's')
			seconds = atoi(optarg);
		else if (c == 'w')
			work_ns = strtoull(optarg, NULL, 0);
		else
			rte_exit(EXIT_FAILURE, "usage: -- [--seconds N] [--work-ns N]\n");
	}
	ch13_signals();
	if (rte_eth_dev_count_avail() != 2)
		rte_exit(EXIT_FAILURE, "need --vdev=net_ring0 --vdev=net_ring1\n");

	pool = rte_pktmbuf_pool_create("ch13_lat_pool", 2047, 32, 0,
				       RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
	if (pool == NULL)
		rte_exit(EXIT_FAILURE, "pool: %s\n", rte_strerror(rte_errno));
	for (p = 0; p < 2; p++)
		if (ch13_port_init(p, pool, NULL, 512) < 0)
			rte_exit(EXIT_FAILURE, "port %u init failed\n", p);

	/* 1. the metrics table must exist before anybody registers names */
	rte_metrics_init(rte_socket_id());
	app_key = rte_metrics_reg_name("ch13_work_ns");

	/* 2. latency stats: sample one packet every 10 us. Call it AFTER the
	 * queues are set up: it adds callbacks to the queues that exist now. */
	ret = rte_latencystats_init(10000, NULL);
	printf("rte_latencystats_init -> %d\n", ret);

	/* 3. bitrate stats: one object, registered once, computed per port */
	br = rte_stats_bitrate_create();
	if (br == NULL || rte_stats_bitrate_reg(br) < 0)
		rte_exit(EXIT_FAILURE, "bitrate init failed\n");

	rte_telemetry_register_cmd("/ch13/latency", tel_latency,
		"rte_metrics table (latency, bitrate, ch13_work_ns). No parameters");
	rte_metrics_update_value(RTE_METRICS_GLOBAL, app_key, work_ns);

	{
		struct rte_eth_dev_info di;

		if (rte_eth_dev_info_get(0, &di) != 0)
			rte_exit(EXIT_FAILURE, "dev_info failed\n");
		if (strcmp(di.driver_name, "net_ring") == 0)
			printf("net_ring loopback: injected %u frames on port 0\n",
			       ch13_inject(0, pool, 256, 64));
		printf("driver %s, work per burst %" PRIu64 " ns\n",
		       di.driver_name, work_ns);
	}
	printf("READY\n");
	fflush(stdout);

	hz = rte_get_tsc_hz();
	next_lat = rte_rdtsc() + hz / 10;
	next_br = rte_rdtsc() + hz;
	end = rte_rdtsc() + seconds * hz;
	while (!ch13_quit && rte_rdtsc() < end) {
		uint64_t now;

		for (p = 0; p < 2; p++) {
			uint16_t n = rte_eth_rx_burst(p, 0, pkts, BURST), s;

			if (n == 0)
				continue;
			if (work_ns)
				spin_ns(work_ns);     /* "processing" */
			s = rte_eth_tx_burst(p ^ 1, 0, pkts, n);
			if (s < n)
				rte_pktmbuf_free_bulk(&pkts[s], n - s);
		}
		now = rte_rdtsc();
		if (now >= next_lat) {        /* 10 Hz: publish latency */
			rte_latencystats_update();
			next_lat = now + hz / 10;
		}
		if (now >= next_br) {         /* 1 Hz: bitrate per port */
			for (p = 0; p < 2; p++)
				rte_stats_bitrate_calc(br, p);
			next_br = now + hz;
		}
	}
	rte_latencystats_update();
	print_metrics();

	/* the typed getter of lib/latencystats, same numbers */
	{
		struct rte_metric_name nm[8];
		struct rte_metric_value v[8];
		int i, n = rte_latencystats_get_names(nm, 8);

		rte_latencystats_get(v, 8);
		printf("rte_latencystats_get:");
		for (i = 0; i < n; i++)
			printf(" %s=%" PRIu64, nm[i].name, v[i].value);
		printf("\n");
	}

	rte_latencystats_uninit();        /* removes the RX/TX callbacks */
	rte_stats_bitrate_free(br);
	for (p = 0; p < 2; p++) {
		rte_eth_dev_stop(p);
		rte_eth_dev_close(p);
	}
	rte_metrics_deinit();
	rte_eal_cleanup();
	return 0;
}
