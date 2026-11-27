# SPDX-License-Identifier: BSD-3-Clause
# Chapter 9 Makefile. Run "source <dpdk-env.sh>" first so that pkg-config
# finds libdpdk.pc. Every program links DPDK statically.

PKGCONF ?= pkg-config

ifneq ($(shell $(PKGCONF) --exists libdpdk && echo 0),0)
$(error "no installation of DPDK found (is PKG_CONFIG_PATH set?)")
endif

# No experimental or internal API is used in this chapter.
CFLAGS += -O2 -g -Wall -Wextra $(shell $(PKGCONF) --cflags libdpdk)
LDLIBS  = $(shell $(PKGCONF) --libs --static libdpdk) -lpthread

APPS = kvargs_demo vdev_runtime devargs_iter

all: $(APPS)

%: %.c
	$(CC) $(CFLAGS) $< -o $@ $(LDLIBS)

clean:
	rm -f $(APPS) *.pcap.out

.PHONY: all clean
