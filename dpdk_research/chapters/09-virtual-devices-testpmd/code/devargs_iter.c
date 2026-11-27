/* SPDX-License-Identifier: BSD-3-Clause
 *
 * devargs_iter.c - Chapter 9: find devices with devargs filter strings.
 *
 * After rte_eal_init() has probed the --vdev devices, this program:
 *   1. walks every device of every bus with RTE_DEV_FOREACH and prints the
 *      bus / name / driver / NUMA node / devargs of each (the device model),
 *   2. runs a list of filter strings through RTE_ETH_FOREACH_MATCHING_DEV
 *      and prints which ethdev ports each one visits. One filter uses the
 *      MAC address of port 1, read at run time,
 *   3. parses a few allow-list (-a) style strings with rte_devargs_parse()
 *      to show the bus / name / args split, including PCI ones.
 * Extra filter strings can be given after "--".
 *
 * Run:
 *   ./devargs_iter -l 0 --no-pci --no-huge -m 128 --file-prefix=ch09-iter \
 *       --vdev=net_null0 --vdev=net_null1 --vdev=net_ring0
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <rte_eal.h>
#include <rte_debug.h>
#include <rte_errno.h>
#include <rte_dev.h>
#include <rte_devargs.h>
#include <rte_bus.h>
#include <rte_ethdev.h>
#include <rte_cryptodev.h>

/* Part 1: the generic device iterator works on rte_device, any class. */
static void
list_devices(const char *filter)
{
	struct rte_dev_iterator it;
	struct rte_device *dev;
	unsigned int n = 0;
	/* rte_dev_iterator_init() splits a multi-layer string ("bus=../class=..")
	 * IN PLACE (it writes '\0' over each '/') and the iterator keeps
	 * pointers into it. So pass a writable buffer that outlives the loop:
	 * a string literal with a '/' would crash with SIGSEGV. */
	char buf[128];

	snprintf(buf, sizeof(buf), "%s", filter);
	printf("\nRTE_DEV_FOREACH(dev, \"%s\")\n", filter);
	RTE_DEV_FOREACH(dev, buf, &it) {
		const struct rte_devargs *da = rte_dev_devargs(dev);
		const struct rte_driver *drv = rte_dev_driver(dev);

		printf("   %-14s bus=%-5s driver=%-12s numa=%d probed=%d args=\"%s\"\n",
		       rte_dev_name(dev), rte_bus_name(rte_dev_bus(dev)),
		       drv ? rte_driver_name(drv) : "-", rte_dev_numa_node(dev),
		       rte_dev_is_probed(dev), (da && da->args) ? da->args : "");
		n++;
	}
	printf("   -> %u device%s\n", n, n == 1 ? "" : "s");
}

/* Part 2: the ethdev iterator yields port ids. If the loop is left early
 * with break, rte_eth_iterator_cleanup() must be called; running to the
 * end cleans up automatically. */
static void
match_ports(const char *filter)
{
	struct rte_dev_iterator it;
	uint16_t port;
	char buf[256];
	int len = 0;

	/* rte_eth_iterator_init() rejects some strings; check it first so we
	 * can print the reason instead of silently matching nothing. */
	int ret = rte_eth_iterator_init(&it, filter);
	if (ret < 0) {
		printf("   %-46s -> error %d (%s)\n", filter, ret, rte_strerror(-ret));
		return;
	}
	rte_eth_iterator_cleanup(&it);

	buf[0] = '\0';
	RTE_ETH_FOREACH_MATCHING_DEV(port, filter, &it) {
		char name[RTE_ETH_NAME_MAX_LEN];

		if (rte_eth_dev_get_name_by_port(port, name, sizeof(name)) != 0)
			snprintf(name, sizeof(name), "?");
		len += snprintf(buf + len, sizeof(buf) - len, " %u(%s)", port, name);
		if (len >= (int)sizeof(buf))
			break;   /* not reached here; shows where cleanup would go */
	}
	printf("   %-46s ->%s\n", filter, buf[0] ? buf : " (no port)");
}

static void
parse_one(const char *s)
{
	struct rte_devargs da;
	int ret;

	memset(&da, 0, sizeof(da));
	ret = rte_devargs_parse(&da, s);
	if (ret < 0) {
		printf("   %-36s -> error %d\n", s, ret);
		return;
	}
	printf("   %-36s -> bus=%-4s name=%-14s args=\"%s\"\n", s,
	       da.bus ? rte_bus_name(da.bus) : "?", da.name, da.args ? da.args : "");
	rte_devargs_reset(&da);
}

int
main(int argc, char **argv)
{
	struct rte_ether_addr mac1;
	char macfilter[64];
	int ret, i;

	ret = rte_eal_init(argc, argv);
	if (ret < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	argc -= ret;
	argv += ret;

	/* the device model, whole and filtered */
	list_devices("");               /* empty string: every bus, every device */
	list_devices("bus=vdev");
	list_devices("bus=vdev,name=net_ring0");
	list_devices("class=eth");      /* generic iterator: class layer only */
	list_devices("bus=vdev/class=eth");

	/* build a MAC filter from port 1 (net_null picks a random MAC) */
	if (rte_eth_macaddr_get(1, &mac1) != 0)
		rte_exit(EXIT_FAILURE, "need at least 2 ports\n");
	snprintf(macfilter, sizeof(macfilter), "class=eth,mac=" RTE_ETHER_ADDR_PRT_FMT,
		 RTE_ETHER_ADDR_BYTES(&mac1));

	printf("\nRTE_ETH_FOREACH_MATCHING_DEV(port, filter)\n");
	match_ports("class=eth,");          /* pure class filter, no property: all */
	match_ports(macfilter);             /* class property: mac= */
	match_ports("class=eth,mac=00:00:00:00:00:00");   /* net_ring0's MAC */
	match_ports("net_ring0");           /* simplified syntax: device name */
	match_ports("vdev:net_null1");      /* simplified syntax with bus prefix */
	match_ports("net_null0,size=64");   /* old-syntax args are ignored ("+") */
	match_ports("nosuch0");             /* no bus knows this name */
	match_ports("class=crypto");        /* not an ethdev filter */
	match_ports("bus=vdev/class=eth/driver=net_null");   /* parses, matches nothing */
	printf("\nrte_devargs_parse() on -a / --vdev style strings\n");
	parse_one("0000:02:00.0");
	parse_one("02:00.0,txq_inline=128");
	parse_one("pci:0000:02:00.0,rx_low_latency=1");
	parse_one("net_null0,size=128");
	parse_one("vdev:net_tap0,iface=ch09tap0");


	/* user filters (and the --crash demo) last */
	for (i = 1; i < argc; i++) {
		/* "--crash" reproduces the trap described in the chapter:
		 * a filter whose driver part is empty ("class=eth" with no
		 * comma, "bus=vdev", "bus=pci", "bus=vdev/class=eth") makes
		 * rte_eth_iterator_init() call strlen(NULL) in DPDK 26.11 and
		 * the process dies with SIGSEGV. RTE_DEV_FOREACH accepts them. */
		if (strcmp(argv[i], "--crash") == 0) {
			printf("   now trying \"bus=vdev\" with the ethdev iterator...\n");
			fflush(stdout);
			match_ports("bus=vdev");
			continue;
		}
		match_ports(argv[i]);
	}

	rte_eal_cleanup();
	return 0;
}
