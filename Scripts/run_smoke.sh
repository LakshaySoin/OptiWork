#!/bin/bash
# Build the pure core and run the Foundation-free smoke suite with plain `swiftc`
# (works with Command Line Tools only — no Xcode / working SwiftPM required).
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${FX_BUILD_DIR:-/tmp/fx}"
mkdir -p "$OUT"

# CLT quirk: normalize file mtimes before compiling to avoid a
# "file was modified during the build" error.
touch Sources/FocusTrackerCore/*.swift Scripts/smoke.swift

swiftc -emit-library -emit-module -module-name FocusTrackerCore \
  Sources/FocusTrackerCore/*.swift \
  -o "$OUT/libFocusTrackerCore.dylib" \
  -emit-module-path "$OUT/FocusTrackerCore.swiftmodule"

swiftc -parse-as-library Scripts/smoke.swift \
  -I "$OUT" -L "$OUT" -lFocusTrackerCore \
  -Xlinker -rpath -Xlinker "$OUT" -o "$OUT/smoke"

"$OUT/smoke"