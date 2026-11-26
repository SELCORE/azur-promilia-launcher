#!/bin/bash
# Builds the launcher's own Wine runtime from CodeWeavers' published CrossOver source,
# adds DXMT from its upstream release, bundles the libraries Wine loads at run time,
# and packs everything into one relocatable tarball.
#
# Runs on an Apple Silicon Mac (GitHub's macOS runners or your own Mac):
#   - Wine is built for x86_64 (it runs under Rosetta 2), with WoW64 so 32-bit Windows
#     programs (for example Nexon's NGService.exe) work too.
#   - Build tools (bison, mingw-w64) come from the native Homebrew in /opt/homebrew.
#   - Libraries Wine loads at run time (FreeType, GnuTLS and what GnuTLS needs) must be x86_64.
#     Homebrew no longer installs x86_64 packages on Apple Silicon, so `deps` builds them from
#     their official source releases into $WORK/x86.
#
# Usage: runtime/build-runtime.sh deps|fetch|configure|build|bundle|package|all
# Env:   CX_VER (default 26.3.0), DXMT_VER (default v0.80), WORK (default ./runtime-work), JOBS
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CX_VER="${CX_VER:-26.3.0}"
DXMT_VER="${DXMT_VER:-v0.80}"
PATCH_REV="${PATCH_REV:-p3}"   # bump when runtime/patches changes
WORK="${WORK:-$PWD/runtime-work}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
SRC_URL="https://media.codeweavers.com/pub/crossover/source/crossover-sources-${CX_VER}.tar.gz"
DXMT_URL="https://github.com/3Shain/dxmt/releases/download/${DXMT_VER}/dxmt-${DXMT_VER}-builtin.tar.gz"
ARM_BREW=/opt/homebrew/bin/brew
SRC="$WORK/wine-src"
BLD="$WORK/wine-build"
DIST="$WORK/dist/wine"
X86="$WORK/x86"          # x86_64 libraries built from source
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
# configure/libtool break on paths with spaces (e.g. ~/Library/Application Support).
case "$WORK" in *" "*) die "WORK must not contain spaces: $WORK (try WORK=\$HOME/azur-runtime-build)";; esac

# Download with resume and retries; keeps a .part file until complete. Extra URLs are mirrors.
fetch_url() { # out url [mirror...]
  local out="$1" u; shift
  [ -f "$out" ] && return 0
  for u in "$@"; do
    curl -fL --retry 5 --retry-all-errors --retry-delay 3 -C - -o "$out.part" "$u" && { mv "$out.part" "$out"; return 0; }
    echo "download failed from $u, trying next" >&2
  done
  die "could not download ${out##*/}"
}

# Official source releases of the x86_64 libraries (name|url|sha256 checked after download is printed)
LIB_SOURCES="
gmp|https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz
nettle|https://ftp.gnu.org/gnu/nettle/nettle-3.10.1.tar.gz
gnutls|https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-3.8.9.tar.xz|https://mirrors.dotsrc.org/gcrypt/gnutls/v3.8/gnutls-3.8.9.tar.xz
freetype|https://download.savannah.gnu.org/releases/freetype/freetype-2.13.3.tar.xz|https://downloads.sourceforge.net/project/freetype/freetype2/2.13.3/freetype-2.13.3.tar.xz
"

x86_env() {
  export CC="clang -arch x86_64" CXX="clang++ -arch x86_64" OBJC="clang -arch x86_64"
  export CPPFLAGS="-I$X86/include" LDFLAGS="-L$X86/lib"
  export PKG_CONFIG_LIBDIR="$X86/lib/pkgconfig" PKG_CONFIG_PATH=""
}

build_lib() { # name  (configure args follow)
  local name="$1"; shift
  local urls; urls="$(printf '%s\n' "$LIB_SOURCES" | awk -F'|' -v n="$name" '$1==n{for(i=2;i<=NF;i++)print $i}')"
  local url="${urls%%$'\n'*}"
  local tarball="$WORK/dl/${url##*/}" dir="$WORK/libsrc/$name"
  [ -f "$X86/.done-$name" ] && { echo "$name: already built"; return 0; }
  mkdir -p "$WORK/dl" "$WORK/libsrc"
  # shellcheck disable=SC2086
  fetch_url "$tarball" $urls
  echo "$name source sha256: $(shasum -a 256 "$tarball" | cut -d' ' -f1)"
  rm -rf "$dir"; mkdir -p "$dir"; tar -xf "$tarball" -C "$dir" --strip-components 1
  say "Building $name (x86_64)"
  ( cd "$dir" && x86_env \
    && ./configure --prefix="$X86" --build=x86_64-apple-darwin --host=x86_64-apple-darwin \
         --enable-shared --disable-static "$@" > "$WORK/lib-$name.log" 2>&1 \
    && make -j"$JOBS" >> "$WORK/lib-$name.log" 2>&1 \
    && make install >> "$WORK/lib-$name.log" 2>&1 ) || { tail -40 "$WORK/lib-$name.log"; die "$name build failed"; }
  touch "$X86/.done-$name"
}

