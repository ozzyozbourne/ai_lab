# SPDX-License-Identifier: BSD-3-Clause
# Chapter 2 Makefile: build DPDK applications against an installed DPDK
# using pkg-config. Run "source <dpdk-env.sh>" first so that pkg-config
# can find libdpdk.pc (PKG_CONFIG_PATH).

PKGCONF ?= pkg-config

ifneq ($(shell $(PKGCONF) --exists libdpdk && echo 0),0)
$(error "no installation of DPDK found (is PKG_CONFIG_PATH set?)")
endif

CFLAGS  += -O2 -g -Wall -Wextra $(shell $(PKGCONF) --cflags libdpdk)

# Static link (the course default). The output starts with
#   -Wl,--whole-archive -l:librte_bus_pci.a ... -l:librte_log.a -Wl,--no-whole-archive
# so that every driver's constructor is kept.
LDLIBS_STATIC = $(shell $(PKGCONF) --libs --static libdpdk)

# Shared link: only -L<libdir> -lrte_xxx; drivers are loaded at run time
# from the plugin directory (RTE_EAL_PMD_PATH) or from -d <path>.
LDLIBS_SHARED = $(shell $(PKGCONF) --libs libdpdk)

# The pitfall: the same static flags with the --whole-archive bracket removed.
comma := ,
LDLIBS_BROKEN = $(filter-out -Wl$(comma)--whole-archive -Wl$(comma)--no-whole-archive,$(LDLIBS_STATIC))

APPS = hello args ports_ok ports_broken hello_shared verbose

all: $(APPS)

hello: hello.c
	$(CC) $(CFLAGS) $< -o $@ $(LDLIBS_STATIC)

args: args.c
	$(CC) $(CFLAGS) $< -o $@ $(LDLIBS_STATIC)

# make pitfall -> both port counters
pitfall: ports_ok ports_broken

ports_ok: ports.c
	$(CC) $(CFLAGS) $< -o $@ $(LDLIBS_STATIC)

ports_broken: ports.c
	$(CC) $(CFLAGS) $< -o $@ $(LDLIBS_BROKEN)

# make shared -> hello linked against the .so files
shared: hello_shared

hello_shared: hello.c
	$(CC) $(CFLAGS) $< -o $@ $(LDLIBS_SHARED)

# Exercise 1 solution
verbose: solutions/verbose.c
	$(CC) $(CFLAGS) $< -o $@ $(LDLIBS_STATIC)

clean:
	rm -f $(APPS)
	rm -rf mesonapp/build

.PHONY: all pitfall shared clean
