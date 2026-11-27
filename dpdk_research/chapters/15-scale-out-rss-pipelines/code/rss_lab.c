/* SPDX-License-Identifier: BSD-3-Clause
 *
 * rss_lab.c - Chapter 15: RSS from the bits up.
 *
 *   Part A  rte_softrss() against the Microsoft/Intel RSS verification suite
 *   Part B  forward vs reverse direction: default key vs symmetric 0x6d5a key,
 *           and a software model of RTE_ETH_HASH_FUNCTION_SYMMETRIC_TOEPLITZ_SORT
 *   Part C  10000 flows -> 32-bit hash -> low 7 bits -> 128-entry RETA -> queue
 *   Part D  rte_thash_adjust_tuple(): choose source ports that land on a
 *           chosen queue (the SNAT trick), verified with rte_softrss()
 *   Part E  a real port (net_null0): dev_info RSS capabilities, rss_algo_capa
 *           printed with rte_eth_dev_rss_algo_name(), what configure rejects,
 *           RETA update + query, and why net_null's per-queue counters do
 *           not follow the RETA (they are poll-driven).
 *
 * Run:  ./rss_lab -l 0 --no-pci --no-huge -m 128 --file-prefix=ch15-rss \
 *                 --vdev=net_null0
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <inttypes.h>
#include <arpa/inet.h>

#include <rte_eal.h>
#include <rte_ethdev.h>
#include <rte_mbuf.h>
#include <rte_thash.h>
#include <rte_ip.h>
#include <rte_errno.h>
#include <rte_random.h>

/* The 40-byte key from the Microsoft RSS specification. Many NICs ship it
 * as their default key, and the verification vectors below use it. */
static uint8_t ms_key[40] = {
	0x6d, 0x5a, 0x56, 0xda, 0x25, 0x5b, 0x0e, 0xc2,
	0x41, 0x67, 0x25, 0x3d, 0x43, 0xa3, 0x8f, 0xb0,
	0xd0, 0xca, 0x2b, 0xcb, 0xae, 0x7b, 0x30, 0xb4,
	0x77, 0xcb, 0x2d, 0xa3, 0x80, 0x30, 0xf2, 0x0c,
	0x6a, 0x42, 0xb7, 0x3b, 0xbe, 0xac, 0x01, 0xfa,
};

/* Verification suite (same table as app/test/test_thash.c). */
static const struct {
	uint32_t dst, src;
	uint16_t dport, sport;
	uint32_t want_l3, want_l3l4;
} vec[] = {
	{ RTE_IPV4(161, 142, 100, 80), RTE_IPV4(66, 9, 149, 187),
	  1766, 2794, 0x323e8fc2, 0x51ccc178 },
	{ RTE_IPV4(65, 69, 140, 83), RTE_IPV4(199, 92, 111, 2),
	  4739, 14230, 0xd718262a, 0xc626b0ea },
	{ RTE_IPV4(12, 22, 207, 184), RTE_IPV4(24, 19, 198, 95),
	  38024, 12898, 0xd2d0a5de, 0x5c2b394a },
};

#define RETA_SIZE 128	/* entries; hash & 127 picks one */
#define NB_Q      4

/* Hash an IPv4 5-tuple. struct rte_ipv4_tuple wants CPU byte order. */
static uint32_t
hash_v4(uint32_t src, uint32_t dst, uint16_t sport, uint16_t dport,
	const uint8_t *key)
{
	struct rte_ipv4_tuple t = {
		.src_addr = src, .dst_addr = dst, .sport = sport, .dport = dport,
	};
	return rte_softrss((uint32_t *)&t, RTE_THASH_V4_L4_LEN, key);
}

/* Software model of SYMMETRIC_TOEPLITZ_SORT: sort addresses and ports
 * before hashing, so (a->b) and (b->a) produce the same input. */
