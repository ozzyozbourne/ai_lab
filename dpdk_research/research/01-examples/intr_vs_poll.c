/* Rx on net_tap either busy-polling or sleeping on Rx interrupts (epoll). argv after -- : poll|intr */
#include <stdio.h>
#include <string.h>
#include <signal.h>
#include <sys/resource.h>
#include <rte_eal.h>
#include <rte_ethdev.h>
#include <rte_mbuf.h>
#include <rte_interrupts.h>
#include <rte_cycles.h>
static volatile int quit;
static void on_sig(int s){(void)s; quit=1;}
int main(int argc, char **argv) {
    int r = rte_eal_init(argc, argv); if (r < 0) return 1;
    argc -= r; argv += r;
    int use_intr = argc > 1 && !strcmp(argv[1], "intr");
    signal(SIGINT, on_sig); signal(SIGTERM, on_sig);
    struct rte_mempool *mp = rte_pktmbuf_pool_create("mp", 4095, 128, 0, RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
    struct rte_eth_conf conf = {0};
    conf.intr_conf.rxq = use_intr;
    if (rte_eth_dev_configure(0, 1, 1, &conf)) { printf("configure failed\n"); return 1; }
    rte_eth_rx_queue_setup(0, 0, 256, rte_socket_id(), NULL, mp);
    rte_eth_tx_queue_setup(0, 0, 256, rte_socket_id(), NULL);
    rte_eth_dev_start(0);
    if (use_intr && rte_eth_dev_rx_intr_ctl_q(0, 0, RTE_EPOLL_PER_THREAD, RTE_INTR_EVENT_ADD, NULL)) { printf("intr ctl failed\n"); return 1; }
    uint64_t pkts = 0, wakeups = 0, polls = 0;
    struct rte_mbuf *b[32];
    uint64_t end = rte_rdtsc() + 5 * rte_get_tsc_hz();
    while (!quit && rte_rdtsc() < end) {
        uint16_t n = rte_eth_rx_burst(0, 0, b, 32); polls++;
        pkts += n; rte_pktmbuf_free_bulk(b, n);
        if (n == 0 && use_intr) {
            struct rte_epoll_event ev;
            rte_eth_dev_rx_intr_enable(0, 0);
            rte_epoll_wait(RTE_EPOLL_PER_THREAD, &ev, 1, 100); /* sleep up to 100 ms */
            rte_eth_dev_rx_intr_disable(0, 0);
            wakeups++;
        }
    }
    struct rusage ru; getrusage(RUSAGE_SELF, &ru);
    printf("mode=%s pkts=%lu polls=%lu wakeups=%lu user_cpu=%.2fs sys_cpu=%.2fs (5s wall)\n", use_intr?"intr":"poll",
        pkts, polls, wakeups, ru.ru_utime.tv_sec+ru.ru_utime.tv_usec/1e6, ru.ru_stime.tv_sec+ru.ru_stime.tv_usec/1e6);
    rte_eth_dev_stop(0); rte_eth_dev_close(0); rte_eal_cleanup();
    return 0;
}
