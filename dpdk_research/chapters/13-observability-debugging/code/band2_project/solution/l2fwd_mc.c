/* SPDX-License-Identifier: BSD-3-Clause
 * Chapter 13, band 2 project (solution): a multi-core L2 forwarder that you
 * can watch and check.
 *
 * It is chapter 11's evolving app grown to two forwarding lcores, with the
 * observability of this chapter built in:
 *
 *   lcore 0 (main)   control plane: rte_timer report every 500 ms, a
 *                    cmdline shell read from stdin without blocking
 *                    (cmdline_in), and the end-of-test check
 *   lcore 1          forwards port 0 <-> port 1   (net_ring0, net_ring1)
 *   lcore 2          forwards port 2 <-> port 3   (net_ring2, net_ring3)
 *   telemetry        /band2/stats: per-lcore rx/tx/drop + pool in_use
 *
 * Every net_ring port is a loopback, so a frame sent on port 1 comes back
 * on port 1 and is forwarded to port 0, and so on: the frames of a pair
 * circulate between its two ports. To make the test finite and exact,
 * each frame carries a hop budget (32 bits in the UDP payload). Every
 * receive decrements it; at 0 the frame is dropped ("TTL expired").
 * With N frames per pair and a budget of H hops the counters MUST end at
 *     rx = N*H,  drop = N,  tx = rx - drop   for each lcore,
 * and the mempool must be full again (in_use = 0).
 *
 *   ./l2fwd_mc -l 0-2 --no-pci --no-huge -m 128 --file-prefix=ch13-b2 \
 *       --vdev=net_ring0 --vdev=net_ring1 --vdev=net_ring2 --vdev=net_ring3 \
 *       -- [--frames N] [--hops H]  < commands
 */
#include <getopt.h>
#include <poll.h>
#include <rte_timer.h>
#include <rte_telemetry.h>
#include <cmdline.h>
#include <cmdline_parse.h>
#include <cmdline_parse_string.h>
#include "../../ch13_common.h"

#define NB_PORTS 4
#define BURST    32

/* ---- per-lcore statistics ---------------------------------------------
 * One writer per entry (its lcore), readers on lcore 0 and the telemetry
 * thread. Each entry is alone in its cache line(s): no false sharing
 * between the two forwarding lcores (chapter 14 shows the cost if not). */
struct __rte_cache_aligned lcore_stats {
	RTE_ATOMIC(uint64_t) rx;
	RTE_ATOMIC(uint64_t) tx;
	RTE_ATOMIC(uint64_t) drop;
	uint16_t port_a, port_b;       /* the pair this lcore owns */
	bool used;
};
static struct lcore_stats lstats[RTE_MAX_LCORE];

static struct rte_mempool *pool;
static unsigned int frames = 512;
static uint32_t hops = 200000;
static volatile bool stop_fwd, shell_done;
static struct rte_timer report_tim;
static uint64_t t_start;

static inline void
st_add(RTE_ATOMIC(uint64_t) *c, uint64_t n)
{
	rte_atomic_store_explicit(c,
		rte_atomic_load_explicit(c, rte_memory_order_relaxed) + n,
		rte_memory_order_relaxed);
}
#define ST(lc, f) rte_atomic_load_explicit(&lstats[lc].f, rte_memory_order_relaxed)

/* the hop budget lives right after the UDP header */
static inline uint32_t *
hop_field(struct rte_mbuf *m)
{
	return rte_pktmbuf_mtod_offset(m, uint32_t *,
		sizeof(struct rte_ether_hdr) + sizeof(struct rte_ipv4_hdr) +
		sizeof(struct rte_udp_hdr));
}

/* ---- the data plane ---------------------------------------------------- */
static void
fwd_one(struct lcore_stats *s, uint16_t in, uint16_t out)
{
	struct rte_mbuf *pkts[BURST], *keep[BURST];
	uint16_t n = rte_eth_rx_burst(in, 0, pkts, BURST), i, k = 0, sent;
	uint64_t dropped = 0;

	if (n == 0)
		return;
	for (i = 0; i < n; i++) {
		uint32_t *h = hop_field(pkts[i]);

		if (--*h == 0) {                   /* budget used up */
			rte_pktmbuf_free(pkts[i]);
			dropped++;
			continue;
		}
		/* l2fwd-style MAC rewrite: src = our port, dst = next hop */
		struct rte_ether_hdr *eh = rte_pktmbuf_mtod(pkts[i], struct rte_ether_hdr *);
		eh->src_addr.addr_bytes[5] = (uint8_t)out;
		keep[k++] = pkts[i];
	}
	sent = rte_eth_tx_burst(out, 0, keep, k);
	if (sent < k) {                            /* TX ring full */
		rte_pktmbuf_free_bulk(&keep[sent], k - sent);
		dropped += k - sent;
	}
	st_add(&s->rx, n);
	st_add(&s->tx, sent);
	st_add(&s->drop, dropped);
}

