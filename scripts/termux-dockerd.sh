#!/usr/bin/env bash
# Native Docker daemon on Android — Termux + root, no proot, no chroot.
#
# This is the host-side helper for the Docker-enabled kernel variant
# (output/boot-docker.img).  It does not change build.sh: it only downloads a
# static Docker toolchain, starts/stops dockerd with a persistent data root,
# and then hands ./build.sh a working DOCKER_HOST.
#
# Requirements
#   - Docker-enabled kernel flashed (configs/docker.fragment, section 13 of
#     NOTES.txt), unlocked bootloader, APatch/Magisk root with a working `su`
#   - Termux with: curl, tar, and optionally iproute2 for the doctor checks
#   - ~10 GB free on /data for images + the kernel build
#
# Usage
#   scripts/termux-dockerd.sh doctor          check kernel/runtime prerequisites
#   scripts/termux-dockerd.sh setup           download the static Docker tools
#   scripts/termux-dockerd.sh start           start dockerd (persistent data)
#   scripts/termux-dockerd.sh status          docker info
#   scripts/termux-dockerd.sh image           docker build (host network)
#   scripts/termux-dockerd.sh build <args>    run ./build.sh with DOCKER_HOST
#   scripts/termux-dockerd.sh logs            last lines of the daemon log
#   scripts/termux-dockerd.sh stop            stop the daemon
#
# Everything stateful lives outside the repository:
#   ~/.local/docker/           docker, dockerd, containerd, runc
#   ~/.local/share/docker-data images/containers (a real directory, i.e. a
#                              persistent "volume"; deleting it is the only
#                              way to lose the daemon state)
#
# Notes
#   - storage driver defaults to vfs because Android's /data/data SELinux
#     labels usually block overlay2 upperdirs.  Set DOCKER_STORAGE=overlay2 to
#     try it anyway.
#   - if no iptables binary is found the daemon runs with NAT disabled, so
#     containers have no outbound network unless started with --network host.
#     The image build therefore always uses host networking.
#   - dockerd runs as root; the unix socket is chmod 666 so the Termux user
#     (and build.sh) can talk to it.
set -euo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DOCKER_VERSION="${DOCKER_VERSION:-27.3.1}"
TOOLS_DIR="${TOOLS_DIR:-$HOME/.local/docker}"
DATA_ROOT="${DOCKER_DATA_ROOT:-$HOME/.local/share/docker-data}"
EXEC_ROOT="${DOCKER_EXEC_ROOT:-$PREFIX/var/run/docker-exec}"
SOCK="${DOCKER_SOCK:-$PREFIX/var/run/docker.sock}"
PIDFILE="${DOCKER_PIDFILE:-$PREFIX/var/run/dockerd.pid}"
LOG="${DOCKER_LOG:-$HOME/.local/share/dockerd.log}"
STORAGE="${DOCKER_STORAGE:-vfs}"
IMAGE_NAME="${IMAGE:-earth-kernel-abuild:latest}"

export DOCKER_HOST="unix://$SOCK"
[[ -d "$TOOLS_DIR" ]] && export PATH="$TOOLS_DIR:$PATH"
export PATH="$PREFIX/bin:$PATH"

say() { printf '\033[1;32m[termux-docker]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[termux-docker]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[termux-docker]\033[0m %s\n' "$*" >&2; exit 1; }

q() { printf '%q' "$1"; }
as_root() { su -c "$1"; }

have_su() { command -v su >/dev/null 2>&1; }
dockerd_bin() {
	if [[ -x "$TOOLS_DIR/dockerd" ]]; then echo "$TOOLS_DIR/dockerd"
	elif command -v dockerd >/dev/null 2>&1; then command -v dockerd
	else return 1; fi
}

need_tools() {
	dockerd_bin >/dev/null || die "dockerd not found: run 'scripts/termux-dockerd.sh setup' first"
	command -v docker >/dev/null || die "docker client not found: run 'scripts/termux-dockerd.sh setup' first"
}

# ---------------------------------------------------------------------------
# doctor
# ---------------------------------------------------------------------------
check_kernel_config() {
	local cfg="$1" sym missing=0
	for sym in NAMESPACES NET_NS PID_NS IPC_NS UTS_NS CGROUPS MEMCG \
	           CGROUP_DEVICE OVERLAY_FS VETH BRIDGE NETFILTER IP_NF_NAT \
	           POSIX_MQUEUE SECCOMP_FILTER; do
		if grep -qx "CONFIG_${sym}=y" <<<"$cfg"; then
			printf '  ok      CONFIG_%s\n' "$sym"
		else
			printf '  MISSING CONFIG_%s (docker.fragment)\n' "$sym"
			missing=$((missing + 1))
		fi
	done
	return "$missing"
}

