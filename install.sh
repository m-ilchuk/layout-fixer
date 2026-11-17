#!/bin/bash
# Builds, copies to ~/Applications and starts Layout Fixer. macOS then asks for Accessibility.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
pkill -x LayoutFixer 2>/dev/null || true
mkdir -p ~/Applications
rm -rf ~/Applications/LayoutFixer.app
cp -R build/LayoutFixer.app ~/Applications/
open ~/Applications/LayoutFixer.app
echo "installed ~/Applications/LayoutFixer.app"