static int
fwd_main(void *arg __rte_unused)
{
	struct lcore_stats *s = &lstats[rte_lcore_id()];

	while (!stop_fwd) {
		fwd_one(s, s->port_a, s->port_b);
		fwd_one(s, s->port_b, s->port_a);
	}
	return 0;
}

/* ---- observability: report, telemetry, shell ------------------------- */
static void
print_stats(FILE *f)
{
	unsigned int lc;

	fprintf(f, "  t=%.2fs in_use=%u", (double)(rte_rdtsc() - t_start) / rte_get_tsc_hz(),
		rte_mempool_in_use_count(pool));
	RTE_LCORE_FOREACH_WORKER(lc)
		if (lstats[lc].used)
			fprintf(f, " | lcore%u p%u<->p%u rx=%" PRIu64 " tx=%" PRIu64 " drop=%" PRIu64,
				lc, lstats[lc].port_a, lstats[lc].port_b,
				ST(lc, rx), ST(lc, tx), ST(lc, drop));
	fprintf(f, "\n");
}

static void
report_cb(struct rte_timer *t __rte_unused, void *arg __rte_unused)
{
	printf("[timer]");
	print_stats(stdout);
	fflush(stdout);
}

static int
tel_band2(const char *cmd __rte_unused, const char *p __rte_unused,
	  struct rte_tel_data *d)
{
	unsigned int lc;

	rte_tel_data_start_dict(d);
	rte_tel_data_add_dict_uint(d, "in_use", rte_mempool_in_use_count(pool));
	RTE_LCORE_FOREACH_WORKER(lc) {
		struct rte_tel_data *ld;
		char name[16];

		if (!lstats[lc].used || (ld = rte_tel_data_alloc()) == NULL)
			continue;
		rte_tel_data_start_dict(ld);
		rte_tel_data_add_dict_uint(ld, "rx", ST(lc, rx));
		rte_tel_data_add_dict_uint(ld, "tx", ST(lc, tx));
		rte_tel_data_add_dict_uint(ld, "drop", ST(lc, drop));
		snprintf(name, sizeof(name), "lcore%u", lc);
		rte_tel_data_add_dict_container(d, name, ld, 0);
	}
	return 0;
}

struct cmd_res { cmdline_fixed_string_t w1, w2; };

static void
cmd_show_cb(void *parsed, struct cmdline *cl, void *data __rte_unused)
{
	struct cmd_res *r = parsed;

	/* cmdline echoes the typed line with write(2); use stdio + fflush
	 * for our own output so the two never interleave */
	(void)cl;
	if (strcmp(r->w2, "stats") == 0) {
		printf("[shell]");
		print_stats(stdout);
	} else {
		printf("[shell] pool %s: size %u avail %u in_use %u\n",
		       pool->name, pool->size, rte_mempool_avail_count(pool),
		       rte_mempool_in_use_count(pool));
	}
	fflush(stdout);
}
static cmdline_parse_token_string_t t_show =
	TOKEN_STRING_INITIALIZER(struct cmd_res, w1, "show");
static cmdline_parse_token_string_t t_what =
	TOKEN_STRING_INITIALIZER(struct cmd_res, w2, "stats#pool");
static cmdline_parse_inst_t cmd_show = {
	.f = cmd_show_cb, .help_str = "show stats|pool",
	.tokens = { (void *)&t_show, (void *)&t_what, NULL },
};

static void
cmd_quit_cb(void *parsed __rte_unused, struct cmdline *cl, void *d __rte_unused)
{
	(void)cl;
	printf("[shell] quit: waiting for the traffic to drain\n");
	fflush(stdout);
	shell_done = true;
}
static cmdline_parse_token_string_t t_quit =
	TOKEN_STRING_INITIALIZER(struct cmd_res, w1, "quit");
static cmdline_parse_inst_t cmd_quit = {
	.f = cmd_quit_cb, .help_str = "quit",
	.tokens = { (void *)&t_quit, NULL },
};
static cmdline_parse_ctx_t ctx[] = {
	(cmdline_parse_inst_t *)&cmd_show, (cmdline_parse_inst_t *)&cmd_quit, NULL
};

/* feed whatever stdin has into the shell, without blocking */
static void
shell_poll(struct cmdline *cl)
{
	struct pollfd pfd = { .fd = 0, .events = POLLIN };
	char buf[128];
	ssize_t n;

	if (shell_done || poll(&pfd, 1, 0) <= 0)
		return;
	n = read(0, buf, sizeof(buf));
	if (n <= 0) {
		shell_done = true;            /* EOF counts as quit */
		return;
	}
	cmdline_in(cl, buf, n);
}

/* ---- setup ------------------------------------------------------------- */
static void
inject(uint16_t port, unsigned int n)
{
	unsigned int i;

	for (i = 0; i < n; i++) {
		struct rte_mbuf *m = rte_pktmbuf_alloc(pool);

		if (m == NULL || ch13_make_udp(m, 64, i) < 0)
			rte_exit(EXIT_FAILURE, "inject: no mbuf\n");
		*hop_field(m) = hops;
		if (rte_eth_tx_burst(port, 0, &m, 1) != 1)
			rte_exit(EXIT_FAILURE, "inject: ring full\n");
	}
}

