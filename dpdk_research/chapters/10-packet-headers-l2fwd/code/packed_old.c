/* SPDX-License-Identifier: BSD-3-Clause
 * Chapter 10: packed_old.c - COMPILE-ONLY demo of the removed __rte_packed.
 *
 * Tutorials written for DPDK <= 25.x declare packed headers with a trailing
 * __rte_packed. 26.11 removed that macro (release_26_11.rst, "Removed
 * Items"). What happens to old code depends on how it was written:
 *
 *   VARIANT 1  struct hdr { ... } __rte_packed;
 *      Still COMPILES, silently: '__rte_packed' is now just an identifier,
 *      so this declares a global VARIABLE named __rte_packed of an UNPACKED
 *      12-byte struct type. Only a size check catches it.
 *   VARIANT 2  typedef struct { ... } __rte_packed hdr_t;
 *      Syntax error.
 *
 * run.sh builds both and shows the results. The 26.11 spelling is:
 *   struct __rte_packed_begin hdr { ... } __rte_packed_end;
 */
#include <stdint.h>
#include <assert.h>
#include <rte_common.h>
#include <rte_byteorder.h>

#if VARIANT == 1
struct old_style_hdr {
	uint8_t    ver;
	uint8_t    flags;
	rte_be32_t session;
	rte_be16_t seq;
} __rte_packed;
#ifdef WITH_SIZE_CHECK
static_assert(sizeof(struct old_style_hdr) == 8, "toy header must be 8 bytes");
#endif
#elif VARIANT == 2
typedef struct {
	uint8_t    ver;
	uint8_t    flags;
	rte_be32_t session;
	rte_be16_t seq;
} __rte_packed old_style_hdr_t;
#endif
