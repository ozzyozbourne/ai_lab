/* SPDX-License-Identifier: BSD-3-Clause
 * events.c - ethdev event callbacks, hotplug and the device event monitor.
 *
 * One callback is registered for every interesting event on RTE_ETH_ALL
 * ports. It prints the event and the name of the THREAD it runs in, because
 * that is the first thing to know about a callback: who calls it.
 *
 *  1. hotplug net_null7 with rte_dev_probe()   -> NEW   (caller's thread)
 *  2. net_pcap with eof=1 reaches end of file  -> LSC   (dpdk-intr thread,
 *     raised through an EAL alarm by the PMD)
 *  3. net_vhost server + virtio_user client in this process: the client
 *     connects -> vhost raises QUEUE_STATE and LSC (vhost's own thread);
 *     the callback defers real work with rte_eal_alarm_set()
 *  4. stop/close/rte_dev_remove net_null7      -> DESTROY
 *  5. rte_dev_event_monitor_start(): kernel uevents for a new veth pair
 *     are NOT reported (the monitor only parses pci/uio/vfio uevents)
 *
 * Run: ./events -l 0 --no-pci --no-huge -m 128 --file-prefix=ch12-evt \
 *        --vdev=net_null0 -- <tiny.pcap> <vhost.sock>
 */
#define _GNU_SOURCE
#include <pthread.h>
#include <stdatomic.h>
#include <rte_alarm.h>
#include <rte_cycles.h>
#include <rte_dev.h>
#include <rte_lcore.h>
#include "ch12_common.h"

static const char *const evname[] = {
	[RTE_ETH_EVENT_UNKNOWN] = "UNKNOWN",
	[RTE_ETH_EVENT_INTR_LSC] = "INTR_LSC",
	[RTE_ETH_EVENT_QUEUE_STATE] = "QUEUE_STATE",
	[RTE_ETH_EVENT_INTR_RESET] = "INTR_RESET",
	[RTE_ETH_EVENT_VF_MBOX] = "VF_MBOX",
	[RTE_ETH_EVENT_MACSEC] = "MACSEC",
	[RTE_ETH_EVENT_INTR_RMV] = "INTR_RMV",
	[RTE_ETH_EVENT_NEW] = "NEW",
	[RTE_ETH_EVENT_DESTROY] = "DESTROY",
	[RTE_ETH_EVENT_IPSEC] = "IPSEC",
	[RTE_ETH_EVENT_FLOW_AGED] = "FLOW_AGED",
	[RTE_ETH_EVENT_RX_AVAIL_THRESH] = "RX_AVAIL_THRESH",
	[RTE_ETH_EVENT_ERR_RECOVERING] = "ERR_RECOVERING",
	[RTE_ETH_EVENT_RECOVERY_SUCCESS] = "RECOVERY_SUCCESS",
	[RTE_ETH_EVENT_RECOVERY_FAILED] = "RECOVERY_FAILED",
};

static uint64_t t0;
static atomic_int n_events;

static double
ms_now(void)
{
	return (double)(rte_get_timer_cycles() - t0) * 1000.0 / rte_get_timer_hz();
}

static const char *
thread_name(void)
{
	static __thread char name[32];

	if (pthread_getname_np(pthread_self(), name, sizeof(name)) != 0)
		strcpy(name, "?");
	return name;
}

/* Deferred work: runs later in the interrupt thread, outside the callback
 * that scheduled it, so it may call control-path APIs on the port. */
static void
deferred_link_check(void *arg)
{
	uint16_t port = (uintptr_t)arg;
	struct rte_eth_link l;
	char s[RTE_ETH_LINK_MAX_STR_LEN];

	if (rte_eth_link_get_nowait(port, &l) != 0)
		return;
	rte_eth_link_to_str(s, sizeof(s), &l);
	printf("  %8.1f ms  [alarm] deferred work for port %u in thread %s: %s\n",
	       ms_now(), port, thread_name(), s);
}

/* The ethdev callback. Rules: be short, do not block, do not stop/close
 * the port that raised the event from inside its own callback. */