static uint32_t
hash_v4_sorted(uint32_t src, uint32_t dst, uint16_t sport, uint16_t dport,
	       const uint8_t *key)
{
	if (src > dst) { uint32_t x = src; src = dst; dst = x; }
	if (sport > dport) { uint16_t x = sport; sport = dport; dport = x; }
	return hash_v4(src, dst, sport, dport, key);
}

static void
part_a(void)
{
	unsigned int i;
	uint32_t be_key[40 / 4];

	printf("== Part A: rte_softrss() vs the RSS verification suite ==\n");
	/* rte_softrss_be() is faster but needs the key pre-converted to
	 * CPU-order 32-bit words with rte_convert_rss_key(). */
	rte_convert_rss_key((const uint32_t *)ms_key, be_key, sizeof(ms_key));
	for (i = 0; i < RTE_DIM(vec); i++) {
		struct rte_ipv4_tuple t = {
			.src_addr = vec[i].src, .dst_addr = vec[i].dst,
			.sport = vec[i].sport, .dport = vec[i].dport,
		};
		uint32_t l3 = rte_softrss((uint32_t *)&t, RTE_THASH_V4_L3_LEN, ms_key);
		uint32_t l4 = rte_softrss((uint32_t *)&t, RTE_THASH_V4_L4_LEN, ms_key);
		uint32_t l4be = rte_softrss_be((uint32_t *)&t, RTE_THASH_V4_L4_LEN,
					       (const uint8_t *)be_key);
		printf("  vector %u: ip-only 0x%08x (%s)  ip+ports 0x%08x (%s)  softrss_be 0x%08x\n",
		       i, l3, l3 == vec[i].want_l3 ? "ok" : "MISMATCH",
		       l4, l4 == vec[i].want_l3l4 ? "ok" : "MISMATCH", l4be);
	}
	printf("  GFNI Toeplitz available on this CPU: %s\n",
	       rte_thash_gfni_supported() ? "yes" : "no");
}

static void
part_b(void)
{
	uint8_t sym_key[40];
	uint32_t a = RTE_IPV4(10, 15, 0, 1), b = RTE_IPV4(10, 15, 0, 2);
	unsigned int i;

	/* 0x6d5a repeated: every 16-bit window of the key is the same, so
	 * swapping src<->dst (32 bits) and sport<->dport (16 bits) cannot
	 * change the result. */
	for (i = 0; i < sizeof(sym_key); i += 2) {
		sym_key[i] = 0x6d;
		sym_key[i + 1] = 0x5a;
	}
	printf("\n== Part B: both directions of one TCP connection ==\n");
	printf("  flow 10.15.0.1:40000 -> 10.15.0.2:80 and its reply\n");
	printf("  default key     fwd 0x%08x  rev 0x%08x  -> queues %u / %u\n",
	       hash_v4(a, b, 40000, 80, ms_key), hash_v4(b, a, 80, 40000, ms_key),
	       (hash_v4(a, b, 40000, 80, ms_key) & (RETA_SIZE - 1)) % NB_Q,
	       (hash_v4(b, a, 80, 40000, ms_key) & (RETA_SIZE - 1)) % NB_Q);
	printf("  0x6d5a key      fwd 0x%08x  rev 0x%08x  -> queues %u / %u\n",
	       hash_v4(a, b, 40000, 80, sym_key), hash_v4(b, a, 80, 40000, sym_key),
	       (hash_v4(a, b, 40000, 80, sym_key) & (RETA_SIZE - 1)) % NB_Q,
	       (hash_v4(b, a, 80, 40000, sym_key) & (RETA_SIZE - 1)) % NB_Q);
	printf("  sort model      fwd 0x%08x  rev 0x%08x  (default key, fields sorted first)\n",
	       hash_v4_sorted(a, b, 40000, 80, ms_key),
	       hash_v4_sorted(b, a, 80, 40000, ms_key));
}

