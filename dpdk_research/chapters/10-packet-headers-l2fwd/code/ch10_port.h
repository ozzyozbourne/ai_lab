/* SPDX-License-Identifier: BSD-3-Clause
 * Chapter 10 shared helper: bring one port up with 1 RX and 1 TX queue.
 * This is exactly the ethdev lifecycle from chapter 8 (configure, queue
 * setup, start), packed into one function so the chapter 10 programs can
 * focus on packet bytes.
 */
#ifndef CH10_PORT_H
#define CH10_PORT_H

#include <stdio.h>
#include <rte_ethdev.h>
#include <rte_mbuf.h>

#define CH10_RX_DESC 512
#define CH10_TX_DESC 512

static inline int
ch10_port_init(uint16_t port, struct rte_mempool *pool)
{
	struct rte_eth_conf conf = {0};
	int ret;

	ret = rte_eth_dev_configure(port, 1, 1, &conf);
	if (ret < 0)
		return ret;
	ret = rte_eth_rx_queue_setup(port, 0, CH10_RX_DESC,
			rte_eth_dev_socket_id(port), NULL, pool);
	if (ret < 0)
		return ret;
	ret = rte_eth_tx_queue_setup(port, 0, CH10_TX_DESC,
			rte_eth_dev_socket_id(port), NULL);
	if (ret < 0)
		return ret;
	return rte_eth_dev_start(port);
}

#endif
