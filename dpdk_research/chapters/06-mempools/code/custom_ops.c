/* SPDX-License-Identifier: BSD-3-Clause
 *
 * Chapter 6, example 5a: custom_ops.c
 *
 * Write and register your own mempool handler ("ops"): a toy LIFO made of a
 * plain pointer array protected by a spinlock. It is the same idea as the
 * built-in "stack" handler, written out so you can see every callback a
 * handler must provide:
 *
 *   alloc     - create the private store, put it in mp->pool_data
 *   free      - destroy it
 *   enqueue   - accept n object pointers (called on put / cache flush)
 *   dequeue   - hand out n object pointers, all or nothing
 *   get_count - how many objects the store holds now
 *
 * RTE_MEMPOOL_REGISTER_OPS() adds it to rte_mempool_ops_table from a
 * constructor that runs before main(). The pool stores only an INDEX into
 * that table (mp->ops_index), so secondary processes can share the pool
 * if they register the same handlers in the same order.
 *
 * The program also counts handler calls with cache 0 and with cache 64 to
 * show how the per-lcore cache shields the handler.
 *
 * Run:  ./custom_ops -l 0 --no-pci --no-huge -m 64 --file-prefix=ch06-custom
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

#include <rte_eal.h>
#include <rte_errno.h>
#include <rte_lcore.h>
#include <rte_malloc.h>
#include <rte_spinlock.h>
#include <rte_mempool.h>
#include <rte_debug.h>

/* ---- the handler's private store --------------------------------------- */
struct array_store {
	rte_spinlock_t lock;
	unsigned int len;      /* objects currently stored  */
	unsigned int size;     /* capacity = mp->size        */
	uint64_t n_enq, n_deq; /* calls, for the demo        */
	void *objs[];          /* LIFO: objs[len-1] is the top */
};

static int
array_alloc(struct rte_mempool *mp)
{
	struct array_store *st;

	st = rte_zmalloc_socket("ch06_array_store",
				sizeof(*st) + sizeof(void *) * mp->size,
				RTE_CACHE_LINE_SIZE, mp->socket_id);
	if (st == NULL)
		return -ENOMEM;
	rte_spinlock_init(&st->lock);
	st->size = mp->size;
	mp->pool_data = st;     /* every other callback finds it here */
	return 0;
}

static void
array_free(struct rte_mempool *mp)
{
	rte_free(mp->pool_data);
}

static int
array_enqueue(struct rte_mempool *mp, void * const *obj_table, unsigned int n)
{
	struct array_store *st = mp->pool_data;
	int ret = 0;

	rte_spinlock_lock(&st->lock);
	st->n_enq++;
	if (st->len + n > st->size) {
		ret = -ENOBUFS;            /* cannot happen in a healthy pool */
	} else {
		memcpy(&st->objs[st->len], obj_table, sizeof(void *) * n);
		st->len += n;
	}
	rte_spinlock_unlock(&st->lock);
	return ret;
}

static int
array_dequeue(struct rte_mempool *mp, void **obj_table, unsigned int n)
{
	struct array_store *st = mp->pool_data;
	unsigned int i;

	rte_spinlock_lock(&st->lock);
	st->n_deq++;
	if (n > st->len) {                 /* all or nothing */
		rte_spinlock_unlock(&st->lock);
		return -ENOBUFS;
	}
	for (i = 0; i < n; i++)            /* pop from the top: LIFO */
		obj_table[i] = st->objs[--st->len];
	rte_spinlock_unlock(&st->lock);
	return 0;
}

static unsigned int
array_get_count(const struct rte_mempool *mp)
{
	const struct array_store *st = mp->pool_data;
	return st->len;
}

static struct rte_mempool_ops ops_ch06_array = {
	.name = "ch06_array",
	.alloc = array_alloc,
	.free = array_free,
	.enqueue = array_enqueue,
	.dequeue = array_dequeue,
	.get_count = array_get_count,
	/* calc_mem_size, populate, get_info: NULL -> library defaults */
};

