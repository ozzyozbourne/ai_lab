/* sched_mini.c - tiny rte_sched hierarchy: 1 port (8 Mbit/s = 1 MB/s), 1 subport,
 * 4 pipes. Pipe 0 is rate-limited to 100 KB/s, pipes 1-3 to 400 KB/s each.
 * All pipes are over-offered; we enqueue continuously for ~1 s of real time and
 * count dequeued bytes per pipe and per traffic class (strict priority TC0 > TC12).
 * Pipes 1-3 together ask for 1.2 MB/s > port 1 MB/s, so they share what is left.
 * run: ./sched_mini --no-huge -m 256 --no-pci --file-prefix=ch07s */
#include <stdio.h>
#include <string.h>
#include <rte_eal.h>
#include <rte_mbuf.h>
#include <rte_cycles.h>
#include <rte_sched.h>

#define NPIPES 4
#define T RTE_SCHED_TRAFFIC_CLASSES_PER_PIPE

int main(int argc, char **argv)
{
	if (rte_eal_init(argc, argv) < 0) return 1;
	struct rte_mempool *mp = rte_pktmbuf_pool_create("mp", 16384, 256, 0, RTE_MBUF_DEFAULT_BUF_SIZE, SOCKET_ID_ANY);
	struct rte_sched_pipe_params pp[2];
	memset(pp, 0, sizeof(pp));
	for (int p = 0; p < 2; p++) {
		pp[p].tb_rate = p == 0 ? 100000 : 400000;   /* bytes/s */
		pp[p].tb_size = 3000; pp[p].tc_period = 40; pp[p].tc_ov_weight = 1;  /* period in ms */
		for (int t = 0; t < T; t++) pp[p].tc_rate[t] = pp[p].tb_rate;
		for (int q = 0; q < RTE_SCHED_BE_QUEUES_PER_PIPE; q++) pp[p].wrr_weights[q] = 1;
	}
	struct rte_sched_subport_profile_params spp = { .tb_rate = 1000000, .tb_size = 1000000, .tc_period = 10 };
	for (int t = 0; t < T; t++) spp.tc_rate[t] = 1000000;
	struct rte_sched_port_params port_p = { .name = "port0", .socket = 0, .rate = 1000000,
		.mtu = 1522, .frame_overhead = RTE_SCHED_FRAME_OVERHEAD_DEFAULT, .n_subports_per_port = 1,
		.subport_profiles = &spp, .n_subport_profiles = 1, .n_max_subport_profiles = 1,
		.n_pipes_per_subport = NPIPES };
	struct rte_sched_port *port = rte_sched_port_config(&port_p);
	struct rte_sched_subport_params sp = { .n_pipes_per_subport_enabled = NPIPES,
		.pipe_profiles = pp, .n_pipe_profiles = 2, .n_max_pipe_profiles = 2 };
	for (int t = 0; t < T; t++) sp.qsize[t] = 64;
	if (!port || rte_sched_subport_config(port, 0, &sp, 0) != 0) { printf("config failed\n"); return 1; }
	for (int p = 0; p < NPIPES; p++) rte_sched_pipe_config(port, 0, p, p == 0 ? 0 : 1);

	uint64_t bytes[NPIPES] = {0}, tcb[T] = {0};
	uint64_t end = rte_get_tsc_cycles() + rte_get_tsc_hz();
	struct rte_mbuf *in[32], *out[32];
	uint32_t seq = 0;
	/* Emulated NIC: rte_sched credits advance with *port time* (bytes it has
	 * sent), so the caller must only dequeue as fast as the link drains.
	 * Without this pacing the shaper only enforces ratios, not absolute rates. */
	double link_bytes = 0, bytes_per_cycle = (double)port_p.rate / rte_get_tsc_hz();
	uint64_t last = rte_get_tsc_cycles();
	while (rte_get_tsc_cycles() < end) {
		if (rte_pktmbuf_alloc_bulk(mp, in, 32) == 0) {
			for (int i = 0; i < 32; i++, seq++) {
				rte_pktmbuf_append(in[i], 1000);
				uint32_t pipe = seq % NPIPES, tc = (seq / NPIPES) % 2 ? 0 : RTE_SCHED_TRAFFIC_CLASS_BE;
				rte_sched_port_pkt_write(port, in[i], 0, pipe, tc, tc == 0 ? 0 : seq % 4, RTE_COLOR_GREEN);
			}
			rte_sched_port_enqueue(port, in, 32);  /* tail-drops (frees) on full queues */
		}
		uint64_t now = rte_get_tsc_cycles();
		link_bytes += (now - last) * bytes_per_cycle; last = now;
		if (link_bytes > 3000) link_bytes = 3000;           /* tiny TX ring */
		if (link_bytes < 1000 + RTE_SCHED_FRAME_OVERHEAD_DEFAULT)
			continue;
		int n = rte_sched_port_dequeue(port, out, 1);
		if (n) link_bytes -= out[0]->pkt_len + RTE_SCHED_FRAME_OVERHEAD_DEFAULT;
		for (int i = 0; i < n; i++) {
			uint32_t s, p, tc, q;
			rte_sched_port_pkt_read_tree_path(port, out[i], &s, &p, &tc, &q);
			bytes[p] += out[i]->pkt_len; tcb[tc] += out[i]->pkt_len;
			rte_pktmbuf_free(out[i]);
		}
	}
	for (int p = 0; p < NPIPES; p++)
		printf("pipe %d (limit %s): %7lu bytes/s\n", p, p == 0 ? "100 KB/s" : "400 KB/s", (unsigned long)bytes[p]);
	printf("TC0 (strict high prio): %lu bytes, TC12 (best effort): %lu bytes\n",
	       (unsigned long)tcb[0], (unsigned long)tcb[RTE_SCHED_TRAFFIC_CLASS_BE]);
	struct rte_sched_subport_stats st; uint32_t tc_ov;
	rte_sched_subport_read_stats(port, 0, &st, &tc_ov);
	printf("subport drops: TC0 %lu pkts, TC12 %lu pkts\n", (unsigned long)st.n_pkts_tc_dropped[0],
	       (unsigned long)st.n_pkts_tc_dropped[RTE_SCHED_TRAFFIC_CLASS_BE]);
	rte_sched_port_free(port);
	rte_eal_cleanup();
	return 0;
}
