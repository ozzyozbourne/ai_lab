/* frag_reasm.c - zero-copy IPv4 fragmentation then out-of-order reassembly,
 * no ports needed. run: ./frag_reasm --no-huge -m 128 --no-pci --file-prefix=ch07fr */
#include <stdio.h>
#include <string.h>
#include <rte_eal.h>
#include <rte_mbuf.h>
#include <rte_ip.h>
#include <rte_udp.h>
#include <rte_ether.h>
#include <rte_cycles.h>
#include <rte_ip_frag.h>

int main(int argc, char **argv)
{
	if (rte_eal_init(argc, argv) < 0) return 1;
	struct rte_mempool *direct = rte_pktmbuf_pool_create("direct", 1024, 32, 0,
					RTE_MBUF_DEFAULT_BUF_SIZE + 4096, SOCKET_ID_ANY);
	struct rte_mempool *indirect = rte_pktmbuf_pool_create("indir", 1024, 32, 0, 0, SOCKET_ID_ANY);
	/* build one 4028-byte IPv4/UDP datagram (L2 stripped, as the API requires) */
	struct rte_mbuf *m = rte_pktmbuf_alloc(direct);
	uint16_t plen = 4000;
	struct rte_ipv4_hdr *ip = (void *)rte_pktmbuf_append(m, sizeof(*ip) + sizeof(struct rte_udp_hdr) + plen);
	memset(ip, 0, sizeof(*ip));
	ip->version_ihl = RTE_IPV4_VHL_DEF; ip->time_to_live = 64; ip->next_proto_id = IPPROTO_UDP;
	ip->total_length = rte_cpu_to_be_16(m->pkt_len); ip->packet_id = rte_cpu_to_be_16(42);
	ip->src_addr = rte_cpu_to_be_32(RTE_IPV4(10, 0, 0, 1)); ip->dst_addr = rte_cpu_to_be_32(RTE_IPV4(10, 0, 0, 2));
	struct rte_udp_hdr *udp = (void *)(ip + 1);
	udp->src_port = rte_cpu_to_be_16(1000); udp->dst_port = rte_cpu_to_be_16(2000);
	udp->dgram_len = rte_cpu_to_be_16(sizeof(*udp) + plen);
	memset(udp + 1, 0xab, plen);
	ip->hdr_checksum = rte_ipv4_cksum(ip);
	printf("original: pkt_len=%u segs=%u refcnt=%u\n", m->pkt_len, m->nb_segs, rte_mbuf_refcnt_read(m));

	struct rte_mbuf *frags[8];
	int n = rte_ipv4_fragment_packet(m, frags, 8, 1500, direct, indirect);
	printf("fragments: %d, original refcnt now %u (indirect mbufs point into it)\n", n, rte_mbuf_refcnt_read(m));
	for (int i = 0; i < n; i++) {
		struct rte_ipv4_hdr *h = rte_pktmbuf_mtod(frags[i], struct rte_ipv4_hdr *);
		uint16_t fo = rte_be_to_cpu_16(h->fragment_offset);
		printf("  frag %d: pkt_len=%4u segs=%u off=%4u MF=%d cksum=0x%04x\n", i, frags[i]->pkt_len,
		       frags[i]->nb_segs, (fo & RTE_IPV4_HDR_OFFSET_MASK) * 8, !!(fo & RTE_IPV4_HDR_MF_FLAG),
		       h->hdr_checksum);
	}
	rte_pktmbuf_free(m);  /* caller still owns the input packet */

	struct rte_ip_frag_tbl *tbl = rte_ip_frag_table_create(64, 4, 256, rte_get_tsc_hz(), SOCKET_ID_ANY);
	struct rte_ip_frag_death_row dr = { 0 };
	int order[] = { 2, 0, 1 };      /* deliver out of order */
	for (int k = 0; k < n; k++) {
		struct rte_mbuf *f = frags[order[k % 3] < n ? order[k % 3] : k];
		f->l2_len = 0; f->l3_len = sizeof(struct rte_ipv4_hdr);
		struct rte_mbuf *r = rte_ipv4_frag_reassemble_packet(tbl, &dr, f, rte_rdtsc(),
						rte_pktmbuf_mtod(f, struct rte_ipv4_hdr *));
		printf("  feed frag %d -> %s\n", order[k % 3], r ? "REASSEMBLED" : "pending");
		if (r) {
			printf("reassembled: pkt_len=%u nb_segs=%u (chained, not copied)\n", r->pkt_len, r->nb_segs);
			rte_pktmbuf_free(r);
		}
	}
	rte_ip_frag_free_death_row(&dr, 0);
	rte_ip_frag_table_destroy(tbl);
	rte_eal_cleanup();
	return 0;
}
