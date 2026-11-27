/* SPDX-License-Identifier: BSD-3-Clause
 *
 * Chapter 7, exercise 1 (easy) solution: vlan_prepend.c
 *
 * Insert an 802.1Q VLAN tag into an Ethernet frame IN PLACE, using the
 * mbuf headroom:
 *
 *   before:  | dst MAC 6 | src MAC 6 | type 2 | payload ...
 *   after :  | dst MAC 6 | src MAC 6 | 0x8100 | TCI 2 | type 2 | payload ...
 *
 * Steps: rte_pktmbuf_prepend(m, 4) moves the start 4 bytes earlier; the
 * 12 MAC bytes are moved to the new start; the 4 freed bytes right after
 * them receive TPID + TCI. Only 12 bytes are copied, never the payload.
 * The frame bytes are written by hand on purpose: lib/net (struct
 * rte_ether_hdr, rte_vlan_insert) is ch10, where you compare with this.
 *
 * Run: ./vlan_prepend -l 0 --no-pci --no-huge -m 64 --file-prefix=ch07-vlan
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include <rte_eal.h>
#include <rte_errno.h>
#include <rte_debug.h>
#include <rte_lcore.h>
#include <rte_hexdump.h>
#include <rte_byteorder.h>
#include <rte_mbuf.h>

/* Returns 0, or -1 if there is no headroom or the frame is too short. */
static int vlan_prepend(struct rte_mbuf *m, uint16_t vlan_id, uint8_t pcp)
{
	if (rte_pktmbuf_data_len(m) < 14)
		return -1;
	char *old = rte_pktmbuf_mtod(m, char *);
	char *new = rte_pktmbuf_prepend(m, 4);   /* NULL if headroom < 4 */
	if (new == NULL)
		return -1;
	memmove(new, old, 12);                   /* MACs go 4 bytes earlier */
	rte_be16_t tpid = rte_cpu_to_be_16(0x8100);
	rte_be16_t tci  = rte_cpu_to_be_16((uint16_t)(pcp << 13) | (vlan_id & 0x0fff));
	memcpy(new + 12, &tpid, 2);              /* the old type stays at +16 */
	memcpy(new + 14, &tci, 2);
	return 0;
}

int main(int argc, char **argv)
{
	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	struct rte_mempool *mp = rte_pktmbuf_pool_create("ch07_vlan", 63, 0, 0,
			RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
	if (mp == NULL)
		rte_exit(EXIT_FAILURE, "pool: %s\n", rte_strerror(rte_errno));

	static const uint8_t frame[] = {
		0x02, 0x00, 0x00, 0x00, 0x00, 0x02,   /* dst MAC */
		0x02, 0x00, 0x00, 0x00, 0x00, 0x01,   /* src MAC */
		0x08, 0x00,                           /* EtherType IPv4 */
		'p', 'a', 'y', 'l', 'o', 'a', 'd', '!'
	};
	struct rte_mbuf *m = rte_pktmbuf_alloc(mp);
	memcpy(rte_pktmbuf_append(m, sizeof(frame)), frame, sizeof(frame));
	printf("before: data_off=%u len=%u\n", m->data_off, m->data_len);
	rte_hexdump(stdout, "untagged", rte_pktmbuf_mtod(m, void *), m->data_len);

	if (vlan_prepend(m, 100, 3) != 0)
		rte_exit(EXIT_FAILURE, "vlan_prepend failed\n");
	printf("after : data_off=%u len=%u (VLAN 100, PCP 3 -> TCI 0x%04x)\n",
	       m->data_off, m->data_len, (3 << 13) | 100);
	rte_hexdump(stdout, "tagged", rte_pktmbuf_mtod(m, void *), m->data_len);

	/* With no headroom the function must refuse, not scribble */
	m->data_off = 2;
	printf("with headroom 2: vlan_prepend -> %d\n", vlan_prepend(m, 1, 0));

	rte_pktmbuf_free(m);
	rte_mempool_free(mp);
	rte_eal_cleanup();
	return 0;
}