static void
part_c(void)
{
	unsigned int q[NB_Q] = {0}, q_sym[NB_Q] = {0}, s;
	uint8_t reta[RETA_SIZE], sym_key[40];
	unsigned int i;

	for (i = 0; i < sizeof(sym_key); i += 2) {
		sym_key[i] = 0x6d;
		sym_key[i + 1] = 0x5a;
	}
	for (i = 0; i < RETA_SIZE; i++)
		reta[i] = i % NB_Q;	/* the usual default fill */

	rte_srand(15);
	for (s = 0; s < 10000; s++) {
		uint32_t src = RTE_IPV4(10, 0, 0, 0) | (rte_rand() & 0xffff);
		uint16_t sport = 1024 + (rte_rand() % 60000);
		uint32_t dst = RTE_IPV4(192, 0, 2, 1);
		q[reta[hash_v4(src, dst, sport, 443, ms_key) & (RETA_SIZE - 1)]]++;
		q_sym[reta[hash_v4(src, dst, sport, 443, sym_key) & (RETA_SIZE - 1)]]++;
	}
	printf("\n== Part C: 10000 random flows -> RETA[hash & 127] -> queue ==\n");
	printf("  default key : q0 %u  q1 %u  q2 %u  q3 %u\n", q[0], q[1], q[2], q[3]);
	printf("  0x6d5a key  : q0 %u  q1 %u  q2 %u  q3 %u\n",
	       q_sym[0], q_sym[1], q_sym[2], q_sym[3]);
}

/* Part D: tuple bytes are in network order: src(4) dst(4) sport(2) dport(2) */
static void
part_d(void)
{
	struct rte_thash_ctx *ctx;
	struct rte_thash_subtuple_helper *h;
	const uint8_t *key;
	unsigned int q;
	int ret;

	printf("\n== Part D: rte_thash_adjust_tuple(): pick a source port per queue ==\n");
	/* reta_sz is log2 of the RETA size: 7 -> 128 entries. Start from the
	 * Microsoft key (a copy: the context changes its own key). */
	ctx = rte_thash_init_ctx("ch15_snat", sizeof(ms_key), 7, ms_key, 0);
	if (ctx == NULL) {
		printf("  rte_thash_init_ctx failed: %s\n", rte_strerror(rte_errno));
		return;
	}
	/* The helper owns 16 bits at bit offset 64: the source port. */
	ret = rte_thash_add_helper(ctx, "sport", 16, 64);
	if (ret != 0) {
		printf("  rte_thash_add_helper failed: %d\n", ret);
		rte_thash_free_ctx(ctx);
		return;
	}
	h = rte_thash_get_helper(ctx, "sport");
	key = rte_thash_get_key(ctx);	/* NEW key: it must be programmed into the NIC */
	/* The helper rewrites the key bits that multiply the source port
	 * (key bits 64..64+16+31), so compare bytes 8..13. */
	printf("  key bytes 8..13 after add_helper: %02x %02x %02x %02x %02x %02x"
	       " (Microsoft key: %02x %02x %02x %02x %02x %02x)\n",
	       key[8], key[9], key[10], key[11], key[12], key[13],
	       ms_key[8], ms_key[9], ms_key[10], ms_key[11], ms_key[12], ms_key[13]);

	for (q = 0; q < NB_Q; q++) {
		uint8_t tuple[12];
		uint32_t w[3], hash;
		uint32_t src = htonl(RTE_IPV4(10, 15, 1, 1));
		uint32_t dst = htonl(RTE_IPV4(198, 51, 100, 7));
		uint16_t sport = htons(30000), dport = htons(443);

		memcpy(tuple, &src, 4);
		memcpy(tuple + 4, &dst, 4);
		memcpy(tuple + 8, &sport, 2);
		memcpy(tuple + 10, &dport, 2);
		/* desired_value = RETA index; with RETA[i] = i % 4, index q -> queue q */
		ret = rte_thash_adjust_tuple(ctx, h, tuple, sizeof(tuple), q, 1, NULL, NULL);
		if (ret != 0) {
			printf("  queue %u: adjust failed %d\n", q, ret);
			continue;
		}
		/* verify with the generic software hash (CPU-order words) */
		for (unsigned int i = 0; i < 3; i++) {
			uint32_t be;
			memcpy(&be, tuple + 4 * i, 4);
			w[i] = ntohl(be);
		}
		hash = rte_softrss(w, 3, key);
		memcpy(&sport, tuple + 8, 2);
		printf("  want queue %u: sport 30000 -> %5u  hash 0x%08x  RETA idx %3u -> queue %u\n",
		       q, ntohs(sport), hash, hash & (RETA_SIZE - 1),
		       (hash & (RETA_SIZE - 1)) % NB_Q);
	}
	rte_thash_free_ctx(ctx);
}

