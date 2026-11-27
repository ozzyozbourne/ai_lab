# SPDX-License-Identifier: BSD-3-Clause
# Chapter 12 Makefile. Run "source <dpdk-env.sh>" first so that pkg-config
# finds libdpdk.pc. Every program links DPDK statically.

PKGCONF ?= pkg-config

ifneq ($(shell $(PKGCONF) --exists libdpdk && echo 0),0)
$(error "no installation of DPDK found (is PKG_CONFIG_PATH set?)")
endif

# rte_eth_bond_* lives in drivers/net/bonding/rte_eth_bond.h (installed).
# No experimental API is needed: every call used here is stable in 26.11
# (the build would fail without -DALLOW_EXPERIMENTAL_API otherwise).
CFLAGS += -O2 -g -Wall -Wextra $(shell $(PKGCONF) --cflags libdpdk)
LDLIBS  = $(shell $(PKGCONF) --libs --static libdpdk) -lpthread

APPS = port_ctl events rxtx_latency queue_ctl runtime_reconf bonding_modes failure_lab
SOLS = lsc_poll drain_restart

all: $(APPS) $(SOLS)

%: %.c ch12_common.h
	$(CC) $(CFLAGS) $< -o $@ $(LDLIBS)

%: solutions/%.c ch12_common.h
	$(CC) $(CFLAGS) -I. $< -o $@ $(LDLIBS)

clean:
	rm -f $(APPS) $(SOLS)

.PHONY: all clean
