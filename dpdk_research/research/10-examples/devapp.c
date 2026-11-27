#include <stdio.h>
#include <signal.h>
#include <unistd.h>
#include <rte_eal.h>
#include <rte_lcore.h>
#include <rte_log.h>
#include <rte_telemetry.h>
#include <rte_cycles.h>
#include <rte_trace_point.h>
#include <rte_debug.h>
#include <rte_eal_trace.h>
#include "app_trace.h"
#include <rte_version.h>
#include <rte_ethdev.h>

/* custom log type: shows up as "user.devapp" in --log-level */
RTE_LOG_REGISTER(devapp_logtype, user.devapp, INFO);
#define APP_LOG(lvl, ...) rte_log(RTE_LOG_##lvl, devapp_logtype, "DEVAPP: " __VA_ARGS__)

static volatile int quit;
static uint64_t counter;

static int
tel_counter(const char *cmd, const char *params, struct rte_tel_data *d)
{
	(void)cmd; (void)params;
	rte_tel_data_start_dict(d);
	rte_tel_data_add_dict_uint(d, "counter", counter);
	rte_tel_data_add_dict_string(d, "version", rte_version());
	return 0;
}
static void sig(int s) { (void)s; quit = 1; }

int main(int argc, char **argv)
{
	if (rte_eal_init(argc, argv) < 0)
		rte_panic("EAL init failed\n");
	signal(SIGINT, sig); signal(SIGTERM, sig);
	rte_telemetry_register_cmd("/devapp/counter", tel_counter,
		"Returns the devapp counter. No parameters");
	APP_LOG(INFO, "running on lcore %u, %u lcores, tsc %lu Hz\n",
		rte_lcore_id(), rte_lcore_count(), rte_get_tsc_hz());
	APP_LOG(INFO, "%u eth ports\n", rte_eth_dev_count_avail());
	APP_LOG(DEBUG, "this only shows with --log-level=user.devapp:debug\n");
	while (!quit) {
		counter++;
		rte_eal_trace_generic_u64(counter); app_trace_tick(counter, "loop");
		usleep(100000);
	}
	APP_LOG(NOTICE, "exiting, counter=%lu\n", counter);
	rte_eal_cleanup();
	return 0;
}
