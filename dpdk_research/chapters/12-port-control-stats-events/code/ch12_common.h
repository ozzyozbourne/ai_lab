/* SPDX-License-Identifier: BSD-3-Clause
 * Chapter 12 shared helpers.
 *
 *  - rcname():        turn an ethdev return code into "OK", "-ENOTSUP", ...
 *  - ch12_port_init(): configure + queue setup + start (chapter 8 lifecycle)
 *  - kernel side of a net_tap port: disable IPv6 (no kernel chatter),
 *    inject raw Ethernet frames with an AF_PACKET socket
 *  - tel_query():     ask this process's own telemetry socket a question
 *                     (used to read rxq_state, which no public C API returns
 *                     on PMDs without rxq_info_get)
 * Everything here is plain C + public DPDK API.
 */
#ifndef CH12_COMMON_H
#define CH12_COMMON_H

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <net/if.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <linux/if_packet.h>
#include <linux/if_ether.h>

#include <rte_eal.h>
#include <rte_ethdev.h>
#include <rte_mbuf.h>
#include <rte_ether.h>
#include <rte_ip.h>
#include <rte_udp.h>
#include <rte_byteorder.h>

/* Map the errno values ethdev returns to their names. */
static inline const char *
rcname(int rc)
{
	static __thread char buf[32];

	switch (rc) {
	case 0: return "OK";
	case -ENOTSUP: return "-ENOTSUP";
	case -EBUSY: return "-EBUSY";
	case -EINVAL: return "-EINVAL";
	case -ENOSYS: return "-ENOSYS";
	case -ENODEV: return "-ENODEV";
	case -EIO: return "-EIO";
	case -EPERM: return "-EPERM";
	case -ENOMEM: return "-ENOMEM";
	case -EAGAIN: return "-EAGAIN";
	case -ENOSPC: return "-ENOSPC";
	case -EEXIST: return "-EEXIST";
	default:
		snprintf(buf, sizeof(buf), "%d", rc);
		return buf;
	}
}

/* configure(nrxq, ntxq) + every queue + start. rxc may be NULL. */
static inline int
ch12_port_init(uint16_t port, uint16_t nrxq, uint16_t ntxq,
	       struct rte_mempool *mp, const struct rte_eth_conf *conf,
	       const struct rte_eth_rxconf *rxc, int start)
{
	struct rte_eth_conf zero = {0};
	int rc;
	uint16_t q;

	rc = rte_eth_dev_configure(port, nrxq, ntxq, conf ? conf : &zero);
	if (rc < 0)
		return rc;
	for (q = 0; q < nrxq; q++) {
		rc = rte_eth_rx_queue_setup(port, q, 256,
				rte_eth_dev_socket_id(port), rxc, mp);
		if (rc < 0)
			return rc;
	}
	for (q = 0; q < ntxq; q++) {
		rc = rte_eth_tx_queue_setup(port, q, 256,
				rte_eth_dev_socket_id(port), NULL);
		if (rc < 0)
			return rc;
	}
	return start ? rte_eth_dev_start(port) : 0;
}

/* Turn off IPv6 on the kernel side of a tap so the kernel does not send
 * router solicitations / MLD reports that would pollute our counters. */
static inline void
if_quiet(const char *ifname)
{
	char path[128];
	FILE *f;

	snprintf(path, sizeof(path), "/proc/sys/net/ipv6/conf/%s/disable_ipv6",
		 ifname);
	f = fopen(path, "w");
	if (f) {
		fputs("1\n", f);
		fclose(f);
	}
}

/* Read a sysfs attribute of a kernel interface (mtu, operstate, address). */
static inline const char *
if_sysfs(const char *ifname, const char *attr)
{
	static __thread char buf[64];
	char path[128];
	FILE *f;

	snprintf(path, sizeof(path), "/sys/class/net/%s/%s", ifname, attr);
	buf[0] = 0;
	f = fopen(path, "r");
	if (f) {
		if (fgets(buf, sizeof(buf), f) == NULL)
			buf[0] = 0;
		fclose(f);
	}
	buf[strcspn(buf, "\n")] = 0;
	return buf;
}

/* Send n UDP frames to dst from the KERNEL side of interface ifname.
 * For a net_tap port this means "the wire": the frames arrive at the DPDK
 * RX queue. Source UDP port varies by i % flows so the kernel spreads
 * them across tap queues. Returns frames sent or -1. */
