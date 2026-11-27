/* SPDX-License-Identifier: BSD-3-Clause
 * Chapter 13: trace_demo.c - rte_trace with application tracepoints.
 *
 *   ./trace_demo -l 0 --no-pci --no-huge -m 64 --file-prefix=ch13-tr \
 *       --vdev=net_null0 --trace='ch13\..*' --trace-dir=./trace
 *
 * What it does:
 *   - configures one net_null port and fires the slow-path tracepoint
 *     ch13.port_cfg (port, nb_desc, driver name)
 *   - runs 1000 RX bursts and fires the fast-path tracepoint ch13.burst
 *     for each one (compiled out in trace_demo, compiled in in trace_demo_fp,
 *     which is the same source built with -DRTE_ENABLE_TRACE_FP)
 *   - fires the EAL's generic string tracepoint (lib.eal.generic.str)
 *   - disables ch13.port_cfg at run time and fires it again: not recorded
 *   - rte_trace_save() writes the CTF trace into --trace-dir
 *
 * The trace API is experimental: build with -DALLOW_EXPERIMENTAL_API.
 */
#include <rte_trace.h>
#include <rte_eal_trace.h>       /* rte_eal_trace_generic_*() */
#include "ch13_common.h"
#include "ch13_trace.h"

int
main(int argc, char **argv)
{
	struct rte_mempool *pool;
	struct rte_mbuf *pkts[32];
	struct rte_eth_dev_info di;
	rte_trace_point_t *tp;
	uint64_t rx = 0;
	int i;

	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");

	printf("trace compiled in: %s, enabled at run time: %s, fast path: %s\n",
	       rte_trace_feature_is_enabled() ? "yes" : "no",
	       rte_trace_is_enabled() ? "yes" : "no",
#ifdef RTE_ENABLE_TRACE_FP
	       "compiled in (RTE_ENABLE_TRACE_FP)"
#else
	       "compiled out"
#endif
	       );
	tp = rte_trace_point_lookup("ch13.port_cfg");
	printf("ch13.port_cfg: %s, %s\n", tp ? "registered" : "not found",
	       tp && rte_trace_point_is_enabled(tp) ? "enabled" : "disabled");
	tp = rte_trace_point_lookup("ch13.burst");
	printf("ch13.burst:    %s, %s\n", tp ? "registered" : "not found",
	       tp && rte_trace_point_is_enabled(tp) ? "enabled" : "disabled");

	pool = rte_pktmbuf_pool_create("ch13_tr_pool", 1023, 32, 0,
				       RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
	if (pool == NULL || ch13_port_init(0, pool, NULL, 256) < 0)
		rte_exit(EXIT_FAILURE, "port init failed\n");
	if (rte_eth_dev_info_get(0, &di) != 0)
		rte_exit(EXIT_FAILURE, "dev_info failed\n");
	ch13_trace_port_cfg(0, 256, di.driver_name);          /* slow path */

	for (i = 0; i < 1000; i++) {
		uint16_t n = rte_eth_rx_burst(0, 0, pkts, 32);

		ch13_trace_burst(0, n);                        /* fast path */
		rx += n;
		rte_pktmbuf_free_bulk(pkts, n);
	}
	rte_eal_trace_generic_str("ch13 loop done");          /* EAL generic */

	/* switch one tracepoint off while running, then fire it again */
	tp = rte_trace_point_lookup("ch13.port_cfg");
	if (tp)
		rte_trace_point_disable(tp);
	ch13_trace_port_cfg(0, 999, "not recorded");

	printf("received %" PRIu64 " packets in 1000 bursts\n", rx);
	printf("rte_trace_save() -> %d\n", rte_trace_save());
	rte_eth_dev_stop(0);
	rte_eth_dev_close(0);
	rte_eal_cleanup();
	return 0;
}
