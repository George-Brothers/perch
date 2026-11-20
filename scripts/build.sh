#!/usr/bin/env bash
# Builds Perch.app into ./build. Pass --install to copy it to /Applications and open it.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodebuild -project Perch.xcodeproj -scheme Perch -configuration Release \
  -destination "generic/platform=macOS" -derivedDataPath build/DerivedData build -quiet

rm -rf build/Perch.app
cp -R build/DerivedData/Build/Products/Release/Perch.app build/

# Sign with the local certificate if it exists (see scripts/make-signing-cert.sh),
# so macOS keeps Perch's Accessibility permission across rebuilds.
if security find-certificate -c "Perch Local Signing" >/dev/null 2>&1; then
  codesign --force --deep --options runtime -s "Perch Local Signing" build/Perch.app 2>/dev/null
  echo "Signed with Perch Local Signing"
fi
echo "Built build/Perch.app"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Perch 2>/dev/null || true
  rm -rf /Applications/Perch.app
  cp -R build/Perch.app /Applications/
  open /Applications/Perch.app
  echo "Installed and opened /Applications/Perch.app"
fi
