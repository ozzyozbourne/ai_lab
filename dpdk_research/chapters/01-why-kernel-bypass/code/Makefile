# Chapter 01 examples. Needs pkg-config to find libdpdk (static link):
#   source <your env.sh> ; make
APPS = hello_dpdk bypass_bench intr_vs_poll

PKGCONF ?= pkg-config
CC      ?= gcc
CFLAGS  += -O2 -g -Wall $(shell $(PKGCONF) --cflags libdpdk)
LDLIBS  += $(shell $(PKGCONF) --libs --static libdpdk)

all: $(APPS)

%: %.c
	$(CC) $(CFLAGS) $< -o $@ $(LDFLAGS) $(LDLIBS)

clean:
	$(RM) $(APPS)

.PHONY: all clean
