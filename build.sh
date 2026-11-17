#!/bin/bash
# Builds LayoutFixer.app (and runs the tests with --test). Needs only the Xcode command line tools.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
CORE=(Sources/KeyLayout.swift Sources/Converter.swift Sources/AutoFix.swift)

if [[ "${1:-}" == "--test" ]]; then
  swiftc -O "${CORE[@]}" Tests/main.swift -o build/tests
  exec build/tests
fi

APP=build/LayoutFixer.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O "${CORE[@]}" Sources/main.swift -o "$APP/Contents/MacOS/LayoutFixer"
cp Info.plist "$APP/Contents/Info.plist"
# With the "LayoutFixer Local Signing" certificate (README: "Keep permissions across rebuilds") every build has the
# same signature, so macOS keeps Accessibility and Input Monitoring. Without it: ad-hoc, allow again after each build.
IDENTITY="LayoutFixer Local Signing"
if security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" --identifier io.local.layoutfixer "$APP"
  echo "signed with $IDENTITY"
else
  codesign --force --sign - --identifier io.local.layoutfixer "$APP"
  echo "ad-hoc signed: allow LayoutFixer again in Privacy & Security after installing"
fi
echo "built $APP"
