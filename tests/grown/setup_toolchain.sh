#!/usr/bin/env bash
# tests/grown/setup_toolchain.sh -- restore the c3c toolchains after a sandbox reset.
#
# The compiler binaries live OUTSIDE the persisted workspace (~/.cache, ~/c3lib),
# so every sandbox reset loses them. The master copy of the 0.8.6 toolchain is
# kept in the workspace at google_drive/c3-linux-static.tar.gz (synced from the
# user's Google Drive, "c3-linux-static.tar.gz", 49 MB).
#
#   0.8.6: ~/.cache/c3tool/c3c086   (stdlib: ~/c3lib086)  -- from Drive
#   0.6.2: ~/.cache/c3tool/c3c      (stdlib: ~/c3lib)     -- from npm (re-download)
#
# Usage: bash tests/grown/setup_toolchain.sh
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)

if [ ! -x "$HOME/.cache/c3tool/c3c086" ]; then
    mkdir -p "$HOME/.cache/c3tool"
    rm -rf /tmp/c3drv "$HOME/.cache/c3tool/c3-086"
    mkdir -p /tmp/c3drv
    tar xzf "$ROOT/google_drive/c3-linux-static.tar.gz" -C /tmp/c3drv
    cp -r /tmp/c3drv/c3 "$HOME/.cache/c3tool/c3-086"
    chmod +x "$HOME/.cache/c3tool/c3-086/c3c"
    ln -sf "$HOME/.cache/c3tool/c3-086/c3c" "$HOME/.cache/c3tool/c3c086"
    rm -rf "$HOME/c3lib086"
    cp -r /tmp/c3drv/c3/lib/std "$HOME/c3lib086"
    echo "restored c3c 0.8.6 from workspace tarball"
fi

if [ ! -x "$HOME/.cache/c3tool/c3c" ]; then
    mkdir -p "$HOME/.cache/c3tool"
    curl -sL -o /tmp/c3c062.tgz https://registry.npmjs.org/@c3-lang/c3c-linux-x64/-/c3c-linux-x64-0.6.2.tgz
    rm -rf /tmp/c3c062 && mkdir -p /tmp/c3c062
    tar xzf /tmp/c3c062.tgz -C /tmp/c3c062
    cp /tmp/c3c062/package/c3c "$HOME/.cache/c3tool/c3c"
    chmod +x "$HOME/.cache/c3tool/c3c"
    rm -rf "$HOME/c3lib"
    cp -r /tmp/c3c062/package/lib/std "$HOME/c3lib"
    echo "restored c3c 0.6.2 from npm"
fi

"$HOME/.cache/c3tool/c3c086" --version | head -1
"$HOME/.cache/c3tool/c3c" --version | head -1
