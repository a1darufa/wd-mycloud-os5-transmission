Licenses of the software in this package
========================================

What's in the package, and under which license:

  bin/transmission-daemon   Transmission, statically linked with the
                            libraries listed below. GPL-3.0 (see "Source").
  share/transmission/       Transmission's web interface. GPL, as Transmission.
  bin/su-exec               su-exec. MIT.
  *.sh, web/                The app's own scripts and dashboard page. MIT.

The license texts, in this folder:

  app/LICENSE               the app's scripts and page
  transmission/             Transmission's COPYING and the license texts it
                            refers to (gpl-2.0.txt, gpl-3.0.txt, mit.txt,
                            bsd-3-clause.txt)
  transmission/third-party/ the libraries bundled in Transmission's source
                            and compiled into the daemon: dht, fast_float, fmt,
                            libb64, libdeflate, libevent, libnatpmp, libutp,
                            crcany, miniupnpc, RapidJSON, small, utfcpp,
                            wide-integer (wildmat is public domain)
  su-exec/LICENSE           su-exec
  libraries/                the libraries linked in from Alpine Linux v3.24:

    Library          Version  License                     File in libraries/
    musl             1.2.6    MIT                         musl-COPYRIGHT
    OpenSSL          3.5.9    Apache-2.0                  openssl-LICENSE.txt
    curl             8.23.0   curl (MIT-style)            curl-COPYING
    nghttp2          1.70.0   MIT                         nghttp2-COPYING
    brotli           1.2.1    MIT                         brotli-LICENSE
    zstd             1.5.7    BSD-3-Clause                zstd-LICENSE
    zlib             1.3.2    Zlib                        zlib-LICENSE
    c-ares           1.34.9   MIT                         c-ares-LICENSE.md
    libidn2          2.3.8    LGPL-3.0-or-later; its      LGPL-3.0.txt,
                              Unicode data: Unicode       libidn2-COPYING.unicode
    libunistring     1.4.2    LGPL-3.0-or-later           LGPL-3.0.txt
    libpsl           0.21.5   MIT; its built-in public    libpsl-COPYING,
                              suffix list: MPL-2.0        transmission/third-party/
                                                          libpsl/list/LICENSE
    libstdc++, libgcc  15.2.0  GPL-3.0 with the GCC       GCC-RUNTIME-EXCEPTION-3.1.txt,
                               Runtime Library Exception  transmission/gpl-3.0.txt

  The versions are those of the build that produced this package; the exact
  Alpine package set is in transmission4/packages.lock of the build scripts.

Source
------

Transmission may be used under GPL-2.0 or GPL-3.0. OpenSSL 3 is under
Apache-2.0, which is compatible with GPL-3.0 only, so transmission-daemon as
built here is distributed under GPL-3.0. Its complete corresponding source:

  - Transmission's official release tarball, unmodified, and su-exec's
    release tarball: their URLs and checksums are in
    transmission4/upstream.env of the build scripts;
  - the Alpine Linux v3.24 packages listed in transmission4/packages.lock,
    whose sources are in Alpine's aports repository
    (https://gitlab.alpinelinux.org/alpine/aports, branch 3.24-stable);
  - the build scripts themselves, published in the same repository as this
    package's release.

With those, the binaries can be rebuilt, including against modified versions
of the LGPL libraries (libidn2, libunistring).

This app is not made, endorsed or supported by the Transmission project or by
Western Digital.
