/* hash_fill.c - fill an rte_hash with random 16B keys until insertion fails;
 * report achieved load factor, and lookup cost single vs bulk.
 * run: ./hash_fill --no-huge -m 128 --no-pci --file-prefix=ch07h */
#include <stdio.h>
#include <stdlib.h>
#include <rte_eal.h>
#include <rte_hash.h>
#include <rte_hash_crc.h>
#include <rte_jhash.h>
#include <rte_cycles.h>
#include <rte_random.h>

#define N (1 << 16)
struct key { uint64_t a, b; };
static struct key keys[N * 2];

static void run(const char *name, uint8_t flags, rte_hash_function fn)
{
	struct rte_hash_parameters p = {
		.name = name, .entries = N, .key_len = sizeof(struct key),
		.hash_func = fn, .socket_id = SOCKET_ID_ANY, .extra_flag = flags,
	};
	struct rte_hash *h = rte_hash_create(&p);
	if (!h) { printf("create failed\n"); return; }
	int i;
	for (i = 0; i < N * 2; i++)
		if (rte_hash_add_key(h, &keys[i]) < 0)
			break;
	printf("%-10s first failure after %6d keys -> load %.1f%% (capacity %u)\n",
	       name, i, 100.0 * i / N, N);
	int ins = i;
	uint64_t t0 = rte_rdtsc();
	for (int j = 0; j < ins; j++)
		rte_hash_lookup(h, &keys[j]);
	uint64_t t1 = rte_rdtsc();
	const void *kp[64]; int32_t pos[64];
	for (int j = 0; j + 64 <= ins; j += 64) {
		for (int k = 0; k < 64; k++) kp[k] = &keys[j + k];
		rte_hash_lookup_bulk(h, kp, 64, pos);
	}
	uint64_t t2 = rte_rdtsc();
	printf("           lookup: single %.1f cycles/key, bulk(64) %.1f cycles/key\n",
	       (double)(t1 - t0) / ins, (double)(t2 - t1) / (ins & ~63));
	rte_hash_free(h);
}

int main(int argc, char **argv)
{
	if (rte_eal_init(argc, argv) < 0) return 1;
	for (int i = 0; i < N * 2; i++) { keys[i].a = rte_rand(); keys[i].b = rte_rand(); }
	run("crc", 0, rte_hash_crc);
	run("jhash", 0, rte_jhash);
	run("crc+ext", RTE_HASH_EXTRA_FLAGS_EXT_TABLE, rte_hash_crc);
	run("crc+lf", RTE_HASH_EXTRA_FLAGS_RW_CONCURRENCY_LF, rte_hash_crc);
	rte_eal_cleanup();
	return 0;
}
