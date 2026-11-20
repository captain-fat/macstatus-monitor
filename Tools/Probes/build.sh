#!/bin/bash
# 直接调用 swiftc 编译探针（避开 SwiftPM 在受限环境下的沙箱/缓存问题）
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/bin .build/modulecache
time swiftc -O -swift-version 5 \
  -module-cache-path "$PWD/.build/modulecache" \
  -o .build/bin/probe \
  Sources/probe/*.swift
