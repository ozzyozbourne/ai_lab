/* SPDX-License-Identifier: BSD-3-Clause
 *
 * kvargs_demo.c - Chapter 9: parse "key=value,key=value" strings the way a
 * DPDK driver parses its devargs.
 *
 * Part A parses a few fixed strings (and any strings given after "--") with
 * a list of valid keys, like a PMD does in its probe() function:
 *   - a clean string,
 *   - a string with an unknown key  (parse fails when a valid-key list is set),
 *   - a repeated key                 (count == 2, handler called twice),
 *   - a key with no value            (rte_kvargs_process() refuses it,
 *                                     rte_kvargs_process_opt() accepts it),
 *   - a list value "[0,2-3]"         (commas inside [] do not split pairs).
 *
 * Part B looks at the --vdev given on the EAL command line: it finds the
 * device behind every ethdev port, reads the args string the EAL stored in
 * its struct rte_devargs, and re-parses it with net_null's own key list.
 * Part C runs rte_devargs_parse() on a few device strings and prints the
 * bus / name / driver-args split the EAL makes.
 *
 * Run:
 *   ./kvargs_demo -l 0 --no-pci --no-huge -m 64 --file-prefix=ch09-kv \
 *       --vdev=net_null0,size=128 -- 'rate=100,burst=32,mode=fast'
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

#include <rte_eal.h>
#include <rte_debug.h>
#include <rte_kvargs.h>
#include <rte_devargs.h>
#include <rte_dev.h>
#include <rte_bus.h>
#include <rte_ethdev.h>

/* The keys our imaginary driver understands. The array MUST end in NULL. */
static const char *const valid_keys[] = { "rate", "burst", "mode", "queues", NULL };

/* Where the handlers store what they parsed. */
struct my_cfg {
	unsigned long rate;
	unsigned long burst;
	char mode[16];
	unsigned int calls;     /* how many times a handler ran */
};

/* arg_handler_t: called once per matching key=value pair.
 * Return >= 0 for success, < 0 to make rte_kvargs_process() fail. */
static int
parse_ulong(const char *key, const char *value, void *opaque)
{
	unsigned long *out = opaque;
	char *end;

	if (value == NULL) {            /* only happens with _process_opt() */
		printf("    handler(%s): no value\n", key);
		return -1;
	}
	errno = 0;
	*out = strtoul(value, &end, 0);
	if (errno != 0 || *end != '\0') {
		printf("    handler(%s): '%s' is not a number\n", key, value);
		return -1;
	}
	printf("    handler(%s) <- \"%s\" -> %lu\n", key, value, *out);
	return 0;
}

static int
parse_mode(const char *key, const char *value, void *opaque)
{
	struct my_cfg *cfg = opaque;

	cfg->calls++;
	if (value == NULL) {
		/* A bare key ("mode") is legal with _process_opt(): treat it
		 * as a boolean flag meaning "default mode". */
		snprintf(cfg->mode, sizeof(cfg->mode), "default");
		printf("    handler(%s) <- (no value) -> flag set\n", key);
		return 0;
	}
	snprintf(cfg->mode, sizeof(cfg->mode), "%s", value);
	printf("    handler(%s) <- \"%s\"\n", key, value);
	return 0;
}

static int
print_pair(const char *key, const char *value, void *opaque)
{
	(void)opaque;
	printf("    pair: %-8s = %s\n", key, value ? value : "(null)");
	return 0;
}

/* Parse one string exactly like a PMD would. */
static void
demo_string(const char *s)
{
	struct rte_kvargs *kv;
	struct my_cfg cfg = { .rate = 0, .burst = 0, .mode = "none" };
	int ret;

	printf("\n  input \"%s\"\n", s);
	kv = rte_kvargs_parse(s, valid_keys);
	if (kv == NULL) {
		printf("    rte_kvargs_parse(valid_keys) -> NULL (unknown key or bad syntax)\n");
		/* Without a key list every key is accepted. */
		kv = rte_kvargs_parse(s, NULL);
		if (kv == NULL) {
			printf("    rte_kvargs_parse(NULL)       -> NULL too: syntax error\n");
			return;
		}
		printf("    rte_kvargs_parse(NULL)       -> %u pairs (no key check)\n",
		       rte_kvargs_count(kv, NULL));
		rte_kvargs_process_opt(kv, NULL, print_pair, NULL);
		rte_kvargs_free(kv);
		return;
	}

	printf("    %u pairs; count(rate)=%u count(burst)=%u count(mode)=%u\n",
	       rte_kvargs_count(kv, NULL), rte_kvargs_count(kv, "rate"),
	       rte_kvargs_count(kv, "burst"), rte_kvargs_count(kv, "mode"));
	rte_kvargs_process_opt(kv, NULL, print_pair, NULL);

	/* The usual driver pattern: one process() call per key. A key that
	 * is absent simply does not call the handler (ret 0). */
	ret = rte_kvargs_process(kv, "rate", parse_ulong, &cfg.rate);
	if (ret == 0)
		ret = rte_kvargs_process(kv, "burst", parse_ulong, &cfg.burst);
	if (ret == 0) {
		ret = rte_kvargs_process(kv, "mode", parse_mode, &cfg);
		if (ret < 0) {
			printf("    rte_kvargs_process(mode) = %d (key without value)"
			       " -> retry with rte_kvargs_process_opt\n", ret);
			ret = rte_kvargs_process_opt(kv, "mode", parse_mode, &cfg);
		}
	}
	if (rte_kvargs_get(kv, "queues") != NULL)
		printf("    rte_kvargs_get(queues) = \"%s\" (list kept whole)\n",
		       rte_kvargs_get(kv, "queues"));
	printf("    => ret=%d rate=%lu burst=%lu mode=%s (mode handler ran %u time%s)\n",
	       ret, cfg.rate, cfg.burst, cfg.mode, cfg.calls, cfg.calls == 1 ? "" : "s");
	rte_kvargs_free(kv);
}

