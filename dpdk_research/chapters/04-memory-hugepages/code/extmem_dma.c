/* SPDX-License-Identifier: BSD-3-Clause
 *
 * extmem_dma.c - Chapter 4, example 6 (deep dive).
 *
 * External memory is memory that DPDK did not allocate: a buffer from your
 * own allocator, a GPU, a file. Making a device able to DMA into it takes
 * TWO steps, and this program shows each one and what fails without it:
 *
 *   1. rte_extmem_register(va, len, iovas, n, page_sz)
 *        tells EAL "these pages exist" (creates an external memseg list),
 *        so rte_mem_virt2memseg() and friends know the address.
 *   2. rte_dev_dma_map(dev, va, iova, len)
 *        asks the device's BUS to program its IOMMU / DMA tables for
 *        that range. On PCI + VFIO this creates an IOMMU mapping. On the
 *        vdev bus it is forwarded to the driver's dma_map hook, if any.
 *
 * rte_vfio_* is internal in 26.11, so rte_dev_dma_map is the public path.
 *
 * It runs on three ports here: net_virtio_user0 talking vhost-user to
 * net_vhost0 (both in this process) and net_null0. Real VFIO mappings need a
 * PCI NIC bound to vfio-pci, which this VM does not have (see ch23).
 *
 *   ./extmem_dma -l 0 --no-pci --no-huge -m 128 --file-prefix=ch04-xdma \
 *       --vdev=net_vhost0,iface=$PWD/x.sock --vdev=net_null0 \
 *       -- net_virtio_user0,path=$PWD/x.sock
 *
 * net_vhost only creates its socket (x.sock) when its port is configured,
 * so virtio_user cannot be a plain --vdev (its probe would fail with
 * "connect error"). The program configures the vhost port first and then
 * hot-plugs virtio_user with rte_dev_probe(<devargs after -->).
 */
#include <stdio.h>
#include <string.h>
#include <inttypes.h>
#include <sys/mman.h>
#include <signal.h>

#include <rte_eal.h>
#include <rte_errno.h>
#include <rte_bus.h>
#include <rte_dev.h>
#include <rte_memory.h>
#include <rte_ethdev.h>

#define REGION (2u << 20)        /* 2 MB */
#define PAGE   4096u

static void try_map(const char *step, struct rte_device *dev, void *va, uint64_t iova, size_t len)
{
	rte_errno = 0;
	int r = rte_dev_dma_map(dev, va, iova, len);
	printf("    %-30s rte_dev_dma_map = %2d  rte_errno=%-2d %s\n", step, r,
	       r ? rte_errno : 0, r ? rte_strerror(rte_errno) : "(success)");
}

int main(int argc, char **argv)
{
	/* vhost-user writes to a socket the peer may already have closed
	 * during shutdown; ignore SIGPIPE so that is an error, not a kill. */
	signal(SIGPIPE, SIG_IGN);

	int nargs = rte_eal_init(argc, argv);
	if (nargs < 0) {
		fprintf(stderr, "rte_eal_init failed: %s\n", rte_strerror(rte_errno));
		return 1;
	}
	argc -= nargs;
	argv += nargs;

	/* Configure port 0 (net_vhost0) so it creates its vhost-user socket,
	 * then hot-plug the virtio_user port that connects to it. */
	if (argc > 1) {
		struct rte_eth_conf conf;
		memset(&conf, 0, sizeof(conf));
		int r = rte_eth_dev_configure(0, 1, 1, &conf);
		printf("configure port 0 (creates the socket) = %d\n", r);
		r = rte_dev_probe(argv[1]);
		printf("rte_dev_probe(\"%.16s...\") = %d\n", argv[1], r);
	}
	printf("IOVA mode %s, %u ports\n", rte_eal_iova_mode() == RTE_IOVA_VA ? "VA" : "PA",
	       rte_eth_dev_count_avail());

	/* Our "external" buffer: plain anonymous memory, 4 KB pages. */
	void *va = mmap(NULL, REGION, PROT_READ | PROT_WRITE,
			MAP_PRIVATE | MAP_ANONYMOUS | MAP_POPULATE, -1, 0);
	if (va == MAP_FAILED) {
		perror("mmap");
		return 1;
	}
	/* In VA mode the device address IS the virtual address. In PA mode we
	 * would have to fill an IOVA table from /proc/self/pagemap. */
	uint64_t iova = (uint64_t)(uintptr_t)va;
	printf("external region va=%p len=%u KB, iova used=0x%" PRIx64 "\n\n", va, REGION >> 10, iova);

	uint16_t port;
	struct rte_device *devs[RTE_MAX_ETHPORTS];

	printf("step 0: rte_dev_dma_map BEFORE registering the memory\n");
	RTE_ETH_FOREACH_DEV(port) {
		struct rte_eth_dev_info info;
		char name[RTE_ETH_NAME_MAX_LEN];

		rte_eth_dev_get_name_by_port(port, name, sizeof(name));  /* 26.11: takes a size */
		if (rte_eth_dev_info_get(port, &info) != 0)
			continue;
		devs[port] = info.device;              /* the generic rte_device behind the port */
		printf("  port %u %-17s driver=%-16s bus=%s\n", port, name, info.driver_name,
		       rte_bus_name(rte_dev_bus(devs[port])));
		try_map("not registered:", devs[port], va, iova, REGION);
	}

	/* Step 1: register once per process (EEXIST if done already). */
	int r = rte_extmem_register(va, REGION, NULL, 0, PAGE);
	printf("\nstep 1: rte_extmem_register = %d%s%s, rte_mem_virt2memseg_list(va) = %s\n", r,
	       r ? ", " : "", r ? rte_strerror(rte_errno) : "",
	       rte_mem_virt2memseg_list(va) ? "found (external list)" : "NULL");

	/* Step 2: the mapping itself, plus a bad length. */
	printf("\nstep 2: rte_dev_dma_map AFTER registering\n");
	RTE_ETH_FOREACH_DEV(port) {
		printf("  port %u\n", port);
		try_map("registered:", devs[port], va, iova, REGION);
		try_map("len = 0:", devs[port], va, iova, 0);
		r = rte_dev_dma_unmap(devs[port], va, iova, REGION);
		printf("    %-30s rte_dev_dma_unmap = %d\n", "undo:", r);
	}

	r = rte_extmem_unregister(va, REGION);
	printf("\nstep 3: rte_extmem_unregister = %d\n", r);
	RTE_ETH_FOREACH_DEV(port) {
		try_map("after unregister:", devs[port], va, iova, REGION);
		break;
	}
	munmap(va, REGION);

	/* close virtio_user (the vhost-user client) before the vhost server */
	for (int p = RTE_MAX_ETHPORTS - 1; p >= 0; p--)
		if (rte_eth_dev_is_valid_port(p))
			rte_eth_dev_close(p);
	rte_eal_cleanup();
	return 0;
}
