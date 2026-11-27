/* SPDX-License-Identifier: BSD-3-Clause
 * Chapter 13: telemetry_app.c - make a running forwarder observable.
 *
 * A worker lcore forwards between two net_null ports (port 0 -> port 1 and
 * port 1 -> port 0). The program adds three things that a monitoring system
 * can read through the telemetry socket while it runs:
 *
 *   1. /ch13/stats   a custom endpoint (rte_telemetry_register_cmd) that
 *                    returns the forwarder's own counters as a JSON dict,
 *                    with a nested dict per port (rte_tel_data_alloc +
 *                    rte_tel_data_add_dict_container)
 *   2. /ch13/echo    an endpoint that shows how parameters arrive
 *                    ("/ch13/echo,hello" -> params = "hello")
 *   3. an lcore usage callback (rte_lcore_register_usage_cb) so that the
 *      built-in /eal/lcore/usage endpoint and rte_lcore_dump() can report
 *      how busy the worker is. Without it /eal/lcore/usage is empty.
 *
 * net_null RX never runs dry, so to make "busy" mean something the worker
 * is paced: it polls the ports only --rate times per second and spends the
 * rest of the time in idle polls, the way a real forwarder waits for
 * traffic. Busy cycles = cycles spent in iterations that moved packets.
 *
 * Usage:
 *   ./telemetry_app -l 0-1 --no-pci --no-huge -m 128 --file-prefix=ch13-tel \
 *       --vdev=net_null0 --vdev=net_null1 -- [--seconds N] [--rate BURSTS_PER_S]
 */
#include <getopt.h>
#include <rte_telemetry.h>
#include "ch13_common.h"

#define BURST 32

/* Counters with ONE writer (the worker) and readers on the telemetry
 * thread. Relaxed atomic load+store is enough for a single writer
 * (chapter 14 explains why plain "+=" would be a data race in C). */
struct __rte_cache_aligned port_ctr {
	RTE_ATOMIC(uint64_t) rx;
	RTE_ATOMIC(uint64_t) tx;
	RTE_ATOMIC(uint64_t) drop;
};

struct __rte_cache_aligned worker_ctr {
	RTE_ATOMIC(uint64_t) busy_polls;   /* iterations that moved packets */
	RTE_ATOMIC(uint64_t) idle_polls;   /* iterations that did nothing   */
	RTE_ATOMIC(uint64_t) busy_cycles;  /* TSC cycles spent in busy polls */
	uint64_t start_tsc;                /* written once before launch     */
	unsigned int lcore;
};

static struct port_ctr pctr[2];
static struct worker_ctr wctr;
static uint64_t rate = 20000;          /* busy polls per second */
static unsigned int seconds;

static inline void
add(RTE_ATOMIC(uint64_t) *c, uint64_t n)
{
	rte_atomic_store_explicit(c,
		rte_atomic_load_explicit(c, rte_memory_order_relaxed) + n,
		rte_memory_order_relaxed);
}

static inline uint64_t
get(RTE_ATOMIC(uint64_t) *c)
{
	return rte_atomic_load_explicit(c, rte_memory_order_relaxed);
}

/* ---- 1. the custom endpoint ------------------------------------------ */
/*
 * Runs on the telemetry thread ("dpdk-telemet-v2" spawns one pthread per
 * client connection), NOT on an lcore. It must only read shared state in a
 * thread-safe way, must be quick, and its JSON must fit in 16 KB.
 * Return 0 on success; a negative value makes the client see null.
 */
static int
tel_stats(const char *cmd __rte_unused, const char *params __rte_unused,
	  struct rte_tel_data *d)
{
	uint64_t hz = rte_get_tsc_hz();
	uint16_t p;

	rte_tel_data_start_dict(d);
	rte_tel_data_add_dict_uint(d, "worker_lcore", wctr.lcore);
	rte_tel_data_add_dict_uint(d, "uptime_ms",
		(rte_rdtsc() - wctr.start_tsc) * 1000 / hz);
	rte_tel_data_add_dict_uint(d, "busy_polls", get(&wctr.busy_polls));
	rte_tel_data_add_dict_uint(d, "idle_polls", get(&wctr.idle_polls));

	for (p = 0; p < 2; p++) {
		/* a nested container must be allocated and handed over;
		 * the library frees it after serialising (keep_data = 0) */
		struct rte_tel_data *pd = rte_tel_data_alloc();
		char name[16];

		if (pd == NULL)
			return -ENOMEM;
		rte_tel_data_start_dict(pd);
		rte_tel_data_add_dict_uint(pd, "rx", get(&pctr[p].rx));
		rte_tel_data_add_dict_uint(pd, "tx", get(&pctr[p].tx));
		rte_tel_data_add_dict_uint(pd, "drop", get(&pctr[p].drop));
		snprintf(name, sizeof(name), "port%u", p);
		rte_tel_data_add_dict_container(d, name, pd, 0);
	}
	return 0;
}

/* /ch13/echo,<anything>: the text after the first comma is 'params' */
static int
tel_echo(const char *cmd, const char *params, struct rte_tel_data *d)
{
	rte_tel_data_start_dict(d);
	rte_tel_data_add_dict_string(d, "cmd", cmd);
	rte_tel_data_add_dict_string(d, "params", params ? params : "(none)");
	return 0;
}

/* ---- 3. the lcore usage callback ------------------------------------- */
/*
 * Called by /eal/lcore/usage, /eal/lcore/info and rte_lcore_dump() for each
 * lcore, on whatever thread asked. Fill only what we know; return <0 for
 * lcores we do not track (they are then left out of the report).
 */