static inline int
kernel_inject(const char *ifname, const struct rte_ether_addr *dst,
	      int n, int flows)
{
	struct sockaddr_ll sll = {0};
	unsigned char fr[60];
	int s, i, sent = 0;

	s = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ALL));
	if (s < 0)
		return -1;
	sll.sll_family = AF_PACKET;
	sll.sll_ifindex = if_nametoindex(ifname);
	sll.sll_halen = 6;
	memcpy(sll.sll_addr, dst->addr_bytes, 6);
	for (i = 0; i < n; i++) {
		struct rte_ether_hdr *eh = (void *)fr;
		struct rte_ipv4_hdr *ip = (void *)(eh + 1);
		struct rte_udp_hdr *udp = (void *)(ip + 1);

		memset(fr, 0, sizeof(fr));
		eh->dst_addr = *dst;
		memcpy(eh->src_addr.addr_bytes, "\x02\x12\xee\x00\x00\x01", 6);
		eh->ether_type = rte_cpu_to_be_16(RTE_ETHER_TYPE_IPV4);
		ip->version_ihl = RTE_IPV4_VHL_DEF;
		ip->total_length = rte_cpu_to_be_16(46);
		ip->time_to_live = 64;
		ip->next_proto_id = IPPROTO_UDP;
		ip->src_addr = rte_cpu_to_be_32(RTE_IPV4(10, 12, 0, 1));
		ip->dst_addr = rte_cpu_to_be_32(RTE_IPV4(10, 12, 0, 2));
		ip->hdr_checksum = rte_ipv4_cksum(ip);
		udp->src_port = rte_cpu_to_be_16(1000 + i % (flows ? flows : 1));
		udp->dst_port = rte_cpu_to_be_16(9);
		udp->dgram_len = rte_cpu_to_be_16(26);
		if (sendto(s, fr, sizeof(fr), 0, (void *)&sll, sizeof(sll)) ==
		    (ssize_t)sizeof(fr))
			sent++;
	}
	close(s);
	return sent;
}

/* Query this process's own telemetry socket, e.g. "/ethdev/info,0".
 * The server lives in a DPDK control thread; we are just a client.
 * Returns bytes of JSON in out, or -1. */
static inline int
tel_query(const char *cmd, char *out, size_t len)
{
	struct sockaddr_un sun = { .sun_family = AF_UNIX };
	int s, n;

	snprintf(sun.sun_path, sizeof(sun.sun_path), "%s/dpdk_telemetry.v2",
		 rte_eal_get_runtime_dir());
	s = socket(AF_UNIX, SOCK_SEQPACKET, 0);
	if (s < 0)
		return -1;
	if (connect(s, (void *)&sun, sizeof(sun)) < 0) {
		close(s);
		return -1;
	}
	n = read(s, out, len - 1);	/* welcome message, ignored */
	if (n < 0 || write(s, cmd, strlen(cmd)) < 0) {
		close(s);
		return -1;
	}
	n = read(s, out, len - 1);
	close(s);
	if (n < 0)
		return -1;
	out[n] = 0;
	return n;
}

/* Extract a JSON array like "rxq_state":[1,0] from a telemetry reply. */
static inline const char *
tel_field(const char *json, const char *key)
{
	static __thread char buf[128];
	char pat[64];
	const char *p, *e;

	snprintf(pat, sizeof(pat), "\"%s\":", key);
	p = strstr(json, pat);
	if (!p)
		return "?";
	p += strlen(pat);
	e = p;
	if (*e == '[')
		e = strchr(e, ']') + 1;
	else
		while (*e && *e != ',' && *e != '}')
			e++;
	snprintf(buf, sizeof(buf), "%.*s", (int)(e - p), p);
	return buf;
}

/* rxq_state of a port via telemetry: "[1,0]" means q0 started, q1 stopped. */
static inline const char *
rxq_states(uint16_t port)
{
	static __thread char json[8192];
	char cmd[32];

	snprintf(cmd, sizeof(cmd), "/ethdev/info,%u", port);
	if (tel_query(cmd, json, sizeof(json)) < 0)
		return "(telemetry unavailable)";
	return tel_field(json, "rxq_state");
}

/* Look up one xstat by name and read it (cheap enough for a slow path). */
static inline uint64_t
xstat(uint16_t port, const char *name)
{
	uint64_t id, val = 0;

	if (rte_eth_xstats_get_id_by_name(port, name, &id) != 0)
		return UINT64_MAX;
	if (rte_eth_xstats_get_by_id(port, &id, &val, 1) != 1)
		return UINT64_MAX;
	return val;
}

#endif /* CH12_COMMON_H */
