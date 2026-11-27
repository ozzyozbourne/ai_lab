/* eBPF RX filter: return 0 (drop) for IPv4/UDP dst port 2001, 1 (keep) otherwise.
 * Input arg: pointer to first-segment packet data (testpmd flag '-').
 * Self-contained (no libc headers) so it builds with plain clang -target bpf:
 *   clang -O2 -target bpf -c drop_dport2001.c -o drop_dport2001.o */
typedef unsigned char u8; typedef unsigned short u16; typedef unsigned long long u64;
#define bswap16(x) __builtin_bswap16(x)
u64 entry(void *pkt)
{
	u8 *p = pkt;
	if (*(u16 *)(p + 12) != bswap16(0x0800))   /* ethertype IPv4 */
		return 1;
	u8 *ip = p + 14;
	if (ip[9] != 17)                           /* protocol UDP */
		return 1;
	u8 *udp = ip + (ip[0] & 0xf) * 4;          /* skip IHL */
	return *(u16 *)(udp + 2) == bswap16(2001) ? 0 : 1;
}
