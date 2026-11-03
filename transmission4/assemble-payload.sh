#!/usr/bin/env bash
# assemble-payload.sh <output folder> [--su-exec-only] — runs inside the
# wd-transmission-builder image (Alpine armv7 under emulation), with no network.
#
# 1. Compiles su-exec and transmission-daemon from the pinned sources in
#    downloads/sources (checked by fetch.sh) into static PIE binaries linked
#    for 64 KB pages: one self-contained file each, with no loader or shared
#    libraries, that the NAS's 32 KB-page kernel can load (README.md).
# 2. Checks each binary: static, and every segment 64 KB-aligned.
# 3. Smoke-tests them: version, su-exec, a real RPC session-get, the web UI.
# 4. Writes bin/, share/transmission/public_html and the license texts from
#    the same tarballs (licenses/transmission, licenses/su-exec) into
#    <output folder>.
#
# --su-exec-only builds and checks just su-exec, for a first test on the NAS.

set -euo pipefail

# shellcheck source=transmission4/upstream.env
source /work/transmission4/upstream.env

out_dir=${1:?usage: assemble-payload.sh <output folder> [--su-exec-only]}
only_su_exec=${2:-}
sources=/work/downloads/sources
work=$(mktemp -d)
payload=$work/payload

# Static PIE keeps address randomisation without a loader. The page-size
# flags align every segment to 64 KB, like WD's own binaries; relro/now make
# the relocated data read-only before main().
compile_flags="-O2 -fstack-clash-protection -D_FORTIFY_SOURCE=2"
link_flags="-static-pie -Wl,-z,max-page-size=0x10000 -Wl,-z,common-page-size=0x10000 -Wl,-z,relro,-z,now"

fail() {
    echo "assemble-payload.sh: $*" >&2
    exit 1
}

# Show the tail of a step's log and fail.
fail_with_log() {
    tail -n 60 "$2" >&2
    fail "$1 failed (full log: $2)"
}

build_su_exec() {
    tar -xzf "$sources/su-exec-$SU_EXEC_VERSION.tar.gz" -C "$work"
    # shellcheck disable=SC2086  # the flag strings are word lists
    gcc $compile_flags -Wall -o "$payload/bin/su-exec" \
        "$work/su-exec-$SU_EXEC_VERSION/su-exec.c" $link_flags
}

# Transmission's own bundled copies of libevent, libdeflate, dht, libutp,
# miniupnpc, libnatpmp and libb64 (the versions upstream tests with); curl,
# OpenSSL and libpsl from Alpine's static libraries. libpsl must be the
# system one because static curl links it too.
build_transmission() {
    local source_dir=$work/transmission-$TRANSMISSION_VERSION cmake_dir=$work/cmake curl_libs
    tar -xJf "$sources/transmission-$TRANSMISSION_VERSION.tar.xz" -C "$work"
    # A static libcurl needs its own dependencies at the end of the link line.
    curl_libs=$(pkg-config --static --libs libcurl)

    cmake -S "$source_dir" -B "$cmake_dir" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DCMAKE_PROJECT_INCLUDE=/work/transmission4/static-link.cmake \
        -DCMAKE_C_FLAGS="$compile_flags" \
        -DCMAKE_CXX_FLAGS="$compile_flags" \
        -DCMAKE_EXE_LINKER_FLAGS="$link_flags" \
        -DCMAKE_C_STANDARD_LIBRARIES="$curl_libs" \
        -DCMAKE_CXX_STANDARD_LIBRARIES="$curl_libs" \
        -DOPENSSL_USE_STATIC_LIBS=ON \
        -DBUILD_SHARED_LIBS=OFF \
        -DENABLE_DAEMON=ON -DENABLE_GTK=OFF -DENABLE_QT=OFF -DENABLE_MAC=OFF \
        -DENABLE_UTILS=OFF -DENABLE_CLI=OFF -DENABLE_TESTS=OFF -DENABLE_NLS=OFF \
        -DINSTALL_WEB=ON -DINSTALL_DOC=OFF -DREBUILD_WEB=OFF -DRUN_CLANG_TIDY=OFF \
        -DWITH_CRYPTO=openssl -DWITH_SYSTEMD=OFF -DWITH_INOTIFY=ON \
        -DUSE_SYSTEM_EVENT2=OFF -DUSE_SYSTEM_DEFLATE=OFF -DUSE_SYSTEM_DHT=OFF \
        -DUSE_SYSTEM_MINIUPNPC=OFF -DUSE_SYSTEM_NATPMP=OFF -DUSE_SYSTEM_UTP=OFF \
        -DUSE_SYSTEM_B64=OFF -DUSE_SYSTEM_PSL=ON \
        > "$work/configure.log" 2>&1 || fail_with_log "cmake configure" "$work/configure.log"
    cmake --build "$cmake_dir" --parallel "$(nproc)" > "$work/build.log" 2>&1 \
        || fail_with_log "compiling Transmission" "$work/build.log"
    DESTDIR=$work/install cmake --install "$cmake_dir" > /dev/null

    cp "$work/install/usr/bin/transmission-daemon" "$payload/bin/"
    mkdir -p "$payload/share/transmission"
    cp -r "$work/install/usr/share/transmission/public_html" "$payload/share/transmission/"
}

