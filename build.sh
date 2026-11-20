#!/bin/bash
# Builds "Layout Fixer.app" for this Mac (and runs the tests with --test).
# Needs only Apple's command line tools (xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
CORE=(Sources/KeyLayout.swift Sources/Converter.swift Sources/AutoFix.swift Sources/Setup.swift Sources/Version.swift Sources/ReleaseNotes.swift Sources/UpdateProgress.swift Sources/TypingSession.swift Sources/ReplaceMethod.swift Sources/Statistics.swift Sources/Exclusions.swift Sources/HeldKeys.swift)
APP_ONLY=(Sources/Flash.swift Sources/Updater.swift Sources/SettingsWindow.swift Sources/ExclusionsPage.swift Sources/ReleaseNotesView.swift Sources/DebugLog.swift Sources/main.swift)
MIN_MACOS=13.0
# The compiler's cache of Apple's frameworks: most of a first build (about 40 s of 45). Inside build/ by default;
# the installer keeps it in ~/Library/Caches, so updates reuse it (about 8 s). The compiler checks it per version.
MODULE_CACHE="${LAYOUT_FIXER_MODULE_CACHE:-build/module-cache}"
# Whole-module: the compiler sees all files at once (about 40% faster here, and a smaller app).
SWIFTC=(swiftc -O -wmo -module-cache-path "$MODULE_CACHE")

if [[ "${1:-}" == "--test" ]]; then
  # Tests without optimising: about 2 s to build instead of 15, a few seconds slower to run.
  swiftc -Onone -wmo -module-cache-path "$MODULE_CACHE" "${CORE[@]}" Tests/Corpus.swift Tests/main.swift -o build/tests
  exec build/tests
fi

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" Info.plist)
APP="build/Layout Fixer.app"  # the program inside is still LayoutFixer
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
# Built on the Mac that runs it, so only for that Mac's chip: the hardware, not the shell (a Terminal under
# Rosetta says x86_64 on Apple silicon). LAYOUT_FIXER_UNIVERSAL=1 builds both, to hand one app to anyone.
if [[ -n "${LAYOUT_FIXER_UNIVERSAL:-}" ]]; then
  ARCHS=(arm64 x86_64)
  STEP="Compiling for Apple silicon and Intel"
elif [[ "$(sysctl -n hw.optional.arm64 2>/dev/null)" == "1" ]]; then
  ARCHS=(arm64)
  STEP="Compiling for Apple silicon"
else
  ARCHS=(x86_64)
  STEP="Compiling for Intel"
fi
# "==> " lines are progress steps: get.sh and the in-app updater show the latest one while they wait.
echo "==> $STEP"
PIDS=()
for ARCH in "${ARCHS[@]}"; do
  "${SWIFTC[@]}" -target "$ARCH-apple-macos$MIN_MACOS" "${CORE[@]}" "${APP_ONLY[@]}" -o "build/LayoutFixer-$ARCH" &
  PIDS+=($!)
done
for PID in "${PIDS[@]}"; do wait "$PID" || { echo "build.sh: compiling failed" >&2; exit 1; }; done
echo "==> Signing"
lipo -create "${ARCHS[@]/#/build/LayoutFixer-}" -output "$APP/Contents/MacOS/LayoutFixer"
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
# Hardened runtime on both: no other program can load code into the app (DYLD_INSERT_LIBRARIES and the like) to
# borrow its Accessibility permission.
IDENTITY="LayoutFixer Local Signing"
if [[ -z "${LAYOUT_FIXER_ADHOC:-}" ]] && security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  codesign --force --options runtime --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
  echo "signed with $IDENTITY"
else
  codesign --force --options runtime --sign - --identifier "$BUNDLE_ID" -r="designated => identifier \"$BUNDLE_ID\"" "$APP"
  echo "ad-hoc signed, recognised by its identifier"
fi
echo "built $APP"
