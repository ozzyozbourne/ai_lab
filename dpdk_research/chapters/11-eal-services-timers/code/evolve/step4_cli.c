/* SPDX-License-Identifier: BSD-3-Clause
 * Chapter 11, step 4: an interactive control shell (lib/cmdline).
 *
 * Until now the only way to change the app was to restart it. Here the main
 * lcore becomes the control plane: it runs a cmdline shell, while lcore 1
 * keeps forwarding and the service lcore keeps the timers ticking.
 *
 *   ch11> show stats        per-port counters and the rate of the last second
 *   ch11> set burst 8       change the RX burst size of the running worker
 *   ch11> show keepalive    the watchdog's view of the forwarding lcore
 *   ch11> stall             make the worker hang (to watch keepalive react)
 *   ch11> help / quit
 *
 * What moved: cmdline_interact() BLOCKS on stdin, so the main lcore can no
 * longer call rte_timer_manage(). The timers (keepalive ping, 1 s stats
 * snapshot) are now armed on the service lcore, and a "housekeeping" service
 * there calls rte_timer_manage(). Same timers, different lcore.
 *
 * Layout (-l 0-2 -S 2):
 *   lcore 0 (main)    the shell (cmdline_stdin_new + cmdline_interact)
 *   lcore 1 (worker)  forwarding + rte_keepalive_mark_alive()
 *   lcore 2 (service) "ch11_housekeeping": rte_timer_manage() for both timers
 *
 *   (sleep 1; echo 'show stats'; echo quit) | ./step4_cli -l 0-2 -S 2 --no-pci \
 *       --no-huge -m 128 --file-prefix=ch11-s4 --vdev=net_ring0 --vdev=net_ring1
 */
#include "app_common.h"

#include <errno.h>
#include <rte_timer.h>
#include <rte_service.h>
#include <rte_service_component.h>
#include <rte_keepalive.h>
#include <rte_malloc.h>

#include <cmdline.h>
#include <cmdline_parse.h>
#include <cmdline_parse_string.h>
#include <cmdline_parse_num.h>
#include <cmdline_socket.h>

static struct rte_keepalive *ka;
static struct rte_timer ka_tim, snap_tim;
static uint64_t hz;
static unsigned int fwd_lcore, svc_lcore;
static RTE_ATOMIC(uint16_t) burst = 32;          /* written by the shell, read by the worker */
static RTE_ATOMIC(uint64_t) rate_pps[NB_PORTS];  /* written by the snapshot timer */
static RTE_ATOMIC(int) ka_state = RTE_KA_STATE_UNUSED;
static volatile bool stall_req;
static RTE_ATOMIC(unsigned int) ka_deaths;      /* failure callbacks so far */

static const char *
ka_name(int s)
{
	static const char *n[] = {"UNUSED", "ALIVE", "DEAD", "GONE", "MISSING", "DOZING", "SLEEP"};

	return (s >= 0 && s < (int)RTE_DIM(n)) ? n[s] : "?";
}

/* ======================= data plane: lcore 1 ======================= */
static int
fwd_main(void *arg)
{
	(void)arg;
	while (!force_quit) {
		app_forward_once(rte_atomic_load_explicit(&burst, rte_memory_order_relaxed));
		rte_keepalive_mark_alive(ka);
		if (stall_req) {
			while (stall_req && !force_quit)
				rte_pause();     /* hung: no forwarding, no mark_alive */
		}
	}
	return 0;
}

/* ======================= housekeeping: service lcore 2 ======================= */
static int32_t
housekeeping(void *arg)
{
	(void)arg;
	/* rte_timer_next_ticks() > 0: nothing is due yet on THIS lcore */
	if (rte_timer_next_ticks() > 0)
		return -EAGAIN;
	rte_timer_manage();
	return 0;
}

/* 1 s timer on lcore 2: turn counters into rates for "show stats" */
static void
snapshot_cb(struct rte_timer *tim, void *arg)
{
	static uint64_t last[NB_PORTS];
	uint16_t p;

	(void)tim;
	(void)arg;
	for (p = 0; p < NB_PORTS; p++) {
		uint64_t rx = ctr_get(&app_ctr[p].rx);

		rte_atomic_store_explicit(&rate_pps[p], rx - last[p], rte_memory_order_relaxed);
		last[p] = rx;
	}
}

static void
ka_ping(struct rte_timer *tim, void *arg)
{
	rte_keepalive_dispatch_pings(tim, arg);
}

static void
ka_relay(void *data, const int core, enum rte_keepalive_state st, uint64_t last_seen)
{
	(void)data;
	(void)core;
	(void)last_seen;
	rte_atomic_store_explicit(&ka_state, st, rte_memory_order_relaxed);
}

static void
ka_dead(void *data, const int core)
{
	char where[64];

	(void)data;
	rte_atomic_fetch_add_explicit(&ka_deaths, 1, rte_memory_order_relaxed);
	printf("\n[keepalive] lcore %d is dead -> releasing it (callback in %s)\n",
	       core, app_where(where, sizeof(where)));
	stall_req = false;
}

