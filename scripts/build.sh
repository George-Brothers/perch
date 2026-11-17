#!/usr/bin/env bash
# Builds Perch.app into ./build. Pass --install to copy it to /Applications and open it.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodebuild -project Perch.xcodeproj -scheme Perch -configuration Release \
  -destination "generic/platform=macOS" -derivedDataPath build/DerivedData build -quiet

rm -rf build/Perch.app
cp -R build/DerivedData/Build/Products/Release/Perch.app build/
echo "Built build/Perch.app"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Perch 2>/dev/null || true
  rm -rf /Applications/Perch.app
  cp -R build/Perch.app /Applications/
  open /Applications/Perch.app
  echo "Installed and opened /Applications/Perch.app"
fi
