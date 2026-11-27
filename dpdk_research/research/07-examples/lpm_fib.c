/* lpm_fib.c - same routes in rte_lpm, rte_fib (DIR24_8) and rte_rib; show LPM
 * semantics (/8 vs /24 vs /32), tbl8 usage, and per-lookup cost.
 * run: ./lpm_fib --no-huge -m 256 --no-pci --file-prefix=ch07lpm */
#include <stdio.h>
#include <rte_eal.h>
#include <rte_ip.h>
#include <rte_lpm.h>
#include <rte_fib.h>
#include <rte_rib.h>
#include <rte_cycles.h>
#include <rte_random.h>

static const struct { uint32_t ip; uint8_t depth; uint32_t nh; } routes[] = {
	{ RTE_IPV4(10, 0, 0, 0), 8, 1 },
	{ RTE_IPV4(10, 1, 0, 0), 16, 2 },
	{ RTE_IPV4(10, 1, 2, 0), 24, 3 },
	{ RTE_IPV4(10, 1, 2, 128), 25, 4 },   /* > 24 -> needs a tbl8 group */
	{ RTE_IPV4(10, 1, 2, 200), 32, 5 },
};
static const uint32_t probes[] = {
	RTE_IPV4(10, 9, 9, 9), RTE_IPV4(10, 1, 9, 9), RTE_IPV4(10, 1, 2, 3),
	RTE_IPV4(10, 1, 2, 130), RTE_IPV4(10, 1, 2, 200), RTE_IPV4(11, 0, 0, 1),
};
#define NB (1 << 20)
static uint32_t ips[NB]; static uint64_t nhs[NB]; static uint32_t nh32[NB];

int main(int argc, char **argv)
{
	if (rte_eal_init(argc, argv) < 0) return 1;
	struct rte_lpm_config lc = { .max_rules = 1024, .number_tbl8s = 256 };
	struct rte_lpm *lpm = rte_lpm_create("lpm", SOCKET_ID_ANY, &lc);
	struct rte_fib_conf fc = { .type = RTE_FIB_DIR24_8, .default_nh = 0, .max_routes = 1024,
		.dir24_8 = { .nh_sz = RTE_FIB_DIR24_8_4B, .num_tbl8 = 256 } };
	struct rte_fib *fib = rte_fib_create("fib", SOCKET_ID_ANY, &fc);
	if (!lpm || !fib) { printf("create failed\n"); return 1; }
	for (unsigned i = 0; i < RTE_DIM(routes); i++) {
		rte_lpm_add(lpm, routes[i].ip, routes[i].depth, routes[i].nh);
		rte_fib_add(fib, routes[i].ip, routes[i].depth, routes[i].nh);
	}
	struct rte_rib *rib = rte_fib_get_rib(fib);  /* FIB keeps a RIB as control-plane copy */
	printf("%-16s %-6s %-6s %-20s\n", "probe", "lpm", "fib", "rib best match");
	for (unsigned i = 0; i < RTE_DIM(probes); i++) {
		uint32_t nh = 0; uint64_t fnh; uint32_t ip = probes[i];
		int r = rte_lpm_lookup(lpm, ip, &nh);
		rte_fib_lookup_bulk(fib, &ip, &fnh, 1);
		struct rte_rib_node *n = rte_rib_lookup(rib, ip);
		uint32_t rip = 0; uint8_t d = 0;
		if (n) { rte_rib_get_ip(n, &rip); rte_rib_get_depth(n, &d); }
		printf("%u.%u.%u.%-8u %-6s %-6lu %u.%u.%u.%u/%u\n", ip >> 24, (ip >> 16) & 255,
		       (ip >> 8) & 255, ip & 255, r == 0 ? (char[8]){'0' + nh, 0} : "miss",
		       (unsigned long)fnh, rip >> 24, (rip >> 16) & 255, (rip >> 8) & 255, rip & 255, d);
	}
	/* perf: 1M random addrs, mostly inside 10/8 */
	for (int i = 0; i < NB; i++) ips[i] = RTE_IPV4(10, 1, 2, 0) | (rte_rand() & 0xff);
	uint64_t t0 = rte_rdtsc();
	for (int i = 0; i < NB; i++) rte_lpm_lookup(lpm, ips[i], &nh32[i]);
	uint64_t t1 = rte_rdtsc();
	uint64_t t2 = rte_rdtsc();
	rte_fib_lookup_bulk(fib, ips, nhs, NB);
	uint64_t t3 = rte_rdtsc();
	printf("lpm single %.1f cyc/lookup, fib bulk %.1f cyc/lookup (ips in 10.1.2.0/24, half hit tbl8)\n",
	       (double)(t1 - t0) / NB, (double)(t3 - t2) / NB);
	rte_eal_cleanup();
	return 0;
}
