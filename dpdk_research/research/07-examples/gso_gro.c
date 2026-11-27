/* gso_gro.c - software TSO (GSO) splits one big TCP/IPv4 packet into MSS-sized
 * segments; GRO merges them back. run: ./gso_gro --no-huge -m 128 --no-pci --file-prefix=ch07g */
#include <stdio.h>
#include <string.h>
#include <rte_eal.h>
#include <rte_mbuf.h>
#include <rte_ether.h>
#include <rte_ip.h>
#include <rte_tcp.h>
#include <rte_ethdev.h>
#include <rte_gso.h>
#include <rte_gro.h>

int main(int argc, char **argv)
{
	if (rte_eal_init(argc, argv) < 0) return 1;
	struct rte_mempool *mp = rte_pktmbuf_pool_create("mp", 1024, 32, 0, 10240 + 128, SOCKET_ID_ANY);
	struct rte_mempool *ind = rte_pktmbuf_pool_create("ind", 1024, 32, 0, 0, SOCKET_ID_ANY);
	struct rte_mbuf *m = rte_pktmbuf_alloc(mp);
	uint16_t payload = 8000, hl = sizeof(struct rte_ether_hdr) + 20 + 20;
	char *p = rte_pktmbuf_append(m, hl + payload);
	if (p == NULL) return 1;
	memset(p, 0, hl);
	struct rte_ether_hdr *eh = (void *)p; eh->ether_type = rte_cpu_to_be_16(RTE_ETHER_TYPE_IPV4);
	struct rte_ipv4_hdr *ip = (void *)(eh + 1);
	ip->version_ihl = RTE_IPV4_VHL_DEF; ip->time_to_live = 64; ip->next_proto_id = IPPROTO_TCP;
	ip->total_length = rte_cpu_to_be_16(40 + payload); ip->packet_id = rte_cpu_to_be_16(100);
	ip->src_addr = rte_cpu_to_be_32(RTE_IPV4(10, 0, 0, 1)); ip->dst_addr = rte_cpu_to_be_32(RTE_IPV4(10, 0, 0, 2));
	struct rte_tcp_hdr *tcp = (void *)(ip + 1);
	tcp->src_port = rte_cpu_to_be_16(5555); tcp->dst_port = rte_cpu_to_be_16(80);
	tcp->sent_seq = rte_cpu_to_be_32(1000); tcp->data_off = 5 << 4; tcp->tcp_flags = RTE_TCP_ACK_FLAG;
	memset(p + hl, 'x', payload);
	m->l2_len = 14; m->l3_len = 20; m->l4_len = 20;
	m->packet_type = RTE_PTYPE_L2_ETHER | RTE_PTYPE_L3_IPV4 | RTE_PTYPE_L4_TCP;
	m->ol_flags = RTE_MBUF_F_TX_TCP_SEG | RTE_MBUF_F_TX_IPV4;

	struct rte_gso_ctx ctx = { .direct_pool = mp, .indirect_pool = ind,
		.gso_types = RTE_ETH_TX_OFFLOAD_TCP_TSO, .gso_size = 1514, .flag = 0 };
	struct rte_mbuf *segs[16];
	int n = rte_gso_segment(m, &ctx, segs, 16);
	printf("GSO: 1 packet of %u bytes -> %d segments\n", m->pkt_len, n);
	for (int i = 0; i < n; i++) {
		struct rte_ipv4_hdr *h = rte_pktmbuf_mtod_offset(segs[i], struct rte_ipv4_hdr *, 14);
		struct rte_tcp_hdr *t = (void *)(h + 1);
		printf("  seg %d len=%4u nb_segs=%u ip_id=%u seq=%u\n", i, segs[i]->pkt_len, segs[i]->nb_segs,
		       rte_be_to_cpu_16(h->packet_id), rte_be_to_cpu_32(t->sent_seq));
		segs[i]->packet_type = m->packet_type;   /* GRO dispatches on packet_type */
		segs[i]->l2_len = 14; segs[i]->l3_len = 20; segs[i]->l4_len = 20;
	}
	rte_pktmbuf_free(m);   /* GSO never frees the input; segments hold references */
	struct rte_gro_param gp = { .gro_types = RTE_GRO_TCP_IPV4, .max_flow_num = 4, .max_item_per_flow = 32 };
	uint16_t out = rte_gro_reassemble_burst(segs, n, &gp);
	printf("GRO: %d segments -> %u packet(s); first len=%u nb_segs=%u\n", n, out, segs[0]->pkt_len, segs[0]->nb_segs);
	for (int i = 0; i < out; i++) rte_pktmbuf_free(segs[i]);
	rte_eal_cleanup();
	return 0;
}
