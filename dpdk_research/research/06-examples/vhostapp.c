/* Minimal vhost-user backend using librte_vhost directly (no net_vhost PMD). */
#include <stdio.h>
#include <signal.h>
#include <unistd.h>
#include <rte_eal.h>
#include <rte_mbuf.h>
#include <rte_vhost.h>
#include <rte_cycles.h>

static volatile int vid_ready = -1, quit;
static int new_device(int vid) {
	char ifn[64]; uint64_t f; rte_vhost_get_ifname(vid, ifn, sizeof(ifn));
	rte_vhost_get_negotiated_features(vid, &f);
	printf("new_device vid=%d %s features=0x%lx vrings=%u\n", vid, ifn, f, rte_vhost_get_vring_num(vid));
	vid_ready = vid; return 0;
}
static void destroy_device(int vid) { printf("destroy_device vid=%d\n", vid); vid_ready = -1; }
static int vring_state_changed(int vid, uint16_t q, int en) { printf("vring %u %s\n", q, en ? "enabled" : "disabled"); return 0; }
static const struct rte_vhost_device_ops ops = {
	.new_device = new_device, .destroy_device = destroy_device, .vring_state_changed = vring_state_changed,
};
static void sig(int s) { (void)s; quit = 1; }

int main(int argc, char **argv) {
	const char *path = "/run/ch06vapp.sock";
	if (rte_eal_init(argc, argv) < 0) return 1;
	signal(SIGINT, sig);
	struct rte_mempool *mp = rte_pktmbuf_pool_create("mp", 8191, 256, 0, RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
	unlink(path);
	if (rte_vhost_driver_register(path, 0) ||
	    rte_vhost_driver_callback_register(path, &ops) ||
	    rte_vhost_driver_start(path)) { printf("vhost setup failed\n"); return 1; }
	uint64_t total = 0, last = rte_get_timer_cycles();
	struct rte_mbuf *pkts[32];
	while (!quit) {
		if (vid_ready < 0) { usleep(1000); continue; }
		/* queue 1 = guest TX virtqueue (odd index); queue 0 = guest RX */
		uint16_t n = rte_vhost_dequeue_burst(vid_ready, 1, mp, pkts, 32);
		if (n) {
			/* echo back into guest RX ring */
			uint16_t e = rte_vhost_enqueue_burst(vid_ready, 0, pkts, n);
			rte_pktmbuf_free_bulk(pkts, n); /* enqueue copies; we still own mbufs */
			total += e;
		}
		if (rte_get_timer_cycles() - last > rte_get_timer_hz()) {
			printf("echoed %lu pkts\n", total); last = rte_get_timer_cycles();
		}
	}
	rte_vhost_driver_unregister(path);
	rte_eal_cleanup();
	return 0;
}