RTE_MEMPOOL_REGISTER_OPS(ops_ch06_array);

/* ---- using it ------------------------------------------------------------ */
static struct rte_mempool *
make_pool(const char *name, unsigned int cache)
{
	struct rte_mempool *mp;
	int ret;

	mp = rte_mempool_create_empty(name, 1023, 64, cache, 0, rte_socket_id(), 0);
	if (mp == NULL)
		rte_exit(EXIT_FAILURE, "create_empty: %s\n", rte_strerror(rte_errno));
	ret = rte_mempool_set_ops_byname(mp, "ch06_array", NULL);
	if (ret != 0)
		rte_exit(EXIT_FAILURE, "set_ops_byname: %s\n", strerror(-ret));
	ret = rte_mempool_populate_default(mp);    /* calls alloc, then enqueue */
	if (ret < 0)
		rte_exit(EXIT_FAILURE, "populate: %s\n", strerror(-ret));
	return mp;
}

static void
workload(struct rte_mempool *mp)
{
	void *objs[32];
	int i;

	for (i = 0; i < 10000; i++) {
		rte_mempool_get_bulk(mp, objs, 32);
		rte_mempool_put_bulk(mp, objs, 32);
	}
}

int
main(int argc, char **argv)
{
	struct rte_mempool *mp;
	struct array_store *st;
	unsigned int i;
	void *a, *b, *big[1024];
	int ret;

	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");

	printf("[1] registered mempool handlers (rte_mempool_ops_table, %u entries):\n  ",
	       rte_mempool_ops_table.num_ops);
	for (i = 0; i < rte_mempool_ops_table.num_ops; i++)
		printf("%u:%s ", i, rte_mempool_ops_table.ops[i].name);
	printf("\n");

	mp = make_pool("ch06_custom", 0);
	st = mp->pool_data;
	printf("[2] pool '%s' ops_index=%d ops=%s; store holds %u, enqueue calls=%" PRIu64
	       " (populate)\n", mp->name, mp->ops_index,
	       rte_mempool_get_ops(mp->ops_index)->name, st->len, st->n_enq);

	/* LIFO check: free a then b; the next get returns b (the hottest). */
	rte_mempool_get(mp, &a);
	rte_mempool_get(mp, &b);
	rte_mempool_put(mp, a);
	rte_mempool_put(mp, b);
	{
		void *c;
		rte_mempool_get(mp, &c);
		printf("[3] put a=%p, put b=%p, get -> %p (%s)\n", a, b, c,
		       c == b ? "b: LIFO" : "a: FIFO");
		rte_mempool_put(mp, c);
	}

	/* Exhaustion: our dequeue returns -ENOBUFS, the API passes it through. */
	ret = rte_mempool_get_bulk(mp, big, 1023);
	printf("[4] get_bulk(1023)=%d, then get_bulk(1)=", ret);
	ret = rte_mempool_get_bulk(mp, &a, 1);
	printf("%d (%s)\n", ret, strerror(-ret));
	rte_mempool_put_bulk(mp, big, 1023);

	/* Handler calls with and without a cache. */
	st->n_enq = st->n_deq = 0;
	workload(mp);
	printf("[5] cache 0 : 10000 x (get 32 + put 32) -> handler dequeue=%" PRIu64
	       " enqueue=%" PRIu64 " calls\n", st->n_deq, st->n_enq);
	rte_mempool_free(mp);

	mp = make_pool("ch06_custom2", 64);
	st = mp->pool_data;
	st->n_enq = st->n_deq = 0;
	workload(mp);
	printf("    cache 64: 10000 x (get 32 + put 32) -> handler dequeue=%" PRIu64
	       " enqueue=%" PRIu64 " calls\n", st->n_deq, st->n_enq);
	rte_mempool_free(mp);

	rte_eal_cleanup();
	return 0;
}
