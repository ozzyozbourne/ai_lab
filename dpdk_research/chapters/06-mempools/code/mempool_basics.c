/* SPDX-License-Identifier: BSD-3-Clause
 *
 * Chapter 6, example 1: mempool_basics.c
 *
 * What it shows
 *   1. rte_mempool_create() of 1023 x 64-byte objects. An obj_init callback
 *      writes a sequence number into every object at creation time.
 *   2. The object layout: header | element | trailer, and how
 *      rte_mempool_from_obj() finds the pool from an object pointer.
 *   3. get/put of a single object and of a bulk, the counters
 *      rte_mempool_avail_count() / rte_mempool_in_use_count(), and the
 *      all-or-nothing rule of a bulk get (-ENOENT, nothing taken).
 *   4. rte_mempool_mem_iter(): how many memory chunks back the pool, and a
 *      second, mbuf-sized (2304-byte) pool that shows how the page size (4 KB with
 *      --no-huge, 2 MB with hugepages) changes the bytes used per object.
 *   5. rte_mempool_lookup() and rte_mempool_dump().
 *
 * Run:  ./mempool_basics -l 0 --no-pci --no-huge -m 64 --file-prefix=ch06-basic
 *       ./mempool_basics -l 0 --no-pci -m 64 --file-prefix=ch06-basic-huge
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

#include <rte_eal.h>
#include <rte_errno.h>
#include <rte_lcore.h>
#include <rte_memory.h>
#include <rte_mempool.h>
#include <rte_debug.h>

#define NB_OBJ   1023      /* 2^10 - 1: the ring backend holds n+1 rounded up to 2^q */
#define OBJ_SIZE 64
#define CACHE    32

/* Our object: 64 bytes, the first field is a sequence number. */
struct my_obj {
	uint32_t seq;          /* written once by obj_init */
	uint32_t uses;         /* incremented by the application */
	uint8_t  payload[OBJ_SIZE - 8];
};

/* obj_init: called once per object, by rte_mempool_create(), before the
 * pool is handed to us. obj_idx runs 0..n-1 in memory order. */
static void
number_obj(struct rte_mempool *mp, void *arg, void *obj, unsigned int obj_idx)
{
	struct my_obj *o = obj;
	(void)mp;
	(void)arg;
	o->seq = obj_idx;
	o->uses = 0;
}

/* mem_iter callback: one call per memory chunk (struct rte_mempool_memhdr). */
static void
count_chunk(struct rte_mempool *mp, void *arg, struct rte_mempool_memhdr *m,
	    unsigned int idx)
{
	size_t *total = arg;
	(void)mp;
	(void)idx;
	*total += m->len;
}

/* Report how much memory a pool really uses, per object. */
static void
report_footprint(struct rte_mempool *mp)
{
	size_t total = 0, pg = 0;
	uint32_t chunks = rte_mempool_mem_iter(mp, count_chunk, &total);

	rte_mempool_get_page_size(mp, &pg);
	printf("  pool %-8s elt=%u hdr=%u trailer=%u -> total_obj_size=%u\n",
	       mp->name, mp->elt_size, mp->header_size, mp->trailer_size,
	       mp->header_size + mp->elt_size + mp->trailer_size);
	printf("           page size used for layout: %zu bytes; %u chunk(s), %zu bytes\n",
	       pg, chunks, total);
	printf("           => %.0f bytes of memory per object (%u objects)\n",
	       (double)total / mp->populated_size, mp->populated_size);
}