int
main(int argc, char **argv)
{
	static const struct option lo[] = {
		{"frames", required_argument, NULL, 'f'},
		{"hops", required_argument, NULL, 'h'},
		{NULL, 0, NULL, 0}
	};
	struct cmdline *cl;
	unsigned int lc, k = 0, fail = 0;
	uint64_t deadline;
	uint16_t p;
	int ret, c;

	ret = rte_eal_init(argc, argv);
	if (ret < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	argc -= ret;
	argv += ret;
	while ((c = getopt_long(argc, argv, "", lo, NULL)) != -1) {
		if (c == 'f')
			frames = atoi(optarg);
		else if (c == 'h')
			hops = strtoul(optarg, NULL, 0);
	}
	ch13_signals();
	if (rte_eth_dev_count_avail() != NB_PORTS || rte_lcore_count() != 3)
		rte_exit(EXIT_FAILURE, "need -l 0-2 and 4 net_ring ports\n");
	if (frames == 0 || frames > 1000 || hops == 0)
		rte_exit(EXIT_FAILURE, "--frames 1..1000, --hops >= 1\n");

	pool = rte_pktmbuf_pool_create("band2_pool", 4095, 64, 0,
				       RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
	if (pool == NULL)
		rte_exit(EXIT_FAILURE, "pool: %s\n", rte_strerror(rte_errno));
	for (p = 0; p < NB_PORTS; p++)
		if (ch13_port_init(p, pool, NULL, 1024) < 0)
			rte_exit(EXIT_FAILURE, "port %u init failed\n", p);

	RTE_LCORE_FOREACH_WORKER(lc) {             /* lcore 1: 0,1  lcore 2: 2,3 */
		lstats[lc].port_a = 2 * k;
		lstats[lc].port_b = 2 * k + 1;
		lstats[lc].used = true;
		inject(2 * k, frames);
		k++;
	}
	printf("%u frames per pair, hop budget %u: expect per lcore rx=%" PRIu64
	       " tx=%" PRIu64 " drop=%u\n", frames, hops,
	       (uint64_t)frames * hops, (uint64_t)frames * hops - frames, frames);

	rte_telemetry_register_cmd("/band2/stats", tel_band2,
		"Band 2 forwarder: per-lcore rx/tx/drop and pool in_use");
	rte_timer_subsystem_init();
	rte_timer_init(&report_tim);
	rte_timer_reset(&report_tim, rte_get_timer_hz() / 2, PERIODICAL,
			rte_lcore_id(), report_cb, NULL);
	cl = cmdline_new(ctx, "", 0, 1);
	if (cl == NULL)
		rte_exit(EXIT_FAILURE, "cmdline_new failed\n");

	t_start = rte_rdtsc();
	RTE_LCORE_FOREACH_WORKER(lc)
		rte_eal_remote_launch(fwd_main, NULL, lc);
	printf("READY\n");
	fflush(stdout);

	/* control loop: timers, shell, and "is all traffic gone?" */
	deadline = rte_rdtsc() + 12 * rte_get_tsc_hz();
	while (!ch13_quit && rte_rdtsc() < deadline) {
		rte_timer_manage();
		shell_poll(cl);
		if (shell_done && rte_mempool_in_use_count(pool) == 0)
			break;
		rte_delay_us_sleep(1000);
	}
	stop_fwd = true;
	rte_eal_mp_wait_lcore();
	rte_timer_stop_sync(&report_tim);
	cmdline_free(cl);

	/* ---- acceptance check ------------------------------------------- */
	printf("final:");
	print_stats(stdout);
	RTE_LCORE_FOREACH_WORKER(lc) {
		uint64_t rx = ST(lc, rx), tx = ST(lc, tx), dr = ST(lc, drop);
		bool ok = rx == tx + dr && rx == (uint64_t)frames * hops && dr == frames;

		printf("check lcore%u: rx == tx + drop (%" PRIu64 " == %" PRIu64 "), "
		       "rx == frames*hops, drop == frames: %s\n",
		       lc, rx, tx + dr, ok ? "ok" : "WRONG");
		fail += !ok;
	}
	printf("check mempool in_use == 0: %u -> %s\n", rte_mempool_in_use_count(pool),
	       rte_mempool_in_use_count(pool) == 0 ? "ok" : "WRONG");
	fail += rte_mempool_in_use_count(pool) != 0;
	printf("RESULT: %s\n", fail ? "FAIL" : "PASS");

	for (p = 0; p < NB_PORTS; p++) {
		rte_eth_dev_stop(p);
		rte_eth_dev_close(p);
	}
	rte_timer_subsystem_finalize();
	rte_eal_cleanup();
	return fail ? 1 : 0;
}
