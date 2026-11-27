/* mp_ipc.c - DPDK IPC: secondary sends sync request, primary replies; shared memzone */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <time.h>
#include <rte_eal.h>
#include <rte_memzone.h>
#include <rte_errno.h>
#include <rte_lcore.h>

#define ACTION "ch02_ping"

static int on_ping(const struct rte_mp_msg *msg, const void *peer)
{
	struct rte_mp_msg reply;
	memset(&reply, 0, sizeof(reply));
	snprintf(reply.name, sizeof(reply.name), "%s", ACTION);
	reply.len_param = snprintf((char *)reply.param, sizeof(reply.param),
				   "pong to '%.*s' from pid %d", msg->len_param,
				   (const char *)msg->param, getpid()) + 1;
	return rte_mp_reply(&reply, peer);
}

int main(int argc, char **argv)
{
	if (rte_eal_init(argc, argv) < 0) {
		fprintf(stderr, "init: %s\n", rte_strerror(rte_errno));
		return 1;
	}
	if (rte_eal_process_type() == RTE_PROC_PRIMARY) {
		const struct rte_memzone *mz = rte_memzone_reserve("ch02_shared", 64, SOCKET_ID_ANY, 0);
		snprintf(mz->addr, 64, "written by primary pid %d", getpid());
		printf("[P] memzone va=%p iova=0x%lx\n", mz->addr, (unsigned long)mz->iova);
		rte_mp_action_register(ACTION, on_ping);
		sleep(6); /* serve requests */
		printf("[P] memzone now: %s\n", (char *)mz->addr);
	} else {
		const struct rte_memzone *mz = rte_memzone_lookup("ch02_shared");
		printf("[S] memzone va=%p content='%s'\n", mz->addr, (char *)mz->addr);
		snprintf(mz->addr, 64, "overwritten by secondary pid %d", getpid());
		struct rte_mp_msg req; struct rte_mp_reply rep;
		struct timespec ts = { .tv_sec = 2 };
		memset(&req, 0, sizeof(req));
		snprintf(req.name, sizeof(req.name), "%s", ACTION);
		req.len_param = snprintf((char *)req.param, sizeof(req.param), "ping");
		if (rte_mp_request_sync(&req, &rep, &ts) == 0 && rep.nb_received == 1) {
			printf("[S] sent=%d received=%d reply='%s'\n", rep.nb_sent, rep.nb_received,
			       (char *)rep.msgs[0].param);
			free(rep.msgs);  /* caller frees sync replies */
		}
	}
	rte_eal_cleanup();
	return 0;
}
