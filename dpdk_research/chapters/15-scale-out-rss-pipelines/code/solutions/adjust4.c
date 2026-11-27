/* SPDX-License-Identifier: BSD-3-Clause
 *
 * Exercise 2 solution: with rte_thash_adjust_tuple(), find 4 source ports
 * for connections 10.15.2.1:* -> 203.0.113.9:80 that land on 4 different
 * queues of a 4-queue port with a 128-entry RETA filled i % 4, and refuse
 * ports already in use through the check callback.
 *
 *   ./adjust4 -l 0 --no-pci --no-huge -m 64 --file-prefix=ch15-ex2
 */
#include <stdio.h>
#include <string.h>
#include <arpa/inet.h>
#include <rte_eal.h>
#include <rte_thash.h>
#include <rte_ip.h>

struct used { uint16_t port[8]; int n; };

/* rte_thash_check_tuple_t: return 1 if the tuple may be used */
static int
port_free(void *userdata, uint8_t *tuple)
{
	struct used *u = userdata;
	uint16_t p;
	int i;

	memcpy(&p, tuple + 8, 2);
	for (i = 0; i < u->n; i++)
		if (u->port[i] == p)
			return 0;
	return 1;
}

int
main(int argc, char **argv)
{
	struct rte_thash_ctx *ctx;
	struct rte_thash_subtuple_helper *h;
	struct used u = { .n = 0 };
	const uint8_t *key;
	unsigned int q;

	if (rte_eal_init(argc, argv) < 0)
		return 1;
	/* Start from the Microsoft key (pass NULL for a random one, which
	 * makes the output differ per run); 7 = log2(128 RETA entries). */
	static uint8_t k[40] = {
		0x6d, 0x5a, 0x56, 0xda, 0x25, 0x5b, 0x0e, 0xc2, 0x41, 0x67,
		0x25, 0x3d, 0x43, 0xa3, 0x8f, 0xb0, 0xd0, 0xca, 0x2b, 0xcb,
		0xae, 0x7b, 0x30, 0xb4, 0x77, 0xcb, 0x2d, 0xa3, 0x80, 0x30,
		0xf2, 0x0c, 0x6a, 0x42, 0xb7, 0x3b, 0xbe, 0xac, 0x01, 0xfa,
	};
	ctx = rte_thash_init_ctx("ex2", 40, 7, k, 0);
	if (ctx == NULL || rte_thash_add_helper(ctx, "sport", 16, 64) != 0)
		return 1;
	h = rte_thash_get_helper(ctx, "sport");
	key = rte_thash_get_key(ctx);

	for (q = 0; q < 4; q++) {
		uint8_t t[12];
		uint32_t a = htonl(RTE_IPV4(10, 15, 2, 1)), b = htonl(RTE_IPV4(203, 0, 113, 9));
		uint16_t sp = htons(40000), dp = htons(80);
		uint32_t w[3], hash;
		int i, ret;

		memcpy(t, &a, 4); memcpy(t + 4, &b, 4);
		memcpy(t + 8, &sp, 2); memcpy(t + 10, &dp, 2);
		ret = rte_thash_adjust_tuple(ctx, h, t, sizeof(t), q, 8, port_free, &u);
		if (ret != 0) {
			printf("queue %u: no port found (%d)\n", q, ret);
			continue;
		}
		memcpy(&u.port[u.n++], t + 8, 2);
		for (i = 0; i < 3; i++) {
			uint32_t be;
			memcpy(&be, t + 4 * i, 4);
			w[i] = ntohl(be);
		}
		hash = rte_softrss(w, 3, key);
		memcpy(&sp, t + 8, 2);
		printf("queue %u: source port %5u  hash 0x%08x  -> RETA[%3u] = queue %u\n",
		       q, ntohs(sp), hash, hash & 127, (hash & 127) % 4);
	}
	printf("program this key into the NIC (rte_eth_dev_rss_hash_update), first bytes: "
	       "%02x %02x %02x %02x\n", key[0], key[1], key[2], key[3]);
	rte_thash_free_ctx(ctx);
	rte_eal_cleanup();
	return 0;
}
