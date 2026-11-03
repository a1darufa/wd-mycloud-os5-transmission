#!/usr/bin/env bash
# build.sh — build the Transmission 4 app .bin.
#
# Usage (from WSL, repo root):
#   transmission4/build.sh                real package, compiled from the pinned sources
#   transmission4/build.sh --update-lock  the same, after rebuilding the ARM build image
#                                         from scratch and rewriting packages.lock (review the diff!)
#   transmission4/build.sh --stub         test package whose binaries are the stubs in tests/stubs
#
# The real build compiles on ARM under emulation (run
# tools/register-arm-emulation.sh once after WSL starts) and takes a while.
# It assembles build/transmission4-<variant>/transmission4 from
# transmission4/package plus the payload (bin/, share/), then packages it with
# the repo's build.sh. Output lands in dist/.

set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=transmission4/upstream.env
source "$repo_dir/transmission4/upstream.env"

image=wd-transmission-builder
lock_file=$repo_dir/transmission4/packages.lock

# The package ships a neutral icon (transmission4/icon.svg). A private icon
# in reference/, which never enters git history, replaces it when present:
# WD's Transmission app icon (Transmission's classic logo), pinned by SHA256.
private_icon=$repo_dir/reference/wd-transmission/web_config/Transmission.png
private_icon_sha256=2bd51f37be64771f6e7ee5b96050a9b80534a3563f83d6c68e4954d0456577e0

fail() {
    echo "transmission4/build.sh: $*" >&2
    exit 1
}

mode=${1:-}
case $mode in
    "" | --update-lock | --stub) ;;
    *) fail "unknown option '$mode'" ;;
esac

package_version=$(awk '$1 == "Version:" { print $2 }' "$repo_dir/transmission4/package/apkg.rc")
[[ $package_version == "$TRANSMISSION_VERSION"-* ]] \
    || fail "apkg.rc Version '$package_version' must be '$TRANSMISSION_VERSION-<revision>' (from upstream.env)"

builder() {
    docker run --rm --platform linux/arm/v7 "$@"
}

# The image is cached after its first build. --update-lock rebuilds it from
# the newest packages, which is how Alpine's security updates get in.
prepare_builder() {
    builder alpine:3.24 true > /dev/null 2>&1 \
        || fail "ARM containers don't run; run tools/register-arm-emulation.sh (needed once after WSL starts)"
    if [[ $mode == --update-lock ]]; then
        docker build --quiet --pull --no-cache --platform linux/arm/v7 --tag "$image" "$repo_dir/docker/alpine" > /dev/null
    else
        docker build --quiet --platform linux/arm/v7 --tag "$image" "$repo_dir/docker/alpine" > /dev/null
    fi
}

# The exact package set of the build image, static libraries included.
check_lock() {
    local installed
    installed=$(builder "$image" apk info -v | sort)
    if [[ $mode == --update-lock ]]; then
        {
            echo "# Exact Alpine package set of the ARM build image (docker/alpine). Its static"
            echo "# libraries (musl, OpenSSL, curl, ...) are linked into the binaries."
            echo "# Written by transmission4/build.sh --update-lock; review changes before committing."
            echo "$installed"
        } > "$lock_file"
        echo "build.sh: wrote $lock_file ($(echo "$installed" | wc -l) packages)"
    elif ! diff <(grep -v '^#' "$lock_file") <(echo "$installed") > /dev/null; then
        echo "transmission4/build.sh: the build image differs from packages.lock:" >&2
        diff <(grep -v '^#' "$lock_file") <(echo "$installed") >&2 || true
        fail "review the change, then run: transmission4/build.sh --update-lock"
    fi
}

apply_private_icon() {
    [[ -f $private_icon ]] || return 0
    if [[ $(sha256sum < "$private_icon" | cut -d' ' -f1) != "$private_icon_sha256" ]]; then
        echo "transmission4/build.sh: $private_icon changed; keeping the neutral icon" >&2
        return 0
    fi
    cp "$private_icon" "$app_dir/transmission4.png"
    cp "$private_icon" "$app_dir/web/transmission4.png"
}

variant=release
[[ $mode == --stub ]] && variant=stub
assembly_dir=$repo_dir/build/transmission4-$variant
app_dir=$assembly_dir/transmission4

rm -rf "$assembly_dir"
mkdir -p "$assembly_dir"
cp -r "$repo_dir/transmission4/package" "$app_dir"
# The settings page's shared files (common/web) go next to the app's own.
cp "$repo_dir"/common/web/* "$app_dir/web/"

if [[ $mode == --stub ]]; then
    mkdir -p "$app_dir/bin"
    cp "$repo_dir/tests/stubs/transmission-daemon" "$repo_dir/tests/stubs/su-exec" "$app_dir/bin/"
    # A distinct version and name, so a stub build is never mistaken for the
    # real app in dist/ or in the dashboard.
    sed -i \
        -e "s/^Version:.*/Version:\t$package_version-stub/" \
        -e "s/^AddonShowName:.*/AddonShowName:\tTransmission 4 (TEST STUB)/" \
        "$app_dir/apkg.rc"
else
    prepare_builder
    check_lock
    "$repo_dir/transmission4/fetch.sh"
    builder --network none --volume "$repo_dir:/work" "$image" \
        bash /work/transmission4/assemble-payload.sh "/work/build/transmission4-$variant/transmission4"
fi

apply_private_icon
mkdir -p "$app_dir/licenses/app"
cp "$repo_dir/LICENSE" "$app_dir/licenses/app/"
"$repo_dir/build.sh" "${app_dir#"$repo_dir"/}"
