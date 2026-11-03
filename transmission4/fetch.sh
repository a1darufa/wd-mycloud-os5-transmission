#!/usr/bin/env bash
# fetch.sh — download the pinned Transmission and su-exec sources.
#
# Usage (from WSL, repo root): transmission4/fetch.sh
#
# Output: downloads/sources/<tarball>. Each file must match every checksum
# pinned in transmission4/upstream.env; a file that already matches is reused,
# and one that doesn't is never kept.

set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=transmission4/upstream.env
source "$repo_dir/transmission4/upstream.env"

sources_dir=$repo_dir/downloads/sources

fail() {
    echo "fetch.sh: $*" >&2
    exit 1
}

# matches <file> <sha256 or ""> <sha512>
matches() {
    [[ -f $1 ]] || return 1
    [[ -z $2 || $(sha256sum < "$1" | cut -d' ' -f1) == "$2" ]] || return 1
    [[ $(sha512sum < "$1" | cut -d' ' -f1) == "$3" ]]
}

# fetch <file name> <url> <sha256 or ""> <sha512>
fetch() {
    local target=$sources_dir/$1 partial=$sources_dir/$1.partial
    if matches "$target" "$3" "$4"; then
        echo "fetch.sh: $1 (cached, checksums match)"
        return
    fi
    rm -f "$target" "$partial"
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --output "$partial" "$2"
    if ! matches "$partial" "$3" "$4"; then
        rm -f "$partial"
        fail "$1 from $2 doesn't match the checksums in upstream.env"
    fi
    mv "$partial" "$target"
    echo "fetch.sh: $1 (downloaded, checksums match)"
}

mkdir -p "$sources_dir"
fetch "transmission-$TRANSMISSION_VERSION.tar.xz" "$TRANSMISSION_URL" "$TRANSMISSION_SHA256" "$TRANSMISSION_SHA512"
fetch "su-exec-$SU_EXEC_VERSION.tar.gz" "$SU_EXEC_URL" "" "$SU_EXEC_SHA512"