int
main(int argc, char **argv)
{
	struct rte_mempool *mp, *big;
	struct my_obj *one;
	void *objs[8];
	int ret, i;

	ret = rte_eal_init(argc, argv);
	if (ret < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");

	/* ---- 1. create ---------------------------------------------------- */
	mp = rte_mempool_create("ch06_basic",   /* name, also used for lookup  */
				NB_OBJ,        /* number of objects            */
				sizeof(struct my_obj), /* element size         */
				CACHE,         /* per-lcore cache size          */
				0,             /* private data after the header */
				NULL, NULL,    /* mp_init + arg (none)          */
				number_obj, NULL, /* obj_init + arg            */
				rte_socket_id(),
				0);            /* flags: MP/MC ring by default  */
	if (mp == NULL)
		rte_exit(EXIT_FAILURE, "mempool create: %s\n", rte_strerror(rte_errno));

	printf("[1] created '%s': size=%u cache_size=%u ops=%s\n", mp->name,
	       mp->size, mp->cache_size, rte_mempool_get_ops(mp->ops_index)->name);
	printf("    avail=%u in_use=%u full=%d empty=%d\n",
	       rte_mempool_avail_count(mp), rte_mempool_in_use_count(mp),
	       rte_mempool_full(mp), rte_mempool_empty(mp));

	/* ---- 2. one object, and its layout ---------------------------------- */
	if (rte_mempool_get(mp, (void **)&one) < 0)
		rte_exit(EXIT_FAILURE, "get failed\n");
	one->uses++;
	{
		struct rte_mempool_objhdr *hdr = (struct rte_mempool_objhdr *)
			RTE_PTR_SUB(one, sizeof(*hdr));
		printf("[2] got obj %p seq=%u; header at %p (obj - %zu), hdr->mp=%s\n",
		       (void *)one, one->seq, (void *)hdr, sizeof(*hdr),
		       hdr->mp == mp ? "this pool" : "?");
		printf("    rte_mempool_from_obj(obj) == mp: %s; iova=0x%" PRIx64 "\n",
		       rte_mempool_from_obj(one) == mp ? "yes" : "no",
		       (uint64_t)rte_mempool_virt2iova(one));
	}
	printf("    avail=%u in_use=%u  (1 handed out, %u sit in this lcore's cache)\n",
	       rte_mempool_avail_count(mp), rte_mempool_in_use_count(mp),
	       rte_mempool_default_cache(mp, rte_lcore_id())->len);
	rte_mempool_put(mp, one);

	/* ---- 3. bulk get/put ---------------------------------------------- */
	ret = rte_mempool_get_bulk(mp, objs, 8);
	printf("[3] get_bulk(8) = %d, seq numbers:", ret);
	for (i = 0; i < 8; i++)
		printf(" %u", ((struct my_obj *)objs[i])->seq);
	printf("\n    distance between consecutive objects in memory: %ld bytes\n",
	       (long)((char *)objs[0] - (char *)objs[1]));
	rte_mempool_put_bulk(mp, objs, 8);

	/* All-or-nothing: take everything, then ask for one more bulk. */
	{
		void **all = malloc(sizeof(void *) * NB_OBJ);
		if (all == NULL)
			rte_exit(EXIT_FAILURE, "malloc\n");
		ret = rte_mempool_get_bulk(mp, all, NB_OBJ - 4);
		printf("    get_bulk(%d) = %d; avail now %u\n", NB_OBJ - 4, ret,
		       rte_mempool_avail_count(mp));
		ret = rte_mempool_get_bulk(mp, objs, 8);
		printf("    get_bulk(8) with only %u left = %d (%s); avail still %u\n",
		       rte_mempool_avail_count(mp), ret, strerror(-ret),
		       rte_mempool_avail_count(mp));
		rte_mempool_put_bulk(mp, all, NB_OBJ - 4);
		free(all);
	}
	printf("    after returning everything: avail=%u in_use=%u full=%d\n",
	       rte_mempool_avail_count(mp), rte_mempool_in_use_count(mp),
	       rte_mempool_full(mp));

	/* ---- 4. memory footprint ------------------------------------------ */
	printf("[4] memory footprint\n");
	report_footprint(mp);
	/* 2304 bytes = one default packet buffer: struct rte_mbuf (128) +
	 * RTE_MBUF_DEFAULT_BUF_SIZE (2048 data + 128 headroom). See ch7. */
	big = rte_mempool_create("ch06_big", 511, 2304, 0, 0, NULL, NULL,
				 NULL, NULL, rte_socket_id(), 0);
	if (big == NULL)
		rte_exit(EXIT_FAILURE, "big create: %s\n", rte_strerror(rte_errno));
	report_footprint(big);

	/* ---- 5. lookup and dump ------------------------------------------- */
	printf("[5] rte_mempool_lookup(\"ch06_basic\") %s\n",
	       rte_mempool_lookup("ch06_basic") == mp ? "found it" : "failed");
	rte_mempool_dump(stdout, mp);

	rte_mempool_free(big);
	rte_mempool_free(mp);
	rte_eal_cleanup();
	return 0;
}
