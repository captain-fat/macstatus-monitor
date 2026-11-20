#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./Scripts/build.sh >/dev/null
./.build/release/MacStatusMonitor --render-previews "$PWD/../Docs/previews/menubar.png"
