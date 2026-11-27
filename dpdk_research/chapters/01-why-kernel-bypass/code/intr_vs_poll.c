/* SPDX-License-Identifier: BSD-3-Clause
 * intr_vs_poll.c - PEEK AHEAD for chapter 01 (Rx interrupts are built
 * properly, from scratch, in ch22). Run it and compare the two modes.
 *
 * One net_tap port, one Rx queue, a fixed wall-clock duration.
 *   poll : the classic DPDK loop - call rte_eth_rx_burst() as fast as
 *          possible, whether or not anything arrived. 100% of one core.
 *   intr : when a poll returns 0 packets, arm the queue's Rx interrupt and
 *          sleep in rte_epoll_wait() (up to 100 ms). Wake up on a packet or
 *          on the timeout, disarm, and poll again.
 * At the end we print packets, polls, wake-ups and the CPU time the process
 * used (getrusage), so you can see what polling costs when the link is idle.
 *
 * Latency: inject.py (run.sh starts it) writes frames into the kernel side of
 * the tap interface. Each frame carries the sender's CLOCK_MONOTONIC time in
 * ns at byte offset 14 (right after the Ethernet header). We read the clock
 * again when rte_eth_rx_burst() hands us the frame; the difference is the
 * send -> kernel -> tap -> DPDK latency, which includes the wake-up time in
 * intr mode.
 *
 * Usage: ./intr_vs_poll <EAL args> --vdev=net_tap0,iface=ch01tap0 -- poll|intr [seconds]
 *        (seconds defaults to 3)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <time.h>
#include <sys/resource.h>

#include <rte_eal.h>
#include <rte_debug.h>
#include <rte_lcore.h>
#include <rte_ethdev.h>
#include <rte_mbuf.h>
#include <rte_interrupts.h>
#include <rte_epoll.h>
#include <rte_cycles.h>

static volatile int quit;
static void on_sig(int s) { (void)s; quit = 1; }

static double tv(struct timeval t) { return t.tv_sec + t.tv_usec / 1e6; }

#define MAX_SAMPLES 65536
static double lat_us[MAX_SAMPLES];
static unsigned int nb_lat;

static uint64_t now_ns(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000000ull + ts.tv_nsec;
}

/* If the frame carries a send timestamp, record its one-way latency. */
static void sample_latency(struct rte_mbuf *m, uint64_t t_rx)
{
	uint64_t t_tx;
	if (rte_pktmbuf_pkt_len(m) < 22 || nb_lat >= MAX_SAMPLES)
		return;
	memcpy(&t_tx, rte_pktmbuf_mtod_offset(m, char *, 14), sizeof(t_tx));
	if (t_tx < t_rx && t_rx - t_tx < 1000000000ull)  /* sane: < 1 s */
		lat_us[nb_lat++] = (t_rx - t_tx) / 1e3;
}

static int cmp_double(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;
	return (x > y) - (x < y);
}

int main(int argc, char **argv)
{
	int ret = rte_eal_init(argc, argv);
	if (ret < 0)
		rte_exit(EXIT_FAILURE, "rte_eal_init failed\n");
	argc -= ret;
	argv += ret;
	int use_intr = argc > 1 && strcmp(argv[1], "intr") == 0;
	int secs = argc > 2 ? atoi(argv[2]) : 3;
	signal(SIGINT, on_sig);
	signal(SIGTERM, on_sig);

	uint16_t port = 0;
	struct rte_mempool *mp = rte_pktmbuf_pool_create("ivp_pool", 4095, 128,
				0, RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
	struct rte_eth_conf conf;
	memset(&conf, 0, sizeof(conf));
	conf.intr_conf.rxq = use_intr;          /* ask the PMD for Rx interrupts */
	if (mp == NULL || rte_eth_dev_configure(port, 1, 1, &conf) != 0 ||
	    rte_eth_rx_queue_setup(port, 0, 256, rte_socket_id(), NULL, mp) != 0 ||
	    rte_eth_tx_queue_setup(port, 0, 256, rte_socket_id(), NULL) != 0 ||
	    rte_eth_dev_start(port) != 0)
		rte_exit(EXIT_FAILURE, "port setup failed\n");

	/* Register queue 0's interrupt fd with this thread's epoll instance. */
	if (use_intr && rte_eth_dev_rx_intr_ctl_q(port, 0, RTE_EPOLL_PER_THREAD,
				RTE_INTR_EVENT_ADD, NULL) != 0)
		rte_exit(EXIT_FAILURE, "rte_eth_dev_rx_intr_ctl_q failed\n");

	uint64_t pkts = 0, polls = 0, empty = 0, wakeups = 0;
	struct rte_mbuf *b[32];
	uint64_t hz = rte_get_tsc_hz();
	uint64_t start = rte_rdtsc(), end = start + secs * hz;

	while (!quit && rte_rdtsc() < end) {
		uint16_t n = rte_eth_rx_burst(port, 0, b, 32);
		polls++;
		pkts += n;
		if (n != 0) {
			uint64_t t_rx = now_ns();
			for (uint16_t i = 0; i < n; i++)
				sample_latency(b[i], t_rx);
		}
		rte_pktmbuf_free_bulk(b, n);       /* we only count packets */
		if (n != 0)
			continue;
		empty++;
		if (use_intr) {
			struct rte_epoll_event ev;
			rte_eth_dev_rx_intr_enable(port, 0);   /* arm   */
			rte_epoll_wait(RTE_EPOLL_PER_THREAD, &ev, 1, 100); /* sleep */
			rte_eth_dev_rx_intr_disable(port, 0);  /* disarm */
			wakeups++;
		}
	}
	double wall = (double)(rte_rdtsc() - start) / hz;

	struct rusage ru;
	getrusage(RUSAGE_SELF, &ru);
	double u = tv(ru.ru_utime), s = tv(ru.ru_stime);
	printf("mode=%-4s wall=%.2fs pkts=%lu polls=%lu empty_polls=%lu wakeups=%lu "
	       "user=%.2fs sys=%.2fs cpu=%.1f%% ivcsw=%ld\n",
	       use_intr ? "intr" : "poll", wall, (unsigned long)pkts,
	       (unsigned long)polls, (unsigned long)empty, (unsigned long)wakeups,
	       u, s, 100.0 * (u + s) / wall,
	       ru.ru_nivcsw);  /* involuntary context switches: someone else
				* wanted this core (it is not isolated) */
	if (nb_lat > 0) {
		qsort(lat_us, nb_lat, sizeof(double), cmp_double);
		printf("          latency send->rx_burst over %u pkts: median %.1f us "
		       "(min %.1f, p99 %.1f, max %.1f)\n", nb_lat,
		       lat_us[nb_lat / 2], lat_us[0], lat_us[nb_lat * 99 / 100],
		       lat_us[nb_lat - 1]);
	}

	rte_eth_dev_stop(port);
	rte_eth_dev_close(port);
	rte_eal_cleanup();
	return 0;
}
