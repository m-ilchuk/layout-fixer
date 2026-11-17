#!/bin/bash
# Builds, copies to ~/Applications and starts Layout Fixer. macOS then asks for Accessibility.
set -euo pipefail
cd "$(dirname "$0")"
APP_NAME="Layout Fixer.app"
OLD_APP_NAME="LayoutFixer.app"  # the name before 0.2.0
./build.sh
echo "==> Installing to ~/Applications"
# LAYOUT_FIXER_NO_LAUNCH=1: the running app is updating itself and restarts on its own.
[[ -n "${LAYOUT_FIXER_NO_LAUNCH:-}" ]] || pkill -x LayoutFixer 2>/dev/null || true
mkdir -p ~/Applications
RENAMED=0
if [[ -d ~/Applications/"$OLD_APP_NAME" ]]; then
  rm -rf ~/Applications/"$OLD_APP_NAME"
  RENAMED=1
fi
rm -rf ~/Applications/"$APP_NAME"
cp -R build/"$APP_NAME" ~/Applications/
if [[ -z "${LAYOUT_FIXER_NO_LAUNCH:-}" ]]; then
  open ~/Applications/"$APP_NAME"
elif (( RENAMED )); then
  # An app from before the rename reopens itself under the old name, which is gone: open the new one once it quits.
  nohup /bin/sh -c 'sleep 3; open "$HOME/Applications/Layout Fixer.app"' >/dev/null 2>&1 &
fi
echo "installed ~/Applications/$APP_NAME"