static int
on_event(uint16_t port, enum rte_eth_event_type ev, void *arg, void *ret)
{
	char name[RTE_ETH_NAME_MAX_LEN] = "?";

	(void)arg;
	(void)ret;
	rte_eth_dev_get_name_by_port(port, name, sizeof(name)); /* 26.11: size arg */
	printf("  %8.1f ms  [event] port %u (%s) %-12s in thread \"%s\" (lcore %d)\n",
	       ms_now(), port, name, evname[ev], thread_name(),
	       (int)rte_lcore_id() == (int)LCORE_ID_ANY ? -1 : (int)rte_lcore_id());
	atomic_fetch_add(&n_events, 1);
	if (ev == RTE_ETH_EVENT_INTR_LSC)
		rte_eal_alarm_set(2000, deferred_link_check, (void *)(uintptr_t)port);
	return 0;
}

static void
on_dev_event(const char *dev, enum rte_dev_event_type t, void *arg)
{
	(void)arg;
	printf("  %8.1f ms  [uevent] %s %s\n", ms_now(), dev,
	       t == RTE_DEV_EVENT_ADD ? "ADD" : "REMOVE");
}

static uint16_t
port_of(const char *name)
{
	uint16_t p;

	if (rte_eth_dev_get_port_by_name(name, &p) != 0)
		rte_exit(EXIT_FAILURE, "no port %s\n", name);
	return p;
}