static void
print_reta_histogram(uint16_t port, uint16_t reta_size, const char *what)
{
	struct rte_eth_rss_reta_entry64 conf[RETA_SIZE / RTE_ETH_RETA_GROUP_SIZE];
	unsigned int cnt[NB_Q] = {0}, i;

	memset(conf, 0, sizeof(conf));
	for (i = 0; i < RTE_DIM(conf); i++)
		conf[i].mask = UINT64_MAX;	/* query all 64 entries of each group */
	if (rte_eth_dev_rss_reta_query(port, conf, reta_size) != 0) {
		printf("  reta_query failed\n");
		return;
	}
	for (i = 0; i < reta_size; i++)
		cnt[conf[i / RTE_ETH_RETA_GROUP_SIZE].reta[i % RTE_ETH_RETA_GROUP_SIZE] % NB_Q]++;
	printf("  RETA %-9s entries per queue: q0 %u  q1 %u  q2 %u  q3 %u   first 16:",
	       what, cnt[0], cnt[1], cnt[2], cnt[3]);
	for (i = 0; i < 16; i++)
		printf(" %u", conf[0].reta[i]);
	printf("\n");
}

static void
print_queue_xstats(uint16_t port)
{
	struct rte_eth_xstat_name *names;
	struct rte_eth_xstat *xs;
	int n = rte_eth_xstats_get_names(port, NULL, 0), i;

	if (n <= 0)
		return;
	names = calloc(n, sizeof(*names));
	xs = calloc(n, sizeof(*xs));
	rte_eth_xstats_get_names(port, names, n);
	rte_eth_xstats_get(port, xs, n);
	printf("  per-queue xstats:");
	for (i = 0; i < n; i++)
		if (strstr(names[xs[i].id].name, "rx_q") &&
		    strstr(names[xs[i].id].name, "_packets"))
			printf(" %s=%" PRIu64, names[xs[i].id].name, xs[i].value);
	printf("\n");
	free(names);
	free(xs);
}

