#!/bin/bash
# End-to-end test: types corpus sentences into TextEdit with real key presses while Layout Fixer runs, and checks
# what TextEdit shows. `./e2e.sh` for a sample, `./e2e.sh all` for every sentence. Takes over the keyboard while it
# runs (a few minutes): don't type or click. Needs Accessibility for Terminal (README: "End-to-end test").
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
swiftc -O -module-cache-path "${LAYOUT_FIXER_MODULE_CACHE:-build/module-cache}" \
  Sources/KeyLayout.swift Tests/Corpus.swift Tests/e2e/main.swift -o build/e2e
exec build/e2e "$@"