int
main(int argc, char **argv)
{
	static const enum rte_eth_event_type watch[] = {
		RTE_ETH_EVENT_INTR_LSC, RTE_ETH_EVENT_QUEUE_STATE,
		RTE_ETH_EVENT_INTR_RESET, RTE_ETH_EVENT_INTR_RMV,
		RTE_ETH_EVENT_NEW, RTE_ETH_EVENT_DESTROY,
		RTE_ETH_EVENT_ERR_RECOVERING, RTE_ETH_EVENT_RECOVERY_SUCCESS,
		RTE_ETH_EVENT_RECOVERY_FAILED,
	};
	struct rte_mempool *mp;
	struct rte_eth_dev_info di;
	struct rte_eth_conf lsc_conf = { .intr_conf.lsc = 1 };
	struct rte_mbuf *b[32];
	char devargs[512];
	uint16_t p, null7, pcap, vh, vu;
	unsigned i, got;
	int rc, ret;

	setvbuf(stdout, NULL, _IOLBF, 0);
	ret = rte_eal_init(argc, argv);
	if (ret < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	argc -= ret;
	argv += ret;
	if (argc < 3)
		rte_exit(EXIT_FAILURE, "usage: events <EAL> -- tiny.pcap vhost.sock\n");
	t0 = rte_get_timer_cycles();
	printf("main thread is \"%s\"\n", thread_name());

	for (i = 0; i < RTE_DIM(watch); i++)
		rte_eth_dev_callback_register(RTE_ETH_ALL, watch[i], on_event, NULL);
	mp = rte_pktmbuf_pool_create("evt_pool", 2047, 32, 0,
				     RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
	if (!mp)
		rte_exit(EXIT_FAILURE, "pool\n");

	printf("\n-- 1. hotplug: rte_dev_probe(\"net_null7\")\n");
	rc = rte_dev_probe("net_null7");
	printf("  rte_dev_probe -> %s, ports now: %u\n", rcname(rc),
	       rte_eth_dev_count_avail());
	null7 = port_of("net_null7");

	printf("\n-- 2. net_pcap with eof=1: link goes down at end of file\n");
	snprintf(devargs, sizeof(devargs), "net_pcap0,rx_pcap=%s,tx_pcap=/dev/null,eof=1",
		 argv[1]);
	rc = rte_dev_probe(devargs);
	pcap = port_of("net_pcap0");
	if (rte_eth_dev_info_get(pcap, &di) == 0)
		printf("  pcap port %u: RTE_ETH_DEV_INTR_LSC flag = %d\n", pcap,
		       !!(*di.dev_flags & RTE_ETH_DEV_INTR_LSC));
	rc = ch12_port_init(pcap, 1, 1, mp, &lsc_conf, NULL, 1);
	printf("  configured with intr_conf.lsc=1, start -> %s\n", rcname(rc));
	for (got = 0, i = 0; i < 100; i++) {
		uint16_t k = rte_eth_rx_burst(pcap, 0, b, 32);

		got += k;
		rte_pktmbuf_free_bulk(b, k);
		rte_delay_us_sleep(1000);
	}
	printf("  received %u packets, then EOF\n", got);
	rte_delay_ms(20);

	printf("\n-- 3. vhost server + virtio_user client in one process\n");
	snprintf(devargs, sizeof(devargs), "net_vhost0,iface=%s,queues=1", argv[2]);
	rc = rte_dev_probe(devargs);
	printf("  probe %s -> %s\n", devargs, rcname(rc));
	vh = port_of("net_vhost0");
	rc = ch12_port_init(vh, 1, 1, mp, &lsc_conf, NULL, 1);
	printf("  vhost port %u started -> %s (link down until a driver connects)\n",
	       vh, rcname(rc));
	snprintf(devargs, sizeof(devargs), "virtio_user0,path=%s,queues=1", argv[2]);
	rc = rte_dev_probe(devargs);
	printf("  probe virtio_user0 -> %s\n", rcname(rc));
	vu = port_of("virtio_user0");
	rc = ch12_port_init(vu, 1, 1, mp, NULL, NULL, 1);
	printf("  virtio_user port %u started -> %s\n", vu, rcname(rc));
	rte_delay_ms(100);
	printf("  stopping virtio_user (the 'VM' goes away)\n");
	rte_eth_dev_stop(vu);
	rte_delay_ms(100);
	if (rte_eth_dev_info_get(vu, &di) == 0) {
		rte_eth_dev_close(vu);
		rte_dev_remove(di.device);
	}
	rte_delay_ms(50);

	printf("\n-- 4. hot-unplug net_null7: stop, close, rte_dev_remove\n");
	if (rte_eth_dev_info_get(null7, &di) == 0) {
		struct rte_device *dev = di.device;	/* save before close */

		rte_eth_dev_stop(null7);
		rc = rte_eth_dev_close(null7);
		printf("  rte_eth_dev_close -> %s\n", rcname(rc));
		rc = rte_dev_remove(dev);
		printf("  rte_dev_remove -> %s, ports now: %u\n", rcname(rc),
		       rte_eth_dev_count_avail());
	}

	printf("\n-- 5. kernel device event monitor\n");
	rc = rte_dev_event_callback_register(NULL, on_dev_event, NULL);
	printf("  rte_dev_event_callback_register(all devices) -> %s\n", rcname(rc));
	rc = rte_dev_event_monitor_start();
	printf("  rte_dev_event_monitor_start -> %s\n", rcname(rc));
	printf("  creating and deleting veth pair ch12a/ch12b (uevents: SUBSYSTEM=net)\n");
	if (system("ip link add ch12a type veth peer name ch12b") != 0)
		printf("  (ip link add failed)\n");
	rte_delay_ms(300);
	if (system("ip link del ch12a") != 0)
		printf("  (ip link del failed)\n");
	rte_delay_ms(300);
	printf("  -> no [uevent] lines: the monitor only parses pci/uio/vfio uevents\n");
	rte_dev_event_monitor_stop();
	rte_dev_event_callback_unregister(NULL, on_dev_event, NULL);

	printf("\n%d ethdev events seen. Closing remaining ports.\n",
	       atomic_load(&n_events));
	RTE_ETH_FOREACH_DEV(p) {
		rte_eth_dev_stop(p);
		rte_eth_dev_close(p);
	}
	rte_eal_alarm_cancel(deferred_link_check, (void *)-1); /* -1 = any arg */
	rte_mempool_free(mp);
	rte_eal_cleanup();
	return 0;
}