doctor() {
	say "host: $(uname -m), kernel $(uname -r)"
	say "termux prefix: $PREFIX"

	local cfg=""
	if [[ -r /proc/config.gz ]]; then
		cfg="$(zcat /proc/config.gz 2>/dev/null || true)"
	fi
	if [[ -z "$cfg" ]] && have_su; then
		cfg="$(as_root 'zcat /proc/config.gz' 2>/dev/null || true)"
	fi

	if [[ -n "$cfg" ]]; then
		say "kernel config from /proc/config.gz"
		check_kernel_config "$cfg" || warn "the running kernel is not the Docker variant; flash output/boot-docker.img"
	else
		warn "no /proc/config.gz, checking runtime features instead"
		for ns in net pid ipc uts user; do
			[[ -e "/proc/self/ns/$ns" ]] && echo "  ok      $ns namespace" \
				|| echo "  MISSING $ns namespace"
		done
		if [[ -r /proc/cgroups ]]; then
			echo "  cgroups:"
			awk 'NR > 1 { printf "    %-12s %s\n", $1, ($4 == 1 ? "enabled" : "disabled") }' /proc/cgroups
		fi
		grep -qw overlay /proc/filesystems \
			&& echo "  ok      overlay filesystem" \
			|| echo "  MISSING overlay filesystem"
	fi

	if command -v ip >/dev/null 2>&1 && have_su; then
		if as_root 'ip link add td-veth0 type veth peer name td-veth1 && ip link del td-veth0' >/dev/null 2>&1; then
			echo "  ok      veth pairs can be created"
		else
			echo "  MISSING veth creation failed (CONFIG_VETH)"
		fi
		if as_root 'ip link add td-br0 type bridge && ip link del td-br0' >/dev/null 2>&1; then
			echo "  ok      bridge devices can be created"
		else
			echo "  MISSING bridge creation failed (CONFIG_BRIDGE)"
		fi
	fi

	have_su || warn "no 'su' in PATH: install root (APatch) and a su wrapper"
	[[ -e "$SOCK" ]] && say "daemon socket present: $SOCK" || say "daemon not started yet"
}

