# SPDX-License-Identifier: BSD-3-Clause
# Chapter 15 Makefile. Source the course env script first so that pkg-config
# finds libdpdk.pc. Every program links DPDK statically.
#
#   make          build all examples and the exercise solutions
#   make clean

PKGCONF ?= pkg-config

ifneq ($(MAKECMDGOALS),clean)
ifneq ($(shell $(PKGCONF) --exists libdpdk && echo 0),0)
$(error "no installation of DPDK found (is PKG_CONFIG_PATH set?)")
endif
endif

# ALLOW_EXPERIMENTAL_API: none of the APIs used here strictly need it in
# 26.11, but rte_thash_gen_key (mentioned in the text) is experimental.
CFLAGS += -O2 -g -Wall -Wextra -Wno-unused-parameter -DALLOW_EXPERIMENTAL_API \
	  $(shell $(PKGCONF) --cflags libdpdk)
LDLIBS  = $(shell $(PKGCONF) --libs --static libdpdk) -lpthread

APPS = rss_lab rtc_multiqueue pipeline_rings distributor_reorder
SOLS = reta_rebalance adjust4

all: $(APPS) $(SOLS)

%: %.c
	$(CC) $(CFLAGS) $< -o $@ $(LDLIBS)

%: solutions/%.c
	$(CC) $(CFLAGS) $< -o $@ $(LDLIBS)

clean:
	rm -f $(APPS) $(SOLS)

.PHONY: all clean
