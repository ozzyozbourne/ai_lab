/* SPDX-License-Identifier: BSD-3-Clause
 *
 * Chapter 7, example 1: mbuf_anatomy.c
 *
 * Dissects struct rte_mbuf on this build:
 *   1. sizeof() and offsetof() of the important fields (two 64 B cache lines)
 *   2. where the private area, the buffer and the data start, as addresses
 *      relative to the mbuf itself
 *   3. append / prepend / adj / trim, printing data_off, data_len, headroom
 *      and tailroom after each step, plus an rte_pktmbuf_dump()
 *   4. what happens when a prepend does not fit in the headroom (NULL)
 *   5. ol_flags, packet_type and tx_offload: setting bits and naming them
 *
 * No ports, no protocol headers: just the buffer.
 *
 * Run: ./mbuf_anatomy -l 0 --no-pci --no-huge -m 64 --file-prefix=ch07-anat
 */
#include <stdio.h>
#include <stddef.h>
#include <string.h>
#include <stdlib.h>
#include <inttypes.h>

#include <rte_eal.h>
#include <rte_errno.h>
#include <rte_debug.h>
#include <rte_lcore.h>
#include <rte_mbuf.h>

#define NB_MBUF   511   /* 2^n - 1 is the most memory-efficient pool size */
#define PRIV_SIZE 16    /* per-mbuf app area; must be a multiple of RTE_MBUF_PRIV_ALIGN */

/* print one field: name, byte offset, size and which cache line it is in */
#define FIELD(f) printf("  %-14s off %3zu  size %2zu  cache line %zu\n", #f, \
	offsetof(struct rte_mbuf, f), sizeof(((struct rte_mbuf *)0)->f),   \
	offsetof(struct rte_mbuf, f) / RTE_CACHE_LINE_MIN_SIZE)

/* the four numbers that describe where the data is inside the buffer */
static void show(const char *what, const struct rte_mbuf *m)
{
	printf("%-28s data_off=%3u data_len=%3u pkt_len=%3u headroom=%3u tailroom=%4u\n",
	       what, m->data_off, rte_pktmbuf_data_len(m), rte_pktmbuf_pkt_len(m),
	       rte_pktmbuf_headroom(m), rte_pktmbuf_tailroom(m));
}

