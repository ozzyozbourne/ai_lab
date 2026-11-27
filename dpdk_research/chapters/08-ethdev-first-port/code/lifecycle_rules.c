/* SPDX-License-Identifier: BSD-3-Clause
 *
 * lifecycle_rules.c - Chapter 8: call the lifecycle functions in the WRONG
 * order on purpose and print what ethdev answers. This is the rule table
 * behind the "port state machine" widget in the chapter.
 *
 * Application option (after "--"):
 *   --early-setup   also call rte_eth_rx_queue_setup() BEFORE configure.
 *                   On net_tap ethdev rejects it (-EINVAL). On net_null in
 *                   26.11 it crashes with SIGSEGV inside eth_dev_rxq_release():
 *                   the null PMD sets data->nb_rx_queues = 1 at probe time,
 *                   so the queue-id check passes, but data->rx_queues is still
 *                   NULL until configure allocates it. Lesson: configure first.
 *
 * Run here (with lib.ethdev at INFO so its explanations are printed):
 *   ./lifecycle_rules -l 0 --no-pci --no-huge -m 64 --file-prefix=ch08-rules \
 *       --vdev=net_null0 --log-level=lib.ethdev:info
 */
#include <stdio.h>
#include <string.h>

#include <rte_eal.h>
#include <rte_errno.h>
#include <rte_ethdev.h>
#include <rte_mbuf.h>

static void
show(const char *what, int ret)
{
	/* Flush stdout so our line comes right after ethdev's log line. */
	printf("  %-40s -> %4d %s\n", what, ret, ret < 0 ? rte_strerror(-ret) : "");
	fflush(stdout);
}

int
main(int argc, char **argv)
{
	struct rte_eth_conf conf;
	uint16_t port = 0;
	int early = 0;

	int ret = rte_eal_init(argc, argv);
	if (ret < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	for (int i = ret + 1; i < argc; i++)
		if (strcmp(argv[i], "--early-setup") == 0)
			early = 1;
	if (!rte_eth_dev_is_valid_port(port))
		rte_exit(EXIT_FAILURE, "need --vdev=net_null0\n");
	struct rte_mempool *mp = rte_pktmbuf_pool_create("ch08_rules", 1023, 0, 0,
			RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
	if (mp == NULL)
		rte_exit(EXIT_FAILURE, "pool: %s\n", rte_strerror(rte_errno));
	memset(&conf, 0, sizeof(conf));
	setvbuf(stdout, NULL, _IOLBF, 0);

	struct rte_eth_dev_info info;
	if (rte_eth_dev_info_get(port, &info) == 0)
		printf("port %u driver %s\n", port, info.driver_name);
	printf("state: probed, not configured\n");
	show("rte_eth_dev_start", rte_eth_dev_start(port));
	if (early) {
		printf("  (calling rte_eth_rx_queue_setup before configure...)\n");
		show("rte_eth_rx_queue_setup(q0)", rte_eth_rx_queue_setup(port, 0, 512, SOCKET_ID_ANY, NULL, mp));
	}

	show("rte_eth_dev_configure(1 rxq, 1 txq)", rte_eth_dev_configure(port, 1, 1, &conf));
	printf("state: configured, queues NOT set up\n");
	show("rte_eth_rx_queue_setup(q1)  [only 1 rxq]", rte_eth_rx_queue_setup(port, 1, 512, SOCKET_ID_ANY, NULL, mp));
	/* ethdev itself does not check that every queue was set up: */
	show("rte_eth_dev_start  [no queues!]", rte_eth_dev_start(port));
	show("rte_eth_dev_stop", rte_eth_dev_stop(port));

	show("rte_eth_rx_queue_setup(q0)", rte_eth_rx_queue_setup(port, 0, 512, SOCKET_ID_ANY, NULL, mp));
	show("rte_eth_tx_queue_setup(q0)", rte_eth_tx_queue_setup(port, 0, 512, SOCKET_ID_ANY, NULL));
	show("rte_eth_dev_start", rte_eth_dev_start(port));
	printf("state: started\n");
	show("rte_eth_dev_start  [again]", rte_eth_dev_start(port));
	show("rte_eth_dev_configure", rte_eth_dev_configure(port, 1, 1, &conf));
	show("rte_eth_rx_queue_setup(q0)", rte_eth_rx_queue_setup(port, 0, 512, SOCKET_ID_ANY, NULL, mp));
	show("rte_eth_dev_close  [while started]", rte_eth_dev_close(port));

	show("rte_eth_dev_stop", rte_eth_dev_stop(port));
	printf("state: stopped\n");
	show("rte_eth_dev_stop  [again]", rte_eth_dev_stop(port));
	show("rte_eth_dev_configure(1, 1)", rte_eth_dev_configure(port, 1, 1, &conf));
	show("rte_eth_rx_queue_setup(q0)", rte_eth_rx_queue_setup(port, 0, 512, SOCKET_ID_ANY, NULL, mp));
	show("rte_eth_dev_close", rte_eth_dev_close(port));
	printf("state: closed (port id released)\n");
	show("rte_eth_dev_is_valid_port", rte_eth_dev_is_valid_port(port));
	show("rte_eth_dev_configure", rte_eth_dev_configure(port, 1, 1, &conf));

	rte_mempool_free(mp);
	rte_eal_cleanup();
	return 0;
}
