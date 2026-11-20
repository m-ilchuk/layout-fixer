#!/bin/bash
# Install or update Layout Fixer:
#   curl -fsSL https://raw.githubusercontent.com/m-ilchuk/layout-fixer/main/get.sh | bash
#
# Downloads the source, builds it on this Mac (nothing prebuilt is downloaded, so Gatekeeper has nothing to
# block), installs "~/Applications/Layout Fixer.app" and starts it. Reads nothing from stdin, so it is safe to pipe.
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
[[ -d ~/Applications/"Layout Fixer.app" || -d ~/Applications/LayoutFixer.app ]] && UPDATING=1

# The latest release (v1.2.0, …); LAYOUT_FIXER_REF=main installs the newest code instead.
if [[ -n "${LAYOUT_FIXER_SOURCE_URL:-}" ]]; then
  SOURCE_URL="$LAYOUT_FIXER_SOURCE_URL"
else
  if [[ "$REF" == "latest" ]]; then
    # Never the newest code instead: when GitHub can't say which release is latest (no network, its hourly limit),
    # stop rather than build whatever is on main.
    TAG=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
      | sed -n 's/^ *"tag_name": *"\([^"]*\)".*/\1/p' | head -1 || true)
    [[ -n "$TAG" ]] || fail "couldn't ask GitHub for the latest release (no network, or its hourly limit). Try again later, or set LAYOUT_FIXER_REF to a release tag such as v0.2.9."
    REF="$TAG"
  fi
  [[ "$REF" =~ ^[A-Za-z0-9._-]+$ ]] || fail "LAYOUT_FIXER_REF must be a release tag or branch name, not \"$REF\"."
  SOURCE_URL="https://github.com/$REPO/archive/$REF.tar.gz"
  echo "Installing Layout Fixer $REF"
fi

# Reused by every update: the compiler's cache of Apple's frameworks, most of the build time.
export LAYOUT_FIXER_MODULE_CACHE="$HOME/Library/Caches/io.github.m-ilchuk.layoutfixer/module-cache"
mkdir -p "$LAYOUT_FIXER_MODULE_CACHE"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
echo "Downloading $SOURCE_URL"
curl -fsSL "$SOURCE_URL" | tar -xz -C "$WORK" --strip-components 1 || fail "could not download the source."
echo "Building (about a minute)…"
LOG="$WORK/build.log"
"$WORK/install.sh" >"$LOG" 2>&1 &
BUILD=$!
START=$SECONDS
SPINNER='-\|/'
TICK=0
# In a terminal, one updating line: the build's latest step ("==> Compiling …") and the seconds so far.
# Otherwise (the app updating itself reads this output for its progress bar), each new step as a line.
LAST_STEP=""
while kill -0 "$BUILD" 2>/dev/null; do
  STEP=$(grep '^==> ' "$LOG" 2>/dev/null | tail -1 | cut -c5- || true)  # no step yet is fine
  if [[ -t 1 ]]; then
    printf '\r  %s %s… %ds   ' "${SPINNER:TICK++%4:1}" "${STEP:-Building}" $((SECONDS - START))
  elif [[ -n "$STEP" && "$STEP" != "$LAST_STEP" ]]; then
    echo "==> $STEP"
  fi
  LAST_STEP="$STEP"
  sleep 0.25
done
if ! wait "$BUILD"; then
  [[ -t 1 ]] && printf '\n'
  cat "$LOG" >&2
  fail "the build failed (log above)."
fi
if [[ -t 1 ]]; then printf '\r  ✓ Built in %ds%40s\n' $((SECONDS - START)) ""; else echo "Built in $((SECONDS - START))s"; fi

echo
"$HOME/Applications/Layout Fixer.app/Contents/MacOS/LayoutFixer" --layouts || true
if (( UPDATING )); then
  cat <<'MSG'

Layout Fixer is updated and running.

If its window shows ⚠ (once, when updating from 0.2.1 or earlier): open System Settings › Privacy &
Security › Accessibility, select Layout Fixer (or LayoutFixer), remove it with –, then open Layout Fixer
and allow it when asked. Later updates keep the permission.
MSG
else
  cat <<'MSG'

Layout Fixer is installed in ~/Applications and running (⚠ in the menu bar until you allow it).

One step left: a dialog asks to let "Layout Fixer" control this computer. Click Open System Settings and
turn on Layout Fixer. No dialog? Open System Settings › Privacy & Security › Accessibility, click +,
press ⌘⇧G, type ~/Applications/Layout Fixer.app, click Open and turn it on.
MSG
fi
cat <<'MSG'

Then select text typed on the wrong layout (or just type a word) and tap the right ⌥ key on its own.
Tap again to convert it back. Help: https://github.com/m-ilchuk/layout-fixer#use
MSG
