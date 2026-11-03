#!/usr/bin/env bash
# register-arm-emulation.sh — let this machine's Docker run 32-bit ARM
# containers (--platform linux/arm/v7), for builds that compile on ARM.
#
# Usage (from WSL): tools/register-arm-emulation.sh
#
# Registers qemu's ARM user-mode emulator with the WSL kernel's binfmt_misc,
# from Debian's signed qemu-user-static package and its own registration line
# (/usr/lib/binfmt.d/qemu-arm.conf). The "F" flag makes the kernel open the
# emulator once, at registration, so it serves every later container.
#
# This needs one --privileged container, and the registration lasts until WSL
# restarts. It registers 32-bit ARM only and leaves every other handler
# (WSLInterop and the rest) alone.

set -euo pipefail

test_image=alpine:3.24

arm_containers_run() {
    docker run --rm --platform linux/arm/v7 "$test_image" true > /dev/null 2>&1
}

if arm_containers_run; then
    echo "register-arm-emulation.sh: ARM containers already run; nothing to do"
    exit 0
fi

docker run --rm --privileged debian:bookworm-slim sh -euc '
    apt-get update -qq
    apt-get install -qq -y --no-install-recommends qemu-user-static > /dev/null
    binfmt=/proc/sys/fs/binfmt_misc
    [ -f "$binfmt/register" ] || mount -t binfmt_misc binfmt_misc "$binfmt"
    if [ -e "$binfmt/qemu-arm" ]; then
        echo "a qemu-arm handler is already registered but ARM containers fail:" >&2
        cat "$binfmt/qemu-arm" >&2
        exit 1
    fi
    cat /usr/lib/binfmt.d/qemu-arm.conf > "$binfmt/register"
    echo "registered: $(head -n 1 "$binfmt/qemu-arm") ($(sed -n "s/^interpreter //p" "$binfmt/qemu-arm"))"
'

arm_containers_run || { echo "register-arm-emulation.sh: ARM containers still don't run" >&2; exit 1; }
echo "register-arm-emulation.sh: $(docker run --rm --platform linux/arm/v7 "$test_image" uname -m) containers run"