static int
usage_cb(unsigned int lcore_id, struct rte_lcore_usage *u)
{
	if (lcore_id != wctr.lcore || wctr.start_tsc == 0)
		return -1;
	u->total_cycles = rte_rdtsc() - wctr.start_tsc;
	u->busy_cycles = get(&wctr.busy_cycles);
	return 0;
}

/* ---- the worker ------------------------------------------------------- */
static int
worker(void *arg __rte_unused)
{
	uint64_t gap = rte_get_tsc_hz() / rate, next = rte_rdtsc();
	struct rte_mbuf *pkts[BURST];

	while (!ch13_quit) {
		uint64_t t0 = rte_rdtsc();
		uint16_t p;

		if (t0 < next) {               /* nothing to do yet: idle poll */
			add(&wctr.idle_polls, 1);
			rte_pause();
			continue;
		}
		next += gap;
		for (p = 0; p < 2; p++) {
			uint16_t n = rte_eth_rx_burst(p, 0, pkts, BURST);
			uint16_t s = rte_eth_tx_burst(p ^ 1, 0, pkts, n);

			add(&pctr[p].rx, n);
			add(&pctr[p ^ 1].tx, s);
			if (s < n) {
				add(&pctr[p ^ 1].drop, n - s);
				rte_pktmbuf_free_bulk(&pkts[s], n - s);
			}
		}
		add(&wctr.busy_polls, 1);
		add(&wctr.busy_cycles, rte_rdtsc() - t0);
	}
	return 0;
}

static void
parse_args(int argc, char **argv)
{
	static const struct option lo[] = {
		{"seconds", required_argument, NULL, 's'},
		{"rate", required_argument, NULL, 'r'},
		{NULL, 0, NULL, 0}
	};
	int c;

	while ((c = getopt_long(argc, argv, "", lo, NULL)) != -1) {
		if (c == 's')
			seconds = atoi(optarg);
		else if (c == 'r')
			rate = strtoull(optarg, NULL, 0);
		else
			rte_exit(EXIT_FAILURE, "usage: -- [--seconds N] [--rate N]\n");
	}
	if (rate == 0)
		rate = 1;
}

int
main(int argc, char **argv)
{
	struct rte_mempool *pool;
	uint16_t p;
	int ret;

	ret = rte_eal_init(argc, argv);
	if (ret < 0)
		rte_exit(EXIT_FAILURE, "EAL init: %s\n", rte_strerror(rte_errno));
	parse_args(argc - ret, argv + ret);
	ch13_signals();

	if (rte_eth_dev_count_avail() != 2 || rte_lcore_count() < 2)
		rte_exit(EXIT_FAILURE, "need 2 ports and 2 lcores (-l 0-1)\n");
	pool = rte_pktmbuf_pool_create("ch13_tel_pool", 4095, 64, 0,
				       RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
	if (pool == NULL)
		rte_exit(EXIT_FAILURE, "pool: %s\n", rte_strerror(rte_errno));
	for (p = 0; p < 2; p++)
		if (ch13_port_init(p, pool, NULL, 512) < 0)
			rte_exit(EXIT_FAILURE, "port %u init failed\n", p);

	/* 1 + 2: register the endpoints. Names: '/' first, only [A-Za-z0-9_/],
	 * shorter than 56 bytes; help text shorter than 128 bytes. */
	printf("register /ch13/stats      -> %d\n",
	       rte_telemetry_register_cmd("/ch13/stats", tel_stats,
			"Forwarder counters of telemetry_app. No parameters"));
	printf("register /ch13/echo       -> %d\n",
	       rte_telemetry_register_cmd("/ch13/echo", tel_echo,
			"Echoes its parameters back. Parameters: any text"));
	/* two deliberate mistakes, to see the real return codes */
	printf("register /ch13/bad-name   -> %d (a '-' is not allowed)\n",
	       rte_telemetry_register_cmd("/ch13/bad-name", tel_echo, "x"));
	printf("register ch13/no_slash    -> %d (must start with '/')\n",
	       rte_telemetry_register_cmd("ch13/no_slash", tel_echo, "x"));

	/* 3: the usage callback */
	rte_lcore_register_usage_cb(usage_cb);

	wctr.lcore = rte_get_next_lcore(-1, 1, 0);
	wctr.start_tsc = rte_rdtsc();
	rte_eal_remote_launch(worker, NULL, wctr.lcore);
	printf("worker on lcore %u, %" PRIu64 " busy polls/s; telemetry socket: %s/dpdk_telemetry.v2\n",
	       wctr.lcore, rate, rte_eal_get_runtime_dir());
	printf("READY\n");
	fflush(stdout);

	if (seconds) {
		uint64_t end = rte_rdtsc() + seconds * rte_get_tsc_hz();

		while (!ch13_quit && rte_rdtsc() < end)
			rte_delay_ms(50);
		ch13_quit = true;
	} else {
		while (!ch13_quit)
			rte_delay_ms(50);
	}
	rte_eal_mp_wait_lcore();

	printf("\nfinal: port0 rx=%" PRIu64 " port1 tx=%" PRIu64 " drops=%" PRIu64 "\n",
	       get(&pctr[0].rx), get(&pctr[1].tx), get(&pctr[1].drop));
	printf("rte_lcore_dump() uses the same usage callback:\n");
	rte_lcore_dump(stdout);
	for (p = 0; p < 2; p++) {
		rte_eth_dev_stop(p);
		rte_eth_dev_close(p);
	}
	rte_mempool_free(pool);
	rte_eal_cleanup();
	return 0;
}
