/* SPDX-License-Identifier: BSD-3-Clause
 * Chapter 13, exercise 1 (solution): a /ch13/port_rates endpoint that
 * returns packets per second for every port SINCE THE PREVIOUS CALL.
 *
 * Points to notice:
 *  - the callback runs on a telemetry thread; two clients can call it at
 *    the same time (one thread per connection), so the "previous" snapshot
 *    is protected by a spinlock
 *  - rte_eth_stats_get() is safe to call from a non-lcore thread
 *  - the first call has no previous snapshot: report the rate since start
 *  - an optional parameter selects one port: /ch13/port_rates,1
 *
 *   ./port_rates -l 0-1 --no-pci --no-huge -m 128 --file-prefix=ch13-rates \
 *       --vdev=net_null0 --vdev=net_null1 -- [--seconds N]
 */
#include <rte_telemetry.h>
#include <rte_spinlock.h>
#include "../ch13_common.h"

#define MAXP 8

static struct {
	rte_spinlock_t lock;
	uint64_t tsc;
	uint64_t ipackets[MAXP], opackets[MAXP];
} prev = { .lock = RTE_SPINLOCK_INITIALIZER };

static int
tel_rates(const char *cmd __rte_unused, const char *params,
	  struct rte_tel_data *d)
{
	uint64_t now = rte_rdtsc(), dt;
	int only = (params && *params) ? atoi(params) : -1;
	uint16_t p;

	rte_tel_data_start_dict(d);
	rte_spinlock_lock(&prev.lock);
	dt = now - prev.tsc;
	rte_tel_data_add_dict_uint(d, "interval_ms", dt * 1000 / rte_get_tsc_hz());
	RTE_ETH_FOREACH_DEV(p) {
		struct rte_eth_stats st;
		struct rte_tel_data *pd;
		char name[16];

		if (p >= MAXP || rte_eth_stats_get(p, &st) != 0)
			continue;
		if (only < 0 || only == p) {
			pd = rte_tel_data_alloc();
			if (pd != NULL) {
				rte_tel_data_start_dict(pd);
				rte_tel_data_add_dict_uint(pd, "rx_pps",
					(st.ipackets - prev.ipackets[p]) * rte_get_tsc_hz() / dt);
				rte_tel_data_add_dict_uint(pd, "tx_pps",
					(st.opackets - prev.opackets[p]) * rte_get_tsc_hz() / dt);
				snprintf(name, sizeof(name), "port%u", p);
				rte_tel_data_add_dict_container(d, name, pd, 0);
			}
		}
		prev.ipackets[p] = st.ipackets;
		prev.opackets[p] = st.opackets;
	}
	prev.tsc = now;
	rte_spinlock_unlock(&prev.lock);
	return 0;
}

static int
worker(void *arg __rte_unused)
{
	struct rte_mbuf *pkts[32];

	while (!ch13_quit) {
		uint16_t p;

		for (p = 0; p < 2; p++) {
			uint16_t n = rte_eth_rx_burst(p, 0, pkts, 32);
			uint16_t s = rte_eth_tx_burst(p ^ 1, 0, pkts, n);

			rte_pktmbuf_free_bulk(&pkts[s], n - s);
		}
		rte_delay_us_block(20);        /* keep the rates readable */
	}
	return 0;
}

int
main(int argc, char **argv)
{
	struct rte_mempool *mp;
	unsigned int secs = 4;
	uint16_t p;
	int ret;

	ret = rte_eal_init(argc, argv);
	if (ret < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	if (argc - ret >= 3 && strcmp(argv[ret + 1], "--seconds") == 0)
		secs = atoi(argv[ret + 2]);
	ch13_signals();
	mp = rte_pktmbuf_pool_create("rates_pool", 4095, 64, 0,
				     RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
	for (p = 0; p < 2; p++)
		if (mp == NULL || ch13_port_init(p, mp, NULL, 512) < 0)
			rte_exit(EXIT_FAILURE, "port init failed\n");
	prev.tsc = rte_rdtsc();
	printf("register /ch13/port_rates -> %d\nREADY\n",
	       rte_telemetry_register_cmd("/ch13/port_rates", tel_rates,
			"pps per port since the previous call. Param: port id (optional)"));
	fflush(stdout);
	rte_eal_remote_launch(worker, NULL, rte_get_next_lcore(-1, 1, 0));
	sleep(secs);
	ch13_quit = true;
	rte_eal_mp_wait_lcore();
	rte_eal_cleanup();
	return 0;
}
