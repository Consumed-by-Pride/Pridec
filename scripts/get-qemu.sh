#!/bin/bash
# Install qemu-system-i386/x86_64 under ~/.local/qemu WITHOUT root (Debian/Ubuntu): download the .debs with a private apt state dir and unpack them.
# tests/air3/boot.sh finds the result. Idempotent.
set -eu
D="$HOME/.local/qemu"
[ -x "$D/usr/bin/qemu-system-i386" ] && { echo "qemu already in $D"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/state/lists/partial" "$T/cache/archives/partial" "$D"
O="-o Dir::State=$T/state -o Dir::Cache=$T/cache -o Dir::State::status=/var/lib/dpkg/status -o Debug::NoLocking=1"
apt-get $O update >/dev/null 2>&1 || true
pkgs=$(apt-get $O install -s qemu-system-x86 --no-install-recommends 2>/dev/null | awk '/^Inst /{print $2}')
[ -n "$pkgs" ] || { echo "get-qemu: apt cannot resolve qemu-system-x86" >&2; exit 1; }
( cd "$T" && apt-get $O download $pkgs >/dev/null )
for d in "$T"/*.deb; do dpkg -x "$d" "$D"; done
echo "qemu installed in $D (LD_LIBRARY_PATH=$D/usr/lib/x86_64-linux-gnu is set by tests/air3/boot.sh)"
