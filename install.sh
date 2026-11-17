#!/bin/bash
# Builds, copies to ~/Applications and starts Layout Fixer. macOS then asks for Accessibility.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
echo "==> Installing to ~/Applications"
# LAYOUT_FIXER_NO_LAUNCH=1: the running app is updating itself and restarts on its own.
[[ -n "${LAYOUT_FIXER_NO_LAUNCH:-}" ]] || pkill -x LayoutFixer 2>/dev/null || true
mkdir -p ~/Applications
rm -rf ~/Applications/LayoutFixer.app
cp -R build/LayoutFixer.app ~/Applications/
[[ -n "${LAYOUT_FIXER_NO_LAUNCH:-}" ]] || open ~/Applications/LayoutFixer.app
echo "installed ~/Applications/LayoutFixer.app"