# The license files of Transmission's bundled libraries that end up in the
# daemon, relative to third-party/. Listed one by one rather than found, so a
# new Transmission version that moves or drops one fails the build and gets
# a look. wildmat is public domain and has no license file.
third_party_licenses=(
    dht/LICENCE
    fast_float/LICENSE-MIT
    fmt/LICENSE
    libb64/LICENSE.md
    libdeflate/COPYING
    libevent/LICENSE
    libnatpmp/LICENSE
    libpsl/list/LICENSE # the public suffix list, also built into Alpine's libpsl
    libutp/LICENSE
    madler-crcany/LICENSE
    miniupnp/miniupnpc/LICENSE
    rapidjson/license.txt
    small/LICENSE
    utfcpp/LICENSE
    wide-integer/LICENSE_1_0.txt
)

# License texts from the same tarballs as the binaries. The package's
# licenses/README.txt explains these and the committed ones next to them.
collect_licenses() {
    local source_dir=$work/transmission-$TRANSMISSION_VERSION dest=$payload/licenses/transmission file
    mkdir -p "$payload/licenses/su-exec"
    cp "$work/su-exec-$SU_EXEC_VERSION/LICENSE" "$payload/licenses/su-exec/"
    [[ $only_su_exec == --su-exec-only ]] && return 0

    mkdir -p "$dest"
    cp "$source_dir/COPYING" "$source_dir"/licenses/*.txt "$dest/"
    for file in "${third_party_licenses[@]}"; do
        mkdir -p "$dest/third-party/$(dirname "$file")"
        cp "$source_dir/third-party/$file" "$dest/third-party/$file"
    done
}

# No program interpreter and no shared libraries: nothing outside the file.
check_static() {
    readelf -lW "$1" | grep -q 'Requesting program interpreter' && fail "$(basename "$1") asks for a loader"
    readelf -dW "$1" | grep -q '(NEEDED)' && fail "$(basename "$1") needs shared libraries"
    return 0
}

check_binaries() {
    local file
    strip --strip-all "$payload"/bin/*
    for file in "$payload"/bin/*; do
        check_static "$file"
    done
    sh /work/tools/check-elf-alignment.sh "$payload"/bin/*
}

smoke_test_su_exec() {
    [[ $("$payload/bin/su-exec" nobody:nobody id -u) == 65534 ]] || fail "su-exec didn't switch user"
    echo "smoke test: su-exec nobody:nobody -> uid 65534"
}

smoke_test_daemon() {
    local daemon=$payload/bin/transmission-daemon config downloads pid session reply
    "$daemon" --version 2>&1 | grep -qF "$TRANSMISSION_VERSION " \
        || fail "transmission-daemon --version doesn't report $TRANSMISSION_VERSION"

    config=$(mktemp -d)
    downloads=$(mktemp -d)
    TRANSMISSION_WEB_HOME=$payload/share/transmission/public_html \
        "$daemon" --foreground --config-dir "$config" --download-dir "$downloads" \
        --rpc-bind-address 127.0.0.1 --allowed 127.0.0.1 --no-portmap > "$config/daemon.log" 2>&1 &
    pid=$!

    # Until the daemon listens, curl fails; that's expected while polling.
    session=""
    for _ in $(seq 120); do
        session=$(curl -s -o /dev/null -D - http://127.0.0.1:9091/transmission/rpc \
            | sed -n 's/^X-Transmission-Session-Id: *\([^[:space:]]*\).*/\1/ip') || true
        [[ -n $session ]] && break
        sleep 1
    done
    [[ -n $session ]] || { cat "$config/daemon.log" >&2; fail "RPC did not come up"; }

    reply=$(curl -s -H "X-Transmission-Session-Id: $session" http://127.0.0.1:9091/transmission/rpc \
        -d '{"method":"session-get","arguments":{"fields":["version","rpc-version","rpc-version-semver","rpc-version-minimum"]}}')
    echo "smoke test: session-get -> $reply"
    curl -s http://127.0.0.1:9091/transmission/web/ | grep -qi "transmission" || fail "web UI not served"
    echo "smoke test: web UI served from share/transmission/public_html"

    kill "$pid"
    wait "$pid" 2> /dev/null || true
}

mkdir -p "$payload/bin"
build_su_exec
if [[ $only_su_exec != --su-exec-only ]]; then
    build_transmission
fi
collect_licenses
check_binaries
smoke_test_su_exec
[[ $only_su_exec == --su-exec-only ]] || smoke_test_daemon

mkdir -p "$out_dir"
cp -r "$payload"/. "$out_dir"/
for file in "$payload"/bin/*; do
    echo "built: bin/$(basename "$file") ($(stat -c %s "$file") bytes, $(file -b "$file" | cut -d, -f1-2))"
done