int main(int argc, char **argv)
{
	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");

	/* ---- 1. The struct itself --------------------------------------- */
	printf("== 1. struct rte_mbuf on this build ==\n");
	printf("sizeof(struct rte_mbuf) = %zu bytes (%zu cache lines of %d)\n",
	       sizeof(struct rte_mbuf),
	       sizeof(struct rte_mbuf) / RTE_CACHE_LINE_MIN_SIZE,
	       RTE_CACHE_LINE_MIN_SIZE);
	printf("RTE_IOVA_IN_MBUF=%d RTE_PKTMBUF_HEADROOM=%d RTE_MBUF_DEFAULT_BUF_SIZE=%d\n",
	       RTE_IOVA_IN_MBUF, RTE_PKTMBUF_HEADROOM, RTE_MBUF_DEFAULT_BUF_SIZE);
	FIELD(buf_addr);
	FIELD(buf_iova);
	FIELD(data_off);
	FIELD(refcnt);
	FIELD(nb_segs);
	FIELD(port);
	FIELD(ol_flags);
	FIELD(packet_type);
	FIELD(pkt_len);
	FIELD(data_len);
	FIELD(vlan_tci);
	FIELD(hash);
	FIELD(vlan_tci_outer);
	FIELD(buf_len);
	FIELD(pool);
	FIELD(next);
	FIELD(tx_offload);
	FIELD(shinfo);
	FIELD(priv_size);
	FIELD(timesync);
	FIELD(dynfield1);

	/* ---- 2. A pool and one fresh mbuf ------------------------------- */
	/* data_room_size includes the headroom: 2048 data + 128 headroom */
	struct rte_mempool *mp = rte_pktmbuf_pool_create("ch07_anat", NB_MBUF,
			32, PRIV_SIZE, RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
	if (mp == NULL)
		rte_exit(EXIT_FAILURE, "pool: %s\n", rte_strerror(rte_errno));

	printf("\n== 2. pool and a fresh mbuf ==\n");
	printf("pool elt_size=%u (= %zu mbuf + %u priv + %u data room)\n",
	       mp->elt_size, sizeof(struct rte_mbuf), rte_pktmbuf_priv_size(mp),
	       rte_pktmbuf_data_room_size(mp));

	struct rte_mbuf *m = rte_pktmbuf_alloc(mp);
	if (m == NULL)
		rte_exit(EXIT_FAILURE, "alloc failed\n");

	char *base = (char *)m;
	printf("m                 = %p  (+0)\n", (void *)m);
	printf("rte_mbuf_to_priv  = %p  (+%td)\n", rte_mbuf_to_priv(m),
	       (char *)rte_mbuf_to_priv(m) - base);
	printf("m->buf_addr       = %p  (+%td)\n", m->buf_addr,
	       (char *)m->buf_addr - base);
	printf("mtod(m)           = %p  (+%td)  buf_addr + data_off\n",
	       rte_pktmbuf_mtod(m, void *), rte_pktmbuf_mtod(m, char *) - base);
	printf("end of buffer     = %p  (+%td)  buf_addr + buf_len\n",
	       (char *)m->buf_addr + m->buf_len,
	       (char *)m->buf_addr + m->buf_len - base);
	printf("buf_len=%u refcnt=%u nb_segs=%u next=%p pool=%s\n",
	       m->buf_len, rte_mbuf_refcnt_read(m), m->nb_segs,
	       (void *)m->next, m->pool->name);

	/* ---- 3. Moving the data window ---------------------------------- */
	printf("\n== 3. append / prepend / adj / trim ==\n");
	show("fresh mbuf", m);

	/* append: grow at the tail. Returns a pointer to the NEW bytes. */
	char *tail = rte_pktmbuf_append(m, 100);
	memset(tail, 'P', 100);                 /* 100 bytes of "payload" */
	show("append(100)", m);

	/* prepend: grow at the front into the headroom. Returns the NEW start. */
	char *head = rte_pktmbuf_prepend(m, 14);
	memset(head, 'H', 14);                  /* 14 bytes of "header" */
	show("prepend(14)", m);

	/* adj: drop bytes from the front (strip a header). */
	rte_pktmbuf_adj(m, 14);
	show("adj(14)", m);

	/* trim: drop bytes from the tail (cut a trailer). Returns 0 or -1. */
	rte_pktmbuf_trim(m, 10);
	show("trim(10)", m);

	/* mtod_offset: a typed pointer N bytes into the data */
	printf("mtod_offset(m, char *, 89) -> '%c' (last byte)\n",
	       *rte_pktmbuf_mtod_offset(m, char *, 89));

	/* ---- 4. Overflows return NULL / -1 and change nothing ----------- */
	printf("\n== 4. overflow is refused, not clamped ==\n");
	char *p = rte_pktmbuf_prepend(m, 200);  /* headroom is only 128 */
	printf("prepend(200) -> %s\n", p ? "pointer" : "NULL");
	p = rte_pktmbuf_append(m, 3000);        /* tailroom is ~2000 */
	printf("append(3000) -> %s\n", p ? "pointer" : "NULL");
	printf("trim(500)    -> %d\n", rte_pktmbuf_trim(m, 500));
	show("after the failed calls", m);

	printf("\nrte_pktmbuf_dump(stdout, m, 32):\n");
	rte_pktmbuf_dump(stdout, m, 32);

	/* reset puts the mbuf back into the "fresh" state (data_off = 128) */
	rte_pktmbuf_reset(m);
	show("rte_pktmbuf_reset(m)", m);

	/* ---- 5. Naming flags and packet types --------------------------- */
	/* No parsing here (that is lib/net, ch10): we only set the bits a
	 * driver or an app would set, and let the library name them. */
	printf("\n== 5. ol_flags, packet_type and tx_offload ==\n");
	char names[256];
	uint64_t rx = RTE_MBUF_F_RX_RSS_HASH | RTE_MBUF_F_RX_IP_CKSUM_GOOD |
		      RTE_MBUF_F_RX_L4_CKSUM_GOOD;
	rte_get_rx_ol_flag_list(rx, names, sizeof(names));
	printf("RX ol_flags 0x%016" PRIx64 " = %s\n", rx, names);
	uint64_t tx = RTE_MBUF_F_TX_IPV4 | RTE_MBUF_F_TX_IP_CKSUM |
		      RTE_MBUF_F_TX_UDP_CKSUM;
	rte_get_tx_ol_flag_list(tx, names, sizeof(names));
	printf("TX ol_flags 0x%016" PRIx64 " = %s\n", tx, names);

	m->packet_type = RTE_PTYPE_L2_ETHER | RTE_PTYPE_L3_IPV4 | RTE_PTYPE_L4_UDP;
	rte_get_ptype_name(m->packet_type, names, sizeof(names));
	printf("packet_type 0x%08x = %s\n", m->packet_type, names);
	uint32_t vx = RTE_PTYPE_L2_ETHER | RTE_PTYPE_L3_IPV4 | RTE_PTYPE_L4_UDP |
		      RTE_PTYPE_TUNNEL_VXLAN | RTE_PTYPE_INNER_L2_ETHER |
		      RTE_PTYPE_INNER_L3_IPV4 | RTE_PTYPE_INNER_L4_TCP;
	rte_get_ptype_name(vx, names, sizeof(names));
	printf("packet_type 0x%08x = %s\n", vx, names);
	printf("  l3 nibble via mask: 0x%02x (RTE_PTYPE_L3_IPV4 = 0x%02x)\n",
	       vx & RTE_PTYPE_L3_MASK, RTE_PTYPE_L3_IPV4);

	/* tx_offload: six bitfields packed into one uint64_t */
	m->l2_len = 14;
	m->l3_len = 20;
	m->l4_len = 8;
	printf("l2_len=%u l3_len=%u l4_len=%u -> tx_offload=0x%016" PRIx64
	       " (l2 in bits 0-6, l3 in 7-15, l4 in 16-23)\n",
	       (unsigned)m->l2_len, (unsigned)m->l3_len, (unsigned)m->l4_len,
	       m->tx_offload);
	rte_pktmbuf_reset(m);   /* clears packet_type and tx_offload again */

	printf("\npool: avail=%u in_use=%u before free\n",
	       rte_mempool_avail_count(mp), rte_mempool_in_use_count(mp));
	rte_pktmbuf_free(m);    /* no pool argument: m->pool says where */
	printf("pool: avail=%u in_use=%u after free\n",
	       rte_mempool_avail_count(mp), rte_mempool_in_use_count(mp));

	rte_mempool_free(mp);
	rte_eal_cleanup();
	return 0;
}