# ---------------------------------------------------------------------------
# setup: static Docker toolchain (aarch64)
# ---------------------------------------------------------------------------
setup() {
	if [[ -x "$TOOLS_DIR/dockerd" ]]; then
		say "already installed: $("$TOOLS_DIR/dockerd" --version)"
		return 0
	fi
	[[ "$(uname -m)" == "aarch64" ]] || die "static Docker is downloaded for aarch64 here, found $(uname -m)"
	command -v curl >/dev/null || die "curl missing: pkg install curl"
	command -v tar >/dev/null || die "tar missing: pkg install tar"

	local url="https://download.docker.com/linux/static/stable/aarch64/docker-${DOCKER_VERSION}.tgz"
	local tmp
	tmp="$(mktemp -d)"

	say "downloading $url"
	if ! curl -fL --retry 3 --retry-delay 5 -o "$tmp/docker.tgz" "$url"; then
		rm -rf "$tmp"
		die "download failed: $url"
	fi
	say "extracting to $TOOLS_DIR"
	mkdir -p "$TOOLS_DIR"
	if ! tar -xzf "$tmp/docker.tgz" -C "$TOOLS_DIR" --strip-components=1; then
		rm -rf "$tmp"
		die "cannot extract $tmp/docker.tgz"
	fi
	rm -rf "$tmp"
	chmod 755 "$TOOLS_DIR"/* 2>/dev/null || true
	"$TOOLS_DIR/dockerd" --version >/dev/null || die "downloaded dockerd does not run on this device"
	say "installed: $("$TOOLS_DIR/dockerd" --version)"
	say "next: scripts/termux-dockerd.sh start"
}

# ---------------------------------------------------------------------------
# start / stop / status
# ---------------------------------------------------------------------------
start() {
	need_tools
	have_su || die "su not found: this needs root"

	if [[ -S "$SOCK" ]] && docker info >/dev/null 2>&1; then
		say "dockerd already running ($SOCK)"
		return 0
	fi

	local dockerd ipt=0
	dockerd="$(dockerd_bin)"
	mkdir -p "$DATA_ROOT" "$(dirname "$LOG")"
	as_root "mkdir -p $(q "$EXEC_ROOT") $(q "$DATA_ROOT")"

	if as_root 'command -v iptables >/dev/null 2>&1'; then
		ipt=1
	fi
	say "iptables available: $ipt"

	local flags=(
		--host "unix://$SOCK"
		--data-root "$DATA_ROOT"
		--exec-root "$EXEC_ROOT"
		--pidfile "$PIDFILE"
		--storage-driver "$STORAGE"
		--log-level info
		--dns 1.1.1.1
		--dns 8.8.8.8
	)
	if [[ "$ipt" == 1 ]]; then
		flags+=(--iptables=true --ip6tables=true --ip-forward=true --ip-masq=true)
	else
		flags+=(--iptables=false --ip6tables=false --ip-forward=false --ip-masq=false)
		warn "iptables not found: NAT is disabled, use --network host for outward traffic"
	fi

	local cmd="PATH=$(q "$TOOLS_DIR:$PREFIX/bin:/system/bin") HOME=/ nohup $(q "$dockerd")"
	local f
	for f in "${flags[@]}"; do cmd+=" $(q "$f")"; done
	cmd+=" >>$(q "$LOG") 2>&1 &"

	say "starting dockerd (storage: $STORAGE, data: $DATA_ROOT)"
	as_root "$cmd"

	local i
	for i in $(seq 1 60); do
		[[ -S "$SOCK" ]] && break
		sleep 1
	done
	[[ -S "$SOCK" ]] || { warn "socket did not appear, see $LOG:"; tail -n 20 "$LOG" >&2 || true; exit 1; }

	# dockerd runs as root; let the Termux user talk to the socket
	as_root "chmod 666 $(q "$SOCK")" || true

	for i in $(seq 1 20); do
		docker info >/dev/null 2>&1 && break
		sleep 1
	done
	docker info >/dev/null 2>&1 || { warn "docker info failed, see $LOG"; tail -n 20 "$LOG" >&2 || true; exit 1; }
	say "dockerd is up: $SOCK"
	say "for manual commands: export DOCKER_HOST=unix://$SOCK"
}

stop() {
	[[ -f "$PIDFILE" ]] || { say "no pidfile, dockerd not running"; return 0; }
	have_su || die "su not found"
	local pid
	pid="$(as_root "cat $(q "$PIDFILE")" | tr -d '[:space:]')"
	[[ -n "$pid" ]] || { warn "empty pidfile"; return 1; }
	say "stopping dockerd (pid $pid)"
	as_root "kill $(q "$pid")" || true
	local i
	for i in $(seq 1 30); do
		as_root "kill -0 $(q "$pid")" 2>/dev/null || break
		sleep 1
	done
	as_root "kill -0 $(q "$pid")" 2>/dev/null && as_root "kill -9 $(q "$pid")" || true
	rm -f "$PIDFILE"
	say "stopped"
}

status() {
	need_tools
	docker info 2>&1 | sed -n '1,25p' || true
	echo
	echo "socket : $SOCK"
	echo "data   : $DATA_ROOT ($(du -sh "$DATA_ROOT" 2>/dev/null | cut -f1))"
	echo "log    : $LOG"
}

# ---------------------------------------------------------------------------
# image / build
# ---------------------------------------------------------------------------
image() {
	need_tools
	[[ -S "$SOCK" ]] || die "dockerd is not running: scripts/termux-dockerd.sh start"
	say "docker build (host network): $IMAGE_NAME"
	# Host networking so apt inside the image works even with NAT disabled.
	docker build --network host -t "$IMAGE_NAME" "$ROOT"
}

build() {
	[[ $# -gt 0 ]] || die "usage: scripts/termux-dockerd.sh build <build.sh args>"
	[[ -S "$SOCK" ]] || die "dockerd is not running: scripts/termux-dockerd.sh start"
	exec "$ROOT/build.sh" "$@"
}

logs() { tail -n "${1:-80}" "$LOG" 2>/dev/null || warn "no log at $LOG"; }

usage() {
	sed -n '3,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

case "${1:-help}" in
	doctor) doctor ;;
	setup) setup ;;
	start) start ;;
	stop) stop ;;
	status) status ;;
	image) image ;;
	build) shift; build "$@" ;;
	logs) shift || true; logs "${1:-80}" ;;
	help|-h|--help) usage ;;
	*) usage; exit 1 ;;
esac
