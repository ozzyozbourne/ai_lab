# SPDX-License-Identifier: BSD-3-Clause
# Chapter 7 Makefile. Run "source <dpdk-env.sh>" first so that pkg-config
# finds libdpdk.pc. Every program links DPDK statically.

PKGCONF ?= pkg-config

ifneq ($(shell $(PKGCONF) --exists libdpdk && echo 0),0)
$(error "no installation of DPDK found (is PKG_CONFIG_PATH set?)")
endif

# ALLOW_EXPERIMENTAL_API: rte_mbuf_history_dump_all() (debug_aids.c) is experimental.
CFLAGS += -O2 -g -Wall -Wextra -DALLOW_EXPERIMENTAL_API $(shell $(PKGCONF) --cflags libdpdk)
LDLIBS  = $(shell $(PKGCONF) --libs --static libdpdk) -lpthread

APPS = mbuf_anatomy payload_build chain_demo clone_extbuf dynfield_demo pool_ops debug_aids
SOLS = vlan_prepend clone_corrupt dyn_order

all: $(APPS) $(SOLS)

%: %.c
	$(CC) $(CFLAGS) $< -o $@ $(LDLIBS)

%: solutions/%.c
	$(CC) $(CFLAGS) $< -o $@ $(LDLIBS)

clean:
	rm -f $(APPS) $(SOLS)

.PHONY: all clean
