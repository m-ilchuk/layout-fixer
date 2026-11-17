#!/bin/bash
# Builds LayoutFixer.app for Apple silicon and Intel (and runs the tests with --test).
# Needs only Apple's command line tools (xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
CORE=(Sources/KeyLayout.swift Sources/Converter.swift Sources/AutoFix.swift Sources/Setup.swift Sources/Version.swift)
APP_ONLY=(Sources/Flash.swift Sources/Updater.swift Sources/SettingsWindow.swift Sources/main.swift)
MIN_MACOS=13.0
# Keep the compiler's cache inside build/, so the build writes nowhere else.
SWIFTC=(swiftc -O -module-cache-path build/module-cache)

if [[ "${1:-}" == "--test" ]]; then
  "${SWIFTC[@]}" "${CORE[@]}" Tests/main.swift -o build/tests
  exec build/tests
fi

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" Info.plist)
APP=build/LayoutFixer.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
# "==> " lines are progress steps: get.sh shows the latest one while it waits.
echo "==> Compiling for Apple silicon and Intel"
PIDS=()
for ARCH in arm64 x86_64; do
  "${SWIFTC[@]}" -target "$ARCH-apple-macos$MIN_MACOS" "${CORE[@]}" "${APP_ONLY[@]}" -o "build/LayoutFixer-$ARCH" &
  PIDS+=($!)
done
for PID in "${PIDS[@]}"; do wait "$PID" || { echo "build.sh: compiling failed" >&2; exit 1; }; done
echo "==> Signing"
lipo -create build/LayoutFixer-arm64 build/LayoutFixer-x86_64 -output "$APP/Contents/MacOS/LayoutFixer"
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"  # made by: swift Icon/make-icon.swift
# The commit this build comes from, for "Check for Updates" (get.sh passes it; a checkout knows it).
COMMIT="${LAYOUT_FIXER_COMMIT:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}"
/usr/libexec/PlistBuddy -c "Add :LFSourceCommit string $COMMIT" "$APP/Contents/Info.plist"

# With the "LayoutFixer Local Signing" certificate (README: "Keep permissions across rebuilds") every build has the
# same signature, so macOS keeps the app's permissions. Without it: ad-hoc, allow it again after each build.
IDENTITY="LayoutFixer Local Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
  echo "signed with $IDENTITY"
else
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
  echo "ad-hoc signed"
fi
echo "built $APP"