static void
part_e(uint16_t port)
{
	struct rte_eth_dev_info info;
	struct rte_eth_conf conf;
	struct rte_mempool *mp;
	struct rte_eth_rss_reta_entry64 reta[RETA_SIZE / RTE_ETH_RETA_GROUP_SIZE];
	struct rte_eth_rss_conf rc;
	uint8_t key[64];
	uint32_t algo;
	unsigned int i, q;
	int ret;

	printf("\n== Part E: RSS on a real ethdev port (net_null0) ==\n");
	if (rte_eth_dev_info_get(port, &info) != 0)
		return;
	printf("  driver %s: max_rx_queues %u, reta_size %u, hash_key_size %u\n",
	       info.driver_name, info.max_rx_queues, info.reta_size, info.hash_key_size);
	printf("  flow_type_rss_offloads 0x%" PRIx64 "\n", info.flow_type_rss_offloads);
	printf("  rss_algo_capa 0x%x:", info.rss_algo_capa);
	for (i = 0; i < RTE_ETH_HASH_FUNCTION_MAX; i++)
		if (info.rss_algo_capa & RTE_ETH_HASH_ALGO_TO_CAPA(i))
			printf(" %s", rte_eth_dev_rss_algo_name(i));
	printf("\n");
	if (rte_eth_find_rss_algo("symmetric_toeplitz_sort", &algo) == 0)
		printf("  rte_eth_find_rss_algo(\"symmetric_toeplitz_sort\") = %u\n", algo);

	mp = rte_pktmbuf_pool_create("ch15_rss_pool", 2047, 64, 0,
				     RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
	if (mp == NULL) {
		printf("  pool: %s\n", rte_strerror(rte_errno));
		return;
	}

	/* 1. Ask for an algorithm the port does not advertise. */
	memset(&conf, 0, sizeof(conf));
	conf.rxmode.mq_mode = RTE_ETH_MQ_RX_RSS;
	conf.rx_adv_conf.rss_conf.rss_hf = RTE_ETH_RSS_IP | RTE_ETH_RSS_UDP | RTE_ETH_RSS_TCP;
	conf.rx_adv_conf.rss_conf.algorithm = RTE_ETH_HASH_FUNCTION_SYMMETRIC_TOEPLITZ;
	ret = rte_eth_dev_configure(port, NB_Q, NB_Q, &conf);
	printf("  configure(algorithm=symmetric_toeplitz) -> %d (%s)\n", ret,
	       ret ? rte_strerror(-ret) : "ok");

	/* 2. A key of the wrong length. */
	conf.rx_adv_conf.rss_conf.algorithm = RTE_ETH_HASH_FUNCTION_DEFAULT;
	conf.rx_adv_conf.rss_conf.rss_key = key;
	conf.rx_adv_conf.rss_conf.rss_key_len = 52;
	memset(key, 0x6d, sizeof(key));
	ret = rte_eth_dev_configure(port, NB_Q, NB_Q, &conf);
	printf("  configure(rss_key_len=52) -> %d (%s)\n", ret,
	       ret ? rte_strerror(-ret) : "ok");

	/* 3. The right way: mask rss_hf with what the port supports, give a
	 *    key of exactly hash_key_size bytes (here: the symmetric key). */
	for (i = 0; i < info.hash_key_size; i += 2) {
		key[i] = 0x6d;
		key[i + 1] = 0x5a;
	}
	conf.rx_adv_conf.rss_conf.rss_key_len = info.hash_key_size;
	conf.rx_adv_conf.rss_conf.rss_hf &= info.flow_type_rss_offloads;
	ret = rte_eth_dev_configure(port, NB_Q, NB_Q, &conf);
	printf("  configure(4 rxq, RSS, 40-byte 0x6d5a key, rss_hf 0x%" PRIx64 ") -> %d\n",
	       conf.rx_adv_conf.rss_conf.rss_hf, ret);
	if (ret != 0)
		return;
	for (q = 0; q < NB_Q; q++) {
		rte_eth_rx_queue_setup(port, q, 256, rte_socket_id(), NULL, mp);
		rte_eth_tx_queue_setup(port, q, 256, rte_socket_id(), NULL);
	}
	if (rte_eth_dev_start(port) != 0) {
		printf("  start failed\n");
		return;
	}

	memset(&rc, 0, sizeof(rc));
	rc.rss_key = key;
	rc.rss_key_len = sizeof(key);
	memset(key, 0, sizeof(key));
	rte_eth_dev_rss_hash_conf_get(port, &rc);
	printf("  rss_hash_conf_get: rss_hf 0x%" PRIx64 ", key %02x%02x%02x%02x..., algorithm %s\n",
	       rc.rss_hf, key[0], key[1], key[2], key[3],
	       rte_eth_dev_rss_algo_name(rc.algorithm));

	/* net_null ignored the key given to configure (drivers differ!).
	 * rte_eth_dev_rss_hash_update() is the portable way to install it. */
	for (i = 0; i < info.hash_key_size; i += 2) {
		key[i] = 0x6d;
		key[i + 1] = 0x5a;
	}
	rc.rss_key_len = info.hash_key_size;
	rc.rss_hf = conf.rx_adv_conf.rss_conf.rss_hf;
	ret = rte_eth_dev_rss_hash_update(port, &rc);
	memset(key, 0, sizeof(key));
	rte_eth_dev_rss_hash_conf_get(port, &rc);
	printf("  rss_hash_update(0x6d5a key) -> %d; conf_get now: key %02x%02x%02x%02x...\n",
	       ret, key[0], key[1], key[2], key[3]);

	/* Encapsulation level lives in rss_hf bits 50-51. net_null does not
	 * advertise those bits in flow_type_rss_offloads, so ethdev refuses. */
	rc.rss_key = NULL;
	rc.rss_hf = RTE_ETH_RSS_IP | RTE_ETH_RSS_LEVEL_INNERMOST;
	ret = rte_eth_dev_rss_hash_update(port, &rc);
	printf("  rss_hash_update(rss_hf = IP | RTE_ETH_RSS_LEVEL_INNERMOST) -> %d (%s)\n",
	       ret, ret ? rte_strerror(-ret) : "ok");

	/* RETA: net_null starts with all zeros, so set the usual i % 4 fill */
	print_reta_histogram(port, info.reta_size, "at start");
	memset(reta, 0, sizeof(reta));
	for (i = 0; i < info.reta_size; i++) {
		reta[i / RTE_ETH_RETA_GROUP_SIZE].mask |= 1ULL << (i % RTE_ETH_RETA_GROUP_SIZE);
		reta[i / RTE_ETH_RETA_GROUP_SIZE].reta[i % RTE_ETH_RETA_GROUP_SIZE] = i % NB_Q;
	}
	ret = rte_eth_dev_rss_reta_update(port, reta, info.reta_size);
	printf("  reta_update(i %% 4) -> %d\n", ret);
	print_reta_histogram(port, info.reta_size, "i % 4");

	/* Drain queue 3 (e.g. its lcore is overloaded): rewrite only the
	 * entries that point at q3, using the mask so others stay untouched. */
	memset(reta, 0, sizeof(reta));
	for (i = 0; i < info.reta_size; i++) {
		if (i % NB_Q != 3)
			continue;
		reta[i / RTE_ETH_RETA_GROUP_SIZE].mask |= 1ULL << (i % RTE_ETH_RETA_GROUP_SIZE);
		reta[i / RTE_ETH_RETA_GROUP_SIZE].reta[i % RTE_ETH_RETA_GROUP_SIZE] = (i / NB_Q) % 3;
	}
	ret = rte_eth_dev_rss_reta_update(port, reta, info.reta_size);
	printf("  reta_update(move q3 entries to q0..q2, masked) -> %d\n", ret);
	print_reta_histogram(port, info.reta_size, "no q3");

	/* A wrong reta_size is rejected */
	ret = rte_eth_dev_rss_reta_update(port, reta, 64);
	printf("  reta_update(reta_size=64 on a 128-entry port) -> %d (%s)\n", ret,
	       ret ? rte_strerror(-ret) : "ok");

	/* Poll each queue 10 times with bursts of 32. net_null invents packets
	 * on whichever queue is polled: the RETA plays no part. */
	for (q = 0; q < NB_Q; q++) {
		struct rte_mbuf *pkts[32];
		for (i = 0; i < 10; i++) {
			uint16_t n = rte_eth_rx_burst(port, q, pkts, 32);
			rte_pktmbuf_free_bulk(pkts, n);
		}
	}
	print_queue_xstats(port);
	printf("  -> equal counts although q3 has no RETA entries: net_null is poll-driven\n");

	rte_eth_dev_stop(port);
	rte_eth_dev_close(port);
}

int
main(int argc, char **argv)
{
	uint16_t port;

	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");

	part_a();
	part_b();
	part_c();
	part_d();
	RTE_ETH_FOREACH_DEV(port) {
		part_e(port);
		break;
	}
	rte_eal_cleanup();
	return 0;
}
