# Makefile.inc - shared rules for chapter code/ Makefiles.
#
# In chapters/NN-slug/code/Makefile:
#     APPS = hello_dpdk ring_demo     # one program per <app>.c
#     # optional: EXPERIMENTAL = 1    -> -DALLOW_EXPERIMENTAL_API
#     # optional: EXTRA_CFLAGS, EXTRA_LDLIBS, per-app sources: ring_demo_SRCS = a.c b.c
#     include ../../../common/Makefile.inc
#
# Targets: all (default), clean, check-env.
# pkg-config must find libdpdk.pc: source common/env.sh first.

PKGCONF ?= pkg-config
CC      ?= gcc

ifneq ($(MAKECMDGOALS),clean)
ifeq ($(shell $(PKGCONF) --exists libdpdk && echo yes),)
$(error libdpdk not found by pkg-config: source common/env.sh (PKG_CONFIG_PATH))
endif
endif

DPDK_CFLAGS := $(shell $(PKGCONF) --cflags libdpdk 2>/dev/null)
DPDK_LDLIBS := $(shell $(PKGCONF) --libs --static libdpdk 2>/dev/null)

CFLAGS += -O2 -g -Wall $(DPDK_CFLAGS)
ifeq ($(EXPERIMENTAL),1)
CFLAGS += -DALLOW_EXPERIMENTAL_API
endif
CFLAGS += $(EXTRA_CFLAGS)
LDLIBS += $(DPDK_LDLIBS) $(EXTRA_LDLIBS)

.DEFAULT_GOAL := all
all: $(APPS)

# each app is built from <app>_SRCS when set, else from <app>.c
.SECONDEXPANSION:
$(APPS): $$(if $$($$@_SRCS),$$($$@_SRCS),$$@.c)
	$(CC) $(CFLAGS) $^ -o $@ $(LDFLAGS) $(LDLIBS)

clean:
	$(RM) $(APPS) *.o

check-env:
	@echo "libdpdk $$($(PKGCONF) --modversion libdpdk)"
	@echo "CFLAGS = $(CFLAGS)"

.PHONY: all clean check-env
