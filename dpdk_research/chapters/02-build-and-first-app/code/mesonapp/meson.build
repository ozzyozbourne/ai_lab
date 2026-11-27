# SPDX-License-Identifier: BSD-3-Clause
# Chapter 2: an out-of-tree meson project that links DPDK *statically*.
#
#   meson setup build && ninja -C build && ./build/app <EAL args>
#   meson setup build-bad -Dlink_mode=declare_dep   (the pitfall)
#
project('ch02-mesonapp', 'c', default_options: ['warning_level=2'])

# 1. Compile flags (include path, -include rte_config.h, -march=native)
#    come from the normal pkg-config dependency.
dpdk = dependency('libdpdk')
dpdk_cflags = dpdk.partial_dependency(compile_args: true, includes: true)

# 2. Link flags: ask pkg-config for the --static list.
pkgconf = find_program('pkg-config')
static_libs = run_command(pkgconf, '--libs', '--static', 'libdpdk',
                          check: true).stdout().strip().split()

srcs = ['main.c', 'util.c']
cargs = ['-DALLOW_EXPERIMENTAL_API']   # we call rte_cpu_socket_id()
mode = get_option('link_mode')

if mode == 'link_args'
    # Correct: pass the list unmodified through executable(link_args:), so
    # the -Wl,--whole-archive ... -Wl,--no-whole-archive bracket stays intact.
    executable('app', srcs, c_args: cargs, dependencies: dpdk_cflags,
               link_args: static_libs)
elif mode == 'declare_dep'
    # Pitfall: meson de-duplicates and reorders the link arguments of a
    # dependency object, which breaks the --whole-archive bracket.
    dpdk_static = declare_dependency(link_args: static_libs)
    executable('app', srcs, c_args: cargs,
               dependencies: [dpdk_cflags, dpdk_static])
else
    # Shared libraries: what plain dependency('libdpdk') gives you.
    executable('app', srcs, c_args: cargs, dependencies: dpdk)
endif
