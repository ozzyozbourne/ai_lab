/* SPDX-License-Identifier: BSD-3-Clause
 * Exercise 1 solution: an LSC callback on net_tap never fires, so poll.
 *
 * Why: net_tap sets RTE_ETH_DEV_INTR_LSC in dev_flags and tracks the
 * kernel link through netlink, but it never calls
 * rte_eth_dev_callback_process(RTE_ETH_EVENT_INTR_LSC) (grep
 * drivers/net/tap/). The callback is registered fine and just never runs.
 *
 * Fix: a self-re-arming EAL alarm (runs in the dpdk-intr thread, the same
 * thread a real LSC callback would use) polls rte_eth_link_get_nowait()
 * every 50 ms and calls the SAME handler when the state changes, so the
 * rest of the app does not care where the event came from.
 *
 * Run: ./lsc_poll -l 0 --no-pci --no-huge -m 64 --file-prefix=ch12-lsc \
 *        --vdev=net_tap0,iface=ch12tap6
 */
#include <stdatomic.h>
#include <rte_alarm.h>
#include <rte_cycles.h>
#include "ch12_common.h"

static atomic_int real_lsc, synth_lsc;
static int last_status = -1;
static uint64_t t0;

static void
link_changed(uint16_t port, int up, const char *source)
{
	printf("  %7.1f ms  port %u link %s  (source: %s)\n",
	       (rte_get_timer_cycles() - t0) * 1000.0 / rte_get_timer_hz(),
	       port, up ? "UP" : "DOWN", source);
}

static int
on_lsc(uint16_t port, enum rte_eth_event_type ev, void *a, void *r)
{
	struct rte_eth_link l;

	(void)ev; (void)a; (void)r;
	atomic_fetch_add(&real_lsc, 1);
	if (rte_eth_link_get_nowait(port, &l) == 0)
		link_changed(port, l.link_status, "LSC callback");
	return 0;
}

static void
poll_link(void *arg)
{
	uint16_t port = (uintptr_t)arg;
	struct rte_eth_link l;

	if (rte_eth_link_get_nowait(port, &l) == 0 &&
	    (int)l.link_status != last_status) {
		last_status = l.link_status;
		atomic_fetch_add(&synth_lsc, 1);
		link_changed(port, l.link_status, "50 ms link poll");
	}
	rte_eal_alarm_set(50 * 1000, poll_link, arg);	/* re-arm */
}

int
main(int argc, char **argv)
{
	struct rte_mempool *mp;
	struct rte_eth_conf conf = { .intr_conf.lsc = 1 };

	setvbuf(stdout, NULL, _IOLBF, 0);
	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	mp = rte_pktmbuf_pool_create("lsc", 1023, 32, 0, RTE_MBUF_DEFAULT_BUF_SIZE,
				     rte_socket_id());
	rte_eth_dev_callback_register(0, RTE_ETH_EVENT_INTR_LSC, on_lsc, NULL);
	if (!mp || ch12_port_init(0, 1, 1, mp, &conf, NULL, 1) < 0)
		rte_exit(EXIT_FAILURE, "port init\n");
	t0 = rte_get_timer_cycles();
	poll_link((void *)(uintptr_t)0);

	rte_delay_ms(200);
	printf("  ip link set ch12tap6 down\n");
	if (system("ip link set ch12tap6 down") != 0)
		printf("ip failed\n");
	rte_delay_ms(300);
	printf("  ip link set ch12tap6 up\n");
	if (system("ip link set ch12tap6 up") != 0)
		printf("ip failed\n");
	rte_delay_ms(300);

	rte_eal_alarm_cancel(poll_link, (void *)-1);
	printf("real LSC callbacks: %d, changes found by polling: %d\n",
	       atomic_load(&real_lsc), atomic_load(&synth_lsc));
	rte_eth_dev_stop(0);
	rte_eth_dev_close(0);
	rte_mempool_free(mp);
	rte_eal_cleanup();
	return 0;
}