/* ======================= control plane: the shell on lcore 0 ======================= */

/*
 * A command is an INSTRUCTION: a list of TOKENS plus a function. Each token
 * parses one word into a field of a result struct (at offsetof(field)).
 * cmdline tries every instruction in the context; the first one whose tokens
 * all match the line wins, and its function gets the filled result struct.
 */

/* ---- "show stats" / "show keepalive" ---- */
struct cmd_show_result {
	cmdline_fixed_string_t show;
	cmdline_fixed_string_t what;
};

static void
cmd_show_parsed(void *parsed, struct cmdline *cl, void *data)
{
	struct cmd_show_result *res = parsed;
	uint16_t p;

	(void)data;
	if (strcmp(res->what, "stats") == 0) {
		for (p = 0; p < NB_PORTS; p++)
			cmdline_printf(cl, "port %u: rx %" PRIu64 " tx %" PRIu64 " drop %" PRIu64
				       "  last second %.2f Mpps\n", p,
				       ctr_get(&app_ctr[p].rx), ctr_get(&app_ctr[p].tx),
				       ctr_get(&app_ctr[p].drop),
				       rte_atomic_load_explicit(&rate_pps[p],
							rte_memory_order_relaxed) / 1e6);
		cmdline_printf(cl, "burst %u\n",
			       rte_atomic_load_explicit(&burst, rte_memory_order_relaxed));
	} else {
		int s = rte_atomic_load_explicit(&ka_state, rte_memory_order_relaxed);

		cmdline_printf(cl, "lcore %u keepalive state after last ping: %s%s, "
			       "failure callbacks so far: %u\n",
			       fwd_lcore, ka_name(s), stall_req ? " (stalled)" : "",
			       rte_atomic_load_explicit(&ka_deaths, rte_memory_order_relaxed));
	}
}

static cmdline_parse_token_string_t cmd_show_show =
	TOKEN_STRING_INITIALIZER(struct cmd_show_result, show, "show");
/* "a#b" = one of several fixed words */
static cmdline_parse_token_string_t cmd_show_what =
	TOKEN_STRING_INITIALIZER(struct cmd_show_result, what, "stats#keepalive");

static cmdline_parse_inst_t cmd_show = {
	.f = cmd_show_parsed,
	.data = NULL,
	.help_str = "show stats|keepalive: print counters or watchdog state",
	.tokens = { (void *)&cmd_show_show, (void *)&cmd_show_what, NULL },
};

/* ---- "set burst <N>" ---- */
struct cmd_burst_result {
	cmdline_fixed_string_t set;
	cmdline_fixed_string_t burst;
	uint16_t n;
};

static void
cmd_burst_parsed(void *parsed, struct cmdline *cl, void *data)
{
	struct cmd_burst_result *res = parsed;

	(void)data;
	/* the NUM token only checked "fits in a uint16_t"; the range is ours */
	if (res->n < 1 || res->n > MAX_BURST) {
		cmdline_printf(cl, "burst must be 1..%u\n", MAX_BURST);
		return;
	}
	rte_atomic_store_explicit(&burst, res->n, rte_memory_order_relaxed);
	cmdline_printf(cl, "burst set to %u\n", res->n);
}

static cmdline_parse_token_string_t cmd_burst_set =
	TOKEN_STRING_INITIALIZER(struct cmd_burst_result, set, "set");
static cmdline_parse_token_string_t cmd_burst_burst =
	TOKEN_STRING_INITIALIZER(struct cmd_burst_result, burst, "burst");
static cmdline_parse_token_num_t cmd_burst_n =
	TOKEN_NUM_INITIALIZER(struct cmd_burst_result, n, RTE_UINT16);

static cmdline_parse_inst_t cmd_burst = {
	.f = cmd_burst_parsed,
	.help_str = "set burst <1..64>: RX burst size of the forwarding lcore",
	.tokens = { (void *)&cmd_burst_set, (void *)&cmd_burst_burst,
		    (void *)&cmd_burst_n, NULL },
};

/* ---- one-word commands: "stall", "help", "quit" share one result type ---- */
struct cmd_word_result {
	cmdline_fixed_string_t word;
};

static cmdline_parse_ctx_t main_ctx[];

static void
cmd_word_parsed(void *parsed, struct cmdline *cl, void *data)
{
	struct cmd_word_result *res = parsed;
	int i;

	(void)data;
	if (strcmp(res->word, "quit") == 0) {
		cmdline_quit(cl);             /* makes cmdline_interact() return */
	} else if (strcmp(res->word, "stall") == 0) {
		stall_req = true;
		cmdline_printf(cl, "worker lcore %u now hangs; keepalive should notice\n",
			       fwd_lcore);
	} else {
		for (i = 0; main_ctx[i] != NULL; i++)
			cmdline_printf(cl, "  %s\n", main_ctx[i]->help_str);
	}
}

