#!/bin/bash
# Install or update Layout Fixer:
#   curl -fsSL https://raw.githubusercontent.com/m-ilchuk/layout-fixer/main/get.sh | bash
#
# Downloads the source, builds it on this Mac (nothing prebuilt is downloaded, so Gatekeeper has nothing to
# block), installs ~/Applications/LayoutFixer.app and starts it. Reads nothing from stdin, so it is safe to pipe.
set -euo pipefail

REPO="m-ilchuk/layout-fixer"
REF="${LAYOUT_FIXER_REF:-latest}"
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

# The latest release (v1.2.0, …); LAYOUT_FIXER_REF=main installs the newest code instead.
if [[ -n "${LAYOUT_FIXER_SOURCE_URL:-}" ]]; then
  SOURCE_URL="$LAYOUT_FIXER_SOURCE_URL"
else
  if [[ "$REF" == "latest" ]]; then
    TAG=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
      | sed -n 's/^ *"tag_name": *"\([^"]*\)".*/\1/p' | head -1 || true)
    REF="${TAG:-main}"  # no release published yet: the newest code
  fi
  SOURCE_URL="https://github.com/$REPO/archive/$REF.tar.gz"
  echo "Installing Layout Fixer $REF"
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
echo "Downloading $SOURCE_URL"
curl -fsSL "$SOURCE_URL" | tar -xz -C "$WORK" --strip-components 1 || fail "could not download the source."
echo "Building (about a minute)…"
"$WORK/install.sh" >"$WORK/build.log" 2>&1 || { cat "$WORK/build.log" >&2; fail "the build failed (log above)."; }

echo
"$HOME/Applications/LayoutFixer.app/Contents/MacOS/LayoutFixer" --layouts || true
if (( UPDATING )); then
  cat <<'MSG'

Layout Fixer is updated and running.

Allow it again: macOS sees each new build as a new app. Open System Settings › Privacy & Security ›
Accessibility, select LayoutFixer, remove it with –, then add it again with + (press ⌘⇧G and type
~/Applications/LayoutFixer.app) and turn it on.
MSG
else
  cat <<'MSG'

Layout Fixer is installed in ~/Applications and running (⚠ in the menu bar until you allow it).

One step left: a dialog asks to let "LayoutFixer" control this computer. Click Open System Settings and
turn on LayoutFixer. No dialog? Open System Settings › Privacy & Security › Accessibility, click +,
press ⌘⇧G, type ~/Applications/LayoutFixer.app, click Open and turn it on.
MSG
fi
cat <<'MSG'

Then select text typed on the wrong layout (or just type a word) and tap the right ⌥ key on its own.
Tap again to convert it back. Help: https://github.com/m-ilchuk/layout-fixer#use
MSG
