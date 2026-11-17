#!/bin/bash
# Install or update Layout Fixer:
#   curl -fsSL https://raw.githubusercontent.com/m-ilchuk/layout-fixer/main/get.sh | bash
#
# Downloads the source, builds it on this Mac (nothing prebuilt is downloaded, so Gatekeeper has nothing to
# block), installs ~/Applications/LayoutFixer.app and starts it. Reads nothing from stdin, so it is safe to pipe.
set -euo pipefail

REPO="m-ilchuk/layout-fixer"
REF="${LAYOUT_FIXER_REF:-main}"
SOURCE_URL="${LAYOUT_FIXER_SOURCE_URL:-https://github.com/$REPO/archive/refs/heads/$REF.tar.gz}"
MIN_MACOS_MAJOR=13

fail() { echo "Layout Fixer: $*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "this is a macOS app."
MACOS_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
(( MACOS_MAJOR >= MIN_MACOS_MAJOR )) || fail "needs macOS $MIN_MACOS_MAJOR or newer (this Mac has $(sw_vers -productVersion))."

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Layout Fixer is built on your Mac and needs Apple's command line tools (free, about 1 GB)."
  xcode-select --install 2>/dev/null || true
  fail "finish the install in the window that just opened, then run this command again."
fi

UPDATING=0
[[ -d ~/Applications/LayoutFixer.app ]] && UPDATING=1

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
echo "Downloading $SOURCE_URL"
curl -fsSL "$SOURCE_URL" | tar -xz -C "$WORK" --strip-components 1 || fail "could not download the source."
echo "Building (about a minute)…"
"$WORK/install.sh" >"$WORK/build.log" 2>&1 || { cat "$WORK/build.log" >&2; fail "the build failed (log above)."; }

cat <<'MSG'

Layout Fixer is installed in ~/Applications and running (the ⌨ icon in the menu bar).

One step left: allow it in System Settings › Privacy & Security › Accessibility.
MSG
if (( UPDATING )); then
  cat <<'MSG'
Because this is an update, macOS treats it as a new app: select LayoutFixer in that list, remove it with –,
then add ~/Applications/LayoutFixer.app with + and turn it on.
MSG
fi
cat <<'MSG'

Then select wrongly typed text (or just type a word) and tap the right ⌥ key on its own.
Menu bar item › Open at login starts it with your Mac.
MSG
