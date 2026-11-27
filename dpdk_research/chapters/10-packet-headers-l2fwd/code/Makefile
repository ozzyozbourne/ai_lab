# SPDX-License-Identifier: BSD-3-Clause
# Chapter 10 Makefile. Run "source <dpdk-env.sh>" first so that pkg-config
# finds libdpdk.pc. Every program links DPDK statically.
#
# ALLOW_EXPERIMENTAL_API: build_packets.c calls rte_vlan_insert_tpid() and
# cksum_lab.c calls rte_ipv4_cksum_simple(); both are __rte_experimental in
# 26.11: without this flag gcc warns "'rte_vlan_insert_tpid' is deprecated:
# Symbol is not yet part of stable ABI" (an error under -Werror).

PKGCONF ?= pkg-config

ifneq ($(shell $(PKGCONF) --exists libdpdk && echo 0),0)
$(error "no installation of DPDK found (is PKG_CONFIG_PATH set?)")
endif

CFLAGS += -O2 -g -Wall -Wextra -DALLOW_EXPERIMENTAL_API $(shell $(PKGCONF) --cflags libdpdk)
LDLIBS  = $(shell $(PKGCONF) --libs --static libdpdk) -lpthread

APPS = parse_pcap build_packets cksum_lab mini_l2fwd
SOLS = parse_vlan incr_cksum mini_l2fwd_filter

all: $(APPS) $(SOLS)

%: %.c ch10_port.h
	$(CC) $(CFLAGS) $< -o $@ $(LDLIBS)

%: solutions/%.c ch10_port.h
	$(CC) $(CFLAGS) -I. $< -o $@ $(LDLIBS)


clean:
	rm -f $(APPS) $(SOLS) *.o built.pcap built.crc mini_out*.pcap l2out*.pcap

.PHONY: all clean
