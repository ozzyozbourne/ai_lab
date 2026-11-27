/* ex1_budget.c - chapter 01, exercise 1 (no DPDK needed).
 * Per-packet time budget: pps, ns/packet, cycles/packet and how many
 * ~80 ns DRAM misses fit, for a few link speeds and frame sizes.
 * Build: gcc -O2 -Wall ex1_budget.c -o ex1_budget
 */
#include <stdio.h>

#define WIRE_OVERHEAD 20   /* preamble+SFD (8) + inter-frame gap (12), bytes */
#define DRAM_NS       80.0 /* rough cost of one cache miss to DRAM */

static void row(double gbps, int frame, double ghz)
{
	double bits = (frame + WIRE_OVERHEAD) * 8.0;
	double pps = gbps * 1e9 / bits;
	double ns = 1e9 / pps;
	printf("%6.0f GbE %5d B %4.1f GHz | %8.2f Mpps %8.2f ns %7.0f cycles %5.2f DRAM misses\n",
	       gbps, frame, ghz, pps / 1e6, ns, ns * ghz, ns / DRAM_NS);
}

int main(void)
{
	printf("exercise 1: 25 GbE, 128-byte frames, 3.0 GHz\n");
	row(25, 128, 3.0);
	printf("\nfor comparison (64-byte frames, 2.7 GHz like this VM):\n");
	row(10, 64, 2.7);
	row(25, 64, 2.7);
	row(100, 64, 2.7);
	row(400, 64, 2.7);
	return 0;
}