static cmdline_parse_token_string_t cmd_word_word =
	TOKEN_STRING_INITIALIZER(struct cmd_word_result, word, "stall#help#quit");

static cmdline_parse_inst_t cmd_word = {
	.f = cmd_word_parsed,
	.help_str = "stall|help|quit",
	.tokens = { (void *)&cmd_word_word, NULL },
};

/* The context: a NULL-terminated array of instructions. */
static cmdline_parse_ctx_t main_ctx[] = {
	(cmdline_parse_inst_t *)&cmd_show,
	(cmdline_parse_inst_t *)&cmd_burst,
	(cmdline_parse_inst_t *)&cmd_word,
	NULL,
};

int
main(int argc, char **argv)
{
	struct rte_service_spec spec;
	uint32_t svc_id, ids[RTE_MAX_LCORE];
	struct rte_mempool *pool;
	struct cmdline *cl;
	uint64_t calls, idle;
	int ret;

	ret = rte_eal_init(argc, argv);
	if (ret < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	signal(SIGINT, app_on_signal);
	signal(SIGTERM, app_on_signal);

	fwd_lcore = rte_get_next_lcore(-1, 1, 0);
	if (fwd_lcore >= RTE_MAX_LCORE || rte_service_lcore_list(ids, RTE_DIM(ids)) < 1)
		rte_exit(EXIT_FAILURE, "run with -l 0-2 -S 2\n");
	svc_lcore = ids[0];
	pool = app_ports_init();
	printf("injected %u frames; shell on lcore %u, forwarding on lcore %u, "
	       "timers on service lcore %u\n",
	       app_inject(pool, 64), rte_lcore_id(), fwd_lcore, svc_lcore);
	hz = rte_get_timer_hz();

	/* keepalive, as in step 3 */
	ka = rte_keepalive_create(ka_dead, NULL);
	if (ka == NULL)
		rte_exit(EXIT_FAILURE, "rte_keepalive_create failed\n");
	rte_keepalive_register_relay_callback(ka, ka_relay, NULL);
	rte_keepalive_register_core(ka, fwd_lcore);

	/* Timers armed FOR the service lcore: tim_lcore = svc_lcore. Only that
	 * lcore's rte_timer_manage() will run them. */
	rte_timer_subsystem_init();
	rte_timer_init(&ka_tim);
	rte_timer_init(&snap_tim);
	rte_timer_reset(&ka_tim, hz / 4, PERIODICAL, svc_lcore, ka_ping, ka);
	rte_timer_reset(&snap_tim, hz, PERIODICAL, svc_lcore, snapshot_cb, NULL);

	memset(&spec, 0, sizeof(spec));
	snprintf(spec.name, sizeof(spec.name), "ch11_housekeeping");
	spec.callback = housekeeping;
	spec.socket_id = rte_socket_id();
	if (rte_service_component_register(&spec, &svc_id) != 0)
		rte_exit(EXIT_FAILURE, "service register failed\n");
	rte_service_component_runstate_set(svc_id, 1);
	rte_service_map_lcore_set(svc_id, svc_lcore, 1);
	rte_service_set_stats_enable(svc_id, 1);
	rte_service_runstate_set(svc_id, 1);

	rte_eal_remote_launch(fwd_main, NULL, fwd_lcore);

	/* The shell. cmdline_stdin_new() puts a tty in raw mode (no-op on a
	 * pipe); cmdline_interact() reads until "quit" or end of input. */
	cl = cmdline_stdin_new(main_ctx, "ch11> ");
	if (cl == NULL)
		rte_exit(EXIT_FAILURE, "cmdline_stdin_new failed\n");
	cmdline_interact(cl);
	cmdline_stdin_exit(cl);           /* restores the terminal settings */
	printf("\nshell closed, stopping\n");

	force_quit = true;
	stall_req = false;
	rte_eal_wait_lcore(fwd_lcore);
	rte_service_runstate_set(svc_id, 0);
	rte_service_lcore_stop(svc_lcore);
	rte_eal_wait_lcore(svc_lcore);
	rte_service_attr_get(svc_id, RTE_SERVICE_ATTR_CALL_COUNT, &calls);
	rte_service_attr_get(svc_id, RTE_SERVICE_ATTR_IDLE_CALL_COUNT, &idle);
	printf("housekeeping service: %" PRIu64 " calls, %" PRIu64 " ran timers\n",
	       calls, calls - idle);
	rte_service_map_lcore_set(svc_id, svc_lcore, 0);
	rte_service_component_runstate_set(svc_id, 0);
	rte_service_component_unregister(svc_id);
	rte_timer_stop(&ka_tim);
	rte_timer_stop(&snap_tim);
	rte_free(ka);
	rte_timer_subsystem_finalize();
	app_ports_close();
	rte_eal_cleanup();
	return 0;
}
