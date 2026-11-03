# ARM build environment for the Transmission payload: Alpine's armv7 compiler
# and the static libraries linked into the binaries, all signed Alpine
# packages. Built and run with --platform linux/arm/v7 under qemu emulation
# (tools/register-arm-emulation.sh); transmission4/build.sh checks the
# installed package set against transmission4/packages.lock.
FROM alpine:3.24

# Compiler and build tools; curl's static library with every library it
# needs; bash, the curl CLI and xz for the build script and its smoke test.
RUN apk add --no-cache \
        build-base cmake samurai linux-headers pkgconf \
        curl-dev curl-static openssl-dev openssl-libs-static zlib-dev zlib-static \
        c-ares-dev nghttp2-static brotli-static zstd-static \
        libidn2-static libunistring-static libpsl-dev libpsl-static \
        bash curl xz

WORKDIR /work
