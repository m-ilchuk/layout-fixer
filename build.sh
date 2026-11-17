#!/bin/bash
# Builds "Layout Fixer.app" for Apple silicon and Intel (and runs the tests with --test).
# Needs only Apple's command line tools (xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
CORE=(Sources/KeyLayout.swift Sources/Converter.swift Sources/AutoFix.swift Sources/Setup.swift Sources/Version.swift Sources/ReleaseNotes.swift Sources/UpdateProgress.swift)
APP_ONLY=(Sources/Flash.swift Sources/Updater.swift Sources/SettingsWindow.swift Sources/ReleaseNotesView.swift Sources/main.swift)
MIN_MACOS=13.0
# Keep the compiler's cache inside build/, so the build writes nowhere else.
SWIFTC=(swiftc -O -module-cache-path build/module-cache)

if [[ "${1:-}" == "--test" ]]; then
  "${SWIFTC[@]}" "${CORE[@]}" Tests/main.swift -o build/tests
  exec build/tests
fi

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" Info.plist)
APP="build/Layout Fixer.app"  # the program inside is still LayoutFixer
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

# macOS ties Accessibility to the app's "designated requirement". With the "LayoutFixer Local Signing" certificate
# (README: "Keep permissions across rebuilds") that is the certificate. Without it the build is ad-hoc, whose
# requirement would be this build's own hash, new on every update; so it says "identifier
# io.github.m-ilchuk.layoutfixer" instead, and every later build keeps the permission (README: Privacy).
# LAYOUT_FIXER_ADHOC=1 makes an ad-hoc build even where the certificate exists (to test this path).
IDENTITY="LayoutFixer Local Signing"
if [[ -z "${LAYOUT_FIXER_ADHOC:-}" ]] && security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
  echo "signed with $IDENTITY"
else
  codesign --force --sign - --identifier "$BUNDLE_ID" -r="designated => identifier \"$BUNDLE_ID\"" "$APP"
  echo "ad-hoc signed, recognised by its identifier"
fi
echo "built $APP"