cmd_deps() {
  say "Build tools (native Homebrew)"
  "$ARM_BREW" install bison flex mingw-w64 pkgconf
  /usr/sbin/softwareupdate --install-rosetta --agree-to-license >/dev/null 2>&1 || true
  mkdir -p "$X86"
  build_lib gmp --disable-assembly
  build_lib nettle --disable-documentation --disable-openssl
  build_lib gnutls --with-included-libtasn1 --with-included-unistring --without-p11-kit \
    --without-idn --without-brotli --without-zstd --without-tpm --without-tpm2 --without-zlib \
    --disable-doc --disable-tools --disable-tests --disable-cxx --disable-nls --disable-guile
  build_lib freetype --without-harfbuzz --without-png --without-bzip2 --without-brotli --with-zlib
  ls "$X86/lib"/*.dylib
}

cmd_fetch() {
  mkdir -p "$WORK"
  local tgz="$WORK/crossover-sources-${CX_VER}.tar.gz"
  [ -f "$tgz" ] || { say "Downloading $SRC_URL"; fetch_url "$tgz" "$SRC_URL"; }
  echo "crossover-sources-${CX_VER}.tar.gz sha256: $(shasum -a 256 "$tgz" | cut -d' ' -f1)"
  say "Extracting sources/wine"
  rm -rf "$SRC" "$WORK/sources"
  tar -xzf "$tgz" -C "$WORK" sources/wine
  mv "$WORK/sources/wine" "$SRC"; rm -rf "$WORK/sources"
  echo "Wine source: $(cat "$SRC/VERSION" 2>/dev/null || echo unknown)"
  say "Applying runtime/patches"
  python3 -I "$HERE/patches/apply.py" "$SRC"
}

configure_env() {
  export PATH="$(dirname "$ARM_BREW")/../opt/bison/bin:$(dirname "$ARM_BREW")/../opt/flex/bin:$(dirname "$ARM_BREW"):$PATH"
  # Only our x86_64 libraries may be found, never the arm64 ones in /opt/homebrew.
  x86_env
}

cmd_configure() {
  [ -d "$SRC" ] || die "run fetch first"
  configure_env
  rm -rf "$BLD"; mkdir -p "$BLD"
  say "configure (x86_64 + WoW64, probes run under Rosetta)"
  (cd "$BLD" && "$SRC/configure" \
      --prefix=/ \
      --build=x86_64-apple-darwin --host=x86_64-apple-darwin \
      --enable-archs=i386,x86_64 \
      --disable-tests \
      --with-freetype --with-gnutls --with-coreaudio --without-sdl \
      --without-x --without-vulkan --without-gstreamer --without-krb5 --without-cups \
      --without-sane --without-gphoto --without-pcap --without-usb --without-v4l2 \
      --without-capi --without-netapi --without-opencl --without-oss --without-pulse \
      --without-udev --without-unwind --without-inotify --without-dbus --without-wayland \
    ) 2>&1 | tee "$WORK/configure.log" | tail -40
  [ -f "$BLD/Makefile" ] || die "configure failed (see $WORK/configure.log)"
  # win32u still needs these names with --without-vulkan (Vulkan is only used if found at run time).
  sed -i '' 's|/\* #undef SONAME_LIBVULKAN \*/|#define SONAME_LIBVULKAN "libvulkan.1.dylib"|' "$BLD/include/config.h"
  sed -i '' 's|/\* #undef SONAME_LIBMOLTENVK \*/|#define SONAME_LIBMOLTENVK "libMoltenVK.dylib"|' "$BLD/include/config.h"
  grep -E 'SONAME_LIB(VULKAN|MOLTENVK)' "$BLD/include/config.h"
  grep -E '^configure: (WARNING|error)' "$WORK/configure.log" || true
}

cmd_build() {
  configure_env
  say "make -j$JOBS"
  (cd "$BLD" && make -j"$JOBS") > "$WORK/build.log" 2>&1 || { tail -60 "$WORK/build.log"; die "build failed"; }
  say "make install"
  rm -rf "$DIST"; mkdir -p "$DIST"
  (cd "$BLD" && make install DESTDIR="$DIST") > "$WORK/install.log" 2>&1 || { tail -40 "$WORK/install.log"; die "install failed"; }
  "$DIST/bin/wine" --version || true
}

