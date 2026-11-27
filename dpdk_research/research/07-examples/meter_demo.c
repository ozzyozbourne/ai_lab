/* meter_demo.c - srTCM and trTCM color decisions with synthetic time.
 * Offered load: 1500B packets at 2x CIR. Prints colour counts per 100 ms.
 * run: ./meter_demo --no-huge -m 64 --no-pci --file-prefix=ch07m */
#include <stdio.h>
#include <rte_eal.h>
#include <rte_cycles.h>
#include <rte_meter.h>

int main(int argc, char **argv)
{
	if (rte_eal_init(argc, argv) < 0) return 1;
	uint64_t hz = rte_get_tsc_hz();
	struct rte_meter_srtcm_params sp = { .cir = 1000000, .cbs = 15000, .ebs = 30000 };
	struct rte_meter_trtcm_params tp = { .cir = 1000000, .pir = 1500000, .cbs = 15000, .pbs = 15000 };
	struct rte_meter_srtcm_profile spp; struct rte_meter_trtcm_profile tpp;
	struct rte_meter_srtcm sm; struct rte_meter_trtcm tm;
	rte_meter_srtcm_profile_config(&spp, &sp); rte_meter_srtcm_config(&sm, &spp);
	rte_meter_trtcm_profile_config(&tpp, &tp); rte_meter_trtcm_config(&tm, &tpp);
	const char *nm[] = { "G", "Y", "R" };
	uint64_t t = rte_rdtsc();          /* meters were stamped with "now" at config */
	uint64_t gap = hz * 1500 / 2000000; /* 2 MB/s offered = 2x CIR */
	printf("t(ms)  srTCM[G Y R]   trTCM[G Y R]\n");
	for (int win = 0; win < 10; win++) {
		unsigned s[3] = {0}, r[3] = {0};
		for (int i = 0; i < 2000000 / 1500 / 10; i++) {   /* packets per 100 ms */
			t += gap;
			s[rte_meter_srtcm_color_blind_check(&sm, &spp, t, 1500)]++;
			r[rte_meter_trtcm_color_blind_check(&tm, &tpp, t, 1500)]++;
		}
		printf("%4d   %3u %3u %3u    %3u %3u %3u\n", (win + 1) * 100,
		       s[0], s[1], s[2], r[0], r[1], r[2]);
	}
	(void)nm;
	rte_eal_cleanup();
	return 0;
}
