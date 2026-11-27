/* Compare: per-packet syscall (UDP sendto on loopback) vs DPDK burst on net_null */
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <rte_eal.h>
#include <rte_ethdev.h>
#include <rte_mbuf.h>
#include <rte_cycles.h>
#define N 2000000
#define BURST 32
int main(int argc, char **argv) {
    if (rte_eal_init(argc, argv) < 0) return 1;
    /* kernel path */
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in a = {.sin_family=AF_INET, .sin_port=htons(9), .sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
    char buf[64] = {0};
    uint64_t t0 = rte_rdtsc();
    int KN = 300000;
    for (int i = 0; i < KN; i++) sendto(fd, buf, sizeof buf, 0, (void*)&a, sizeof a);
    uint64_t t1 = rte_rdtsc();
    double hz = rte_get_tsc_hz();
    printf("kernel sendto : %.1f ns/pkt  (%.2f Mpps)\n", (t1-t0)/hz*1e9/KN, KN/((t1-t0)/hz)/1e6);
    /* DPDK path */
    struct rte_mempool *mp = rte_pktmbuf_pool_create("mp", 8191, 256, 0, RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
    struct rte_eth_conf conf = {0};
    uint16_t port = 0;
    rte_eth_dev_configure(port, 1, 1, &conf);
    rte_eth_rx_queue_setup(port, 0, 512, rte_socket_id(), NULL, mp);
    rte_eth_tx_queue_setup(port, 0, 512, rte_socket_id(), NULL);
    rte_eth_dev_start(port);
    struct rte_mbuf *pk[BURST];
    uint64_t rx = 0, tx = 0;
    t0 = rte_rdtsc();
    while (rx < N) {
        uint16_t n = rte_eth_rx_burst(port, 0, pk, BURST);
        rx += n;
        uint16_t s = rte_eth_tx_burst(port, 0, pk, n);
        tx += s;
        for (uint16_t i = s; i < n; i++) rte_pktmbuf_free(pk[i]);
    }
    t1 = rte_rdtsc();
    printf("dpdk rx+tx burst(net_null): %.1f ns/pkt  (%.2f Mpps)\n", (t1-t0)/hz*1e9/rx, rx/((t1-t0)/hz)/1e6);
    rte_eth_dev_stop(port); rte_eth_dev_close(port);
    rte_eal_cleanup();
    return 0;
}