# Copy a dylib and everything it links from $X86 into lib/, pointing references at
# @loader_path so the folder works wherever it is unpacked.
bundle_one() {
  local src="$1" name dep
  name="$(basename "$src")"
  [ -f "$DIST/lib/$name" ] && return 0
  cp -L "$src" "$DIST/lib/$name"; chmod u+w "$DIST/lib/$name"
  install_name_tool -id "@rpath/$name" "$DIST/lib/$name" 2>/dev/null
  for dep in $(otool -L "$src" | awk 'NR>1 {print $1}' | grep -F "$X86/"); do
    bundle_one "$(cd "$(dirname "$dep")" && pwd -P)/$(basename "$dep")"
    install_name_tool -change "$dep" "@loader_path/$(basename "$dep")" "$DIST/lib/$name" 2>/dev/null
  done
}

cmd_bundle() {
  [ -x "$DIST/bin/wine" ] || die "run build first"
  say "Bundling x86_64 libraries"
  mkdir -p "$DIST/lib"
  local l
  for l in libfreetype.6.dylib libgnutls.30.dylib; do
    [ -f "$X86/lib/$l" ] || die "missing $X86/lib/$l"
    bundle_one "$X86/lib/$l"
  done
  # Wine dlopens these by plain name; the launcher sets DYLD_FALLBACK_LIBRARY_PATH to lib/.
  find "$DIST/lib" -maxdepth 1 -name '*.dylib' -exec codesign --force --sign - {} \; 2>/dev/null
  ls "$DIST/lib"/*.dylib | xargs -n1 basename

  say "Adding DXMT $DXMT_VER (upstream release)"
  local d="$WORK/dxmt"; rm -rf "$d"; mkdir -p "$d"
  fetch_url "$d/dxmt.tar.gz" "$DXMT_URL"
  echo "dxmt-${DXMT_VER}-builtin.tar.gz sha256: $(shasum -a 256 "$d/dxmt.tar.gz" | cut -d' ' -f1)"
  tar -xzf "$d/dxmt.tar.gz" -C "$d"
  local root; root="$(dirname "$(find "$d" -type d -name x86_64-windows | head -1)")"
  [ -d "$root/x86_64-windows" ] && [ -f "$root/x86_64-unix/winemetal.so" ] || die "unexpected DXMT layout: $(find "$d" -maxdepth 3 | head)"
  local arch f
  for arch in x86_64-windows i386-windows; do
    [ -d "$root/$arch" ] || continue
    for f in "$root/$arch"/*.dll; do
      f="$(basename "$f")"
      [ -f "$DIST/lib/wine/$arch/$f" ] && [ ! -f "$DIST/lib/wine/$arch/$f.wined3d" ] \
        && cp "$DIST/lib/wine/$arch/$f" "$DIST/lib/wine/$arch/$f.wined3d"
      cp "$root/$arch/$f" "$DIST/lib/wine/$arch/$f"
    done
  done
  cp "$root/x86_64-unix/winemetal.so" "$DIST/lib/wine/x86_64-unix/winemetal.so"
  ls "$root"/x86_64-windows
}

cmd_package() {
  [ -x "$DIST/bin/wine" ] || die "run build first"
  local name="azur-runtime-cx${CX_VER}-dxmt${DXMT_VER#v}-${PATCH_REV}" out="$WORK/out"
  mkdir -p "$out"
  cat > "$DIST/SOURCES.txt" <<EOF
This runtime was built by runtime/build-runtime.sh in https://github.com/SELCORE/azur-promilia-launcher

Wine:  CodeWeavers CrossOver ${CX_VER} source (LGPL-2.1-or-later), with the small keyboard
       patches in runtime/patches/apply.py (revision ${PATCH_REV})
       ${SRC_URL}
DXMT:  ${DXMT_VER} by Feifan He for CodeWeavers (LGPL-2.1-or-later)
       https://github.com/3Shain/dxmt/tree/${DXMT_VER}
Bundled libraries, built from their official source releases by the same script:
$(printf '%s\n' "$LIB_SOURCES" | awk -F'|' 'NF>=2{print "  "$1": "$2}')
  (GMP, Nettle, GnuTLS: LGPL; FreeType: FreeType License)
EOF
  say "Packing $name.tar.xz"
  (cd "$WORK/dist" && tar -cJf "$out/$name.tar.xz" wine)
  (cd "$out" && shasum -a 256 "$name.tar.xz" > "$name.tar.xz.sha256")
  ls -la "$out"; cat "$out/$name.tar.xz.sha256"
}

case "${1:-all}" in
  deps) cmd_deps ;; fetch) cmd_fetch ;; configure) cmd_configure ;; build) cmd_build ;;
  bundle) cmd_bundle ;; package) cmd_package ;;
  all) cmd_deps; cmd_fetch; cmd_configure; cmd_build; cmd_bundle; cmd_package ;;
  *) sed -n '2,14p' "$0"; exit 1 ;;
esac
