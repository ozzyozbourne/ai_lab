#!/usr/bin/env bash
# build_dpdk.sh - clone, build and install DPDK for this course (Debian/Ubuntu).
#
# Usage:
#   ./build_dpdk.sh [--prefix DIR] [--src DIR] [--tag v26.11] [--no-deps] [--examples all|none]
#
# Defaults: tag v26.11, source in ./dpdk, install prefix $HOME/dpdk-install.
# At the end it prints the lines to put in common/env.sh (PKG_CONFIG_PATH, PATH).
set -euo pipefail

TAG=v26.11
SRC="$PWD/dpdk"
PREFIX="$HOME/dpdk-install"
INSTALL_DEPS=1
EXAMPLES=all
REPO=https://dpdk.org/git/dpdk          # mirror: https://github.com/DPDK/dpdk.git

while [ $# -gt 0 ]; do
	case "$1" in
	--prefix)   PREFIX=$2; shift 2 ;;
	--src)      SRC=$2; shift 2 ;;
	--tag)      TAG=$2; shift 2 ;;
	--no-deps)  INSTALL_DEPS=0; shift ;;
	--examples) EXAMPLES=$2; shift 2 ;;
	--repo)     REPO=$2; shift 2 ;;
	-h|--help)  sed -n '2,9p' "$0"; exit 0 ;;
	*) echo "unknown option: $1" >&2; exit 1 ;;
	esac
done

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO=sudo

if [ "$INSTALL_DEPS" = 1 ]; then
	echo ">>> installing build dependencies (apt)"
	$SUDO apt-get update
	# required: compiler, meson >= 0.57, ninja, pyelftools, libnuma
	# optional: libpcap (net_pcap, dumpcap), libbpf/libxdp (net_af_xdp), openssl (crypto_openssl),
	#           zlib (compress_zlib), libelf (BPF loader), libarchive, jansson
	$SUDO apt-get install -y --no-install-recommends \
		build-essential git pkg-config python3 python3-pip python3-pyelftools \
		meson ninja-build libnuma-dev \
		libpcap-dev libbpf-dev libxdp-dev libssl-dev zlib1g-dev libelf-dev \
		libarchive-dev libjansson-dev gdb ||
		echo "!!! some optional packages failed to install; continuing" >&2
	# Old distributions ship a meson that is too old; fall back to pip.
	if ! meson --version | awk -F. '{exit !($1>0 || $2>=57)}'; then
		python3 -m pip install --user 'meson>=0.57'
		export PATH="$HOME/.local/bin:$PATH"
	fi
fi

if [ ! -d "$SRC/.git" ]; then
	echo ">>> cloning $REPO ($TAG) into $SRC"
	git clone --depth 1 --branch "$TAG" "$REPO" "$SRC"
else
	echo ">>> using existing source tree $SRC"
fi

cd "$SRC"
echo ">>> configuring (prefix $PREFIX)"
if [ -d build ]; then
	meson setup --reconfigure build --prefix="$PREFIX" -Dexamples="$EXAMPLES" -Dtests=false
else
	meson setup build --prefix="$PREFIX" -Dexamples="$EXAMPLES" -Dtests=false \
		-Dbuildtype=release
fi
echo ">>> building with $(nproc) jobs (5-30 minutes)"
ninja -C build -j"$(nproc)"
echo ">>> installing"
mkdir -p "$PREFIX" 2>/dev/null || $SUDO mkdir -p "$PREFIX"
if [ -w "$PREFIX" ]; then
	meson install -C build --quiet
else
	$SUDO meson install -C build --quiet
fi
if [ "$(id -u)" -eq 0 ]; then ldconfig; fi

PC=$(dirname "$(find "$PREFIX" -name libdpdk.pc -print -quit)")
cat <<MSG

DPDK $TAG installed in $PREFIX
Copy common/env.sh.example to common/env.sh, or add:

  export DPDK_SRC=$SRC
  export DPDK_PREFIX=$PREFIX
  export PKG_CONFIG_PATH=$PC\${PKG_CONFIG_PATH:+:\$PKG_CONFIG_PATH}
  export PATH=$PREFIX/bin:\$PATH

Check:  pkg-config --modversion libdpdk
MSG
