#!/bin/bash
# 编译 Swift 包（在本机沙盒环境下需要 --disable-sandbox 与 ASCII TMPDIR）
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p .build/cache .build/config .build/modulecache
TMPDIR=/private/tmp/dshbuild \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/modulecache" \
CLANG_MODULE_CACHE_PATH="$PWD/.build/modulecache" \
swift build -c release --disable-sandbox \
  --scratch-path .build --cache-path .build/cache --config-path .build/config \
  "$@"