/* Part B: what a driver sees for the --vdev given on the command line. */
static void
demo_vdev_args(void)
{
	static const char *const null_keys[] = { "size", "copy", "no-rx", NULL };
	uint16_t port;

	printf("\nPart B: devargs of the ports created by --vdev\n");
	RTE_ETH_FOREACH_DEV(port) {
		struct rte_eth_dev_info info;
		const struct rte_devargs *da;
		struct rte_kvargs *kv;

		if (rte_eth_dev_info_get(port, &info) != 0)
			continue;
		da = rte_dev_devargs(info.device);
		printf("  port %u: device \"%s\" bus=%s driver=%s\n", port,
		       rte_dev_name(info.device), rte_bus_name(rte_dev_bus(info.device)),
		       info.driver_name);
		if (da == NULL || da->args == NULL || da->args[0] == '\0') {
			printf("    no driver arguments\n");
			continue;
		}
		printf("    devargs->args = \"%s\"\n", da->args);
		kv = rte_kvargs_parse(da->args, null_keys);
		if (kv == NULL) {
			printf("    not valid for net_null's keys\n");
			continue;
		}
		rte_kvargs_process(kv, NULL, print_pair, NULL);
		rte_kvargs_free(kv);
	}
}

/* Part C: rte_devargs_parse() splits a device string into its layers. */
static void
demo_devargs_parse(void)
{
	static const char *const strs[] = {
		"net_null0,size=128",
		"vdev:net_ring0",
		"net_pcap0,rx_pcap=in.pcap,tx_pcap=out.pcap",
		"bus=vdev,name=net_null0/class=eth/driver=net_null,size=64",
		"nosuchbus:foo0",
	};
	unsigned int i;

	printf("\nPart C: rte_devargs_parse()\n");
	for (i = 0; i < RTE_DIM(strs); i++) {
		struct rte_devargs da;
		int ret;

		memset(&da, 0, sizeof(da));
		ret = rte_devargs_parse(&da, strs[i]);
		printf("  \"%s\"\n", strs[i]);
		if (ret < 0) {
			printf("    -> error %d (%s)\n", ret, rte_strerror(-ret));
			continue;
		}
		printf("    -> bus=%s name=\"%s\" args=\"%s\"\n",
		       da.bus ? rte_bus_name(da.bus) : "(none)", da.name,
		       da.args ? da.args : "");
		if (da.bus_str || da.cls_str)
			printf("       bus_str=\"%s\" cls_str=\"%s\"\n",
			       da.bus_str ? da.bus_str : "", da.cls_str ? da.cls_str : "");
		rte_devargs_reset(&da);   /* frees da.data / layer strings */
	}
}

int
main(int argc, char **argv)
{
	static const char *const builtin[] = {
		"rate=100,colour=red",
		"burst=32,burst=64,mode=slow",
		"rate=10,mode",
		"rate=0x40,queues=[0,2-3],mode=rr",
		"burst=lots",
	};
	unsigned int i;
	int ret;

	ret = rte_eal_init(argc, argv);
	if (ret < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	argc -= ret;
	argv += ret;

	printf("Part A: rte_kvargs_parse() with valid keys {rate, burst, mode, queues}\n");
	for (i = 1; i < (unsigned int)argc; i++)   /* strings after "--" first */
		demo_string(argv[i]);
	for (i = 0; i < RTE_DIM(builtin); i++)
		demo_string(builtin[i]);

	demo_vdev_args();
	demo_devargs_parse();

	rte_eal_cleanup();
	return 0;
}
