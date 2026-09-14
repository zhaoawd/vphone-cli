#!/bin/zsh
# Build the two bundled host tools from initialized submodules.
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
cd "$PROJECT_ROOT"
mkdir -p .tools/bin
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT
ditto scripts/repos/trustcache "$BUILD_DIR/trustcache"
OPENSSL_PREFIX="$(brew --prefix openssl@3)"
make -C "$BUILD_DIR/trustcache" clean
make -C "$BUILD_DIR/trustcache" OPENSSL=1 \
  CFLAGS="-I${OPENSSL_PREFIX}/include -DOPENSSL -w" \
  LDFLAGS="-L${OPENSSL_PREFIX}/lib" -j"$(sysctl -n hw.logicalcpu)"
cp "$BUILD_DIR/trustcache/trustcache" .tools/bin/trustcache
clang -o .tools/bin/insert_dylib \
  scripts/repos/insert_dylib/insert_dylib/main.c -framework Security -O2
