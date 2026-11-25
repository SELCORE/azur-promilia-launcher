#!/bin/bash
# Builds the launcher's own Wine runtime from CodeWeavers' published CrossOver source,
# adds DXMT from its upstream release, bundles the libraries Wine loads at run time,
# and packs everything into one relocatable tarball.
#
# Runs on an Apple Silicon Mac (GitHub's macOS runners or your own Mac):
#   - Wine is built for x86_64 (it runs under Rosetta 2), with WoW64 so 32-bit Windows
#     programs (for example Nexon's NGService.exe) work too.
#   - Build tools (bison, mingw-w64) come from the native Homebrew in /opt/homebrew.
#   - Libraries Wine links at run time (FreeType, GnuTLS, ...) must be x86_64, so they come
#     from a second, x86_64 Homebrew in /usr/local. `deps` installs it (needs sudo once).
#
# Usage: runtime/build-runtime.sh deps|fetch|configure|build|bundle|package|all
# Env:   CX_VER (default 26.3.0), DXMT_VER (default v0.80), WORK (default ./runtime-work), JOBS
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CX_VER="${CX_VER:-26.3.0}"
DXMT_VER="${DXMT_VER:-v0.80}"
WORK="${WORK:-$PWD/runtime-work}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
SRC_URL="https://media.codeweavers.com/pub/crossover/source/crossover-sources-${CX_VER}.tar.gz"
DXMT_URL="https://github.com/3Shain/dxmt/releases/download/${DXMT_VER}/dxmt-${DXMT_VER}-builtin.tar.gz"
ARM_BREW=/opt/homebrew/bin/brew
X86_BREW=/usr/local/bin/brew
SRC="$WORK/wine-src"
BLD="$WORK/wine-build"
DIST="$WORK/dist/wine"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# x86_64 libraries Wine dlopens (FreeType for fonts, GnuTLS for HTTPS/schannel, SDL2 for gamepads).
X86_LIBS="freetype gnutls sdl2"

cmd_deps() {
  say "Build tools (native Homebrew)"
  "$ARM_BREW" install bison flex mingw-w64 pkgconf
  if [ ! -x "$X86_BREW" ]; then
    say "Installing an x86_64 Homebrew in /usr/local (for x86_64 libraries)"
    /usr/sbin/softwareupdate --install-rosetta --agree-to-license >/dev/null 2>&1 || true
    arch -x86_64 /bin/bash -c "NONINTERACTIVE=1 $(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
  say "x86_64 libraries: $X86_LIBS"
  # shellcheck disable=SC2086
  arch -x86_64 "$X86_BREW" install $X86_LIBS
}

cmd_fetch() {
  mkdir -p "$WORK"
  local tgz="$WORK/crossover-sources-${CX_VER}.tar.gz"
  [ -f "$tgz" ] || { say "Downloading $SRC_URL"; curl -fL --retry 3 -o "$tgz" "$SRC_URL"; }
  echo "crossover-sources-${CX_VER}.tar.gz sha256: $(shasum -a 256 "$tgz" | cut -d' ' -f1)"
  say "Extracting sources/wine"
  rm -rf "$SRC" "$WORK/sources"
  tar -xzf "$tgz" -C "$WORK" sources/wine
  mv "$WORK/sources/wine" "$SRC"; rm -rf "$WORK/sources"
  echo "Wine source: $(cat "$SRC/VERSION" 2>/dev/null || echo unknown)"
}

configure_env() {
  export PATH="$(dirname "$ARM_BREW")/../opt/bison/bin:$(dirname "$ARM_BREW")/../opt/flex/bin:$(dirname "$ARM_BREW"):$PATH"
  # Only the x86_64 libraries may be found, never the arm64 ones in /opt/homebrew.
  export PKG_CONFIG_LIBDIR="/usr/local/lib/pkgconfig:/usr/local/share/pkgconfig"
  export PKG_CONFIG_PATH=""
  export CC="clang -arch x86_64" CXX="clang++ -arch x86_64" OBJC="clang -arch x86_64"
  export CPPFLAGS="-I/usr/local/include" LDFLAGS="-L/usr/local/lib"
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
      --with-freetype --with-gnutls --with-sdl --with-coreaudio \
      --without-x --without-vulkan --without-gstreamer --without-krb5 --without-cups \
      --without-sane --without-gphoto --without-pcap --without-usb --without-v4l2 \
      --without-capi --without-netapi --without-opencl --without-oss --without-pulse \
      --without-udev --without-unwind --without-inotify --without-dbus --without-wayland \
    ) 2>&1 | tee "$WORK/configure.log" | tail -40
  [ -f "$BLD/Makefile" ] || die "configure failed (see $WORK/configure.log)"
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

# Copy a dylib and everything it links from /usr/local into lib/, pointing references at
# @loader_path so the folder works wherever it is unpacked.
bundle_one() {
  local src="$1" name dep
  name="$(basename "$src")"
  [ -f "$DIST/lib/$name" ] && return 0
  cp -L "$src" "$DIST/lib/$name"; chmod u+w "$DIST/lib/$name"
  install_name_tool -id "@rpath/$name" "$DIST/lib/$name" 2>/dev/null
  for dep in $(otool -L "$src" | awk 'NR>1 {print $1}' | grep -E '^/usr/local/'); do
    bundle_one "$(cd "$(dirname "$dep")" && pwd -P)/$(basename "$dep")"
    install_name_tool -change "$dep" "@loader_path/$(basename "$dep")" "$DIST/lib/$name" 2>/dev/null
  done
}

cmd_bundle() {
  [ -x "$DIST/bin/wine" ] || die "run build first"
  say "Bundling x86_64 libraries"
  mkdir -p "$DIST/lib"
  local l
  for l in libfreetype.6.dylib libgnutls.30.dylib libSDL2-2.0.0.dylib; do
    [ -f "/usr/local/lib/$l" ] && bundle_one "/usr/local/lib/$l"
  done
  # Wine dlopens these by plain name; the launcher sets DYLD_FALLBACK_LIBRARY_PATH to lib/.
  find "$DIST/lib" -maxdepth 1 -name '*.dylib' -exec codesign --force --sign - {} \; 2>/dev/null
  ls "$DIST/lib"/*.dylib | xargs -n1 basename

  say "Adding DXMT $DXMT_VER (upstream release)"
  local d="$WORK/dxmt"; rm -rf "$d"; mkdir -p "$d"
  curl -fL --retry 3 -o "$d/dxmt.tar.gz" "$DXMT_URL"
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
  local name="azur-runtime-cx${CX_VER}-dxmt${DXMT_VER#v}" out="$WORK/out"
  mkdir -p "$out"
  cat > "$DIST/SOURCES.txt" <<EOF
This runtime was built by runtime/build-runtime.sh in https://github.com/SELCORE/azur-promilia-launcher

Wine:  CodeWeavers CrossOver ${CX_VER} source (LGPL-2.1-or-later), unmodified
       ${SRC_URL}
DXMT:  ${DXMT_VER} by Feifan He for CodeWeavers (LGPL-2.1-or-later)
       https://github.com/3Shain/dxmt/tree/${DXMT_VER}
Bundled libraries come from Homebrew (FreeType, GnuTLS and its dependencies, SDL2); their
licenses and sources are listed at https://formulae.brew.sh
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
