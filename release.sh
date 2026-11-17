#!/bin/bash
# Publish a new version: ./release.sh 1.2.0
#
# Semantic versioning: MAJOR when something people rely on changes or goes away, MINOR for new features,
# PATCH for fixes. Checks main is clean and in sync, runs the tests, sets the version in Info.plist, commits,
# tags vX.Y.Z, pushes, and creates the GitHub Release from the "Unreleased" section of CHANGELOG.md.
# Installed apps see it within a day (or on Check for Updates…); the installer installs it from then on.
set -euo pipefail
cd "$(dirname "$0")"
fail() { echo "release: $*" >&2; exit 1; }

VERSION="${1:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "usage: ./release.sh X.Y.Z (for example 1.2.0)"
TAG="v$VERSION"
CURRENT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)

[[ "$(git branch --show-current)" == "main" ]] || fail "switch to main first."
[[ -z "$(git status --porcelain)" ]] || fail "commit or stash your changes first."
git fetch -q --tags origin
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "main isn't the same as origin/main: pull or push first."
[[ -z "$(git tag -l "$TAG")" ]] || fail "$TAG already exists."
NEWEST=$(printf '%s\n%s\n' "$CURRENT" "$VERSION" | sort -V | tail -1)
[[ "$NEWEST" == "$VERSION" && "$CURRENT" != "$VERSION" ]] || fail "$VERSION must be newer than the current $CURRENT."
command -v gh >/dev/null || fail "needs the GitHub CLI (brew install gh, then gh auth login)."

echo "Testing…"
./build.sh --test >/dev/null || fail "tests failed: run ./build.sh --test"
echo "Building…"
./build.sh >/dev/null 2>&1 || fail "build failed: run ./build.sh"

# Release notes: the "## Unreleased" section of CHANGELOG.md, which becomes this version's section.
NOTES=$(awk '/^## Unreleased/ { on = 1; next } /^## / { on = 0 } on' CHANGELOG.md | sed '/./,$!d')
[[ -n "$(printf '%s' "$NOTES" | tr -d '[:space:]')" ]] \
  || fail "write what changed under \"## Unreleased\" in CHANGELOG.md first."
awk -v heading="## $VERSION — $(date +%Y-%m-%d)" \
  '/^## Unreleased/ { print; print ""; print heading; next } { print }' CHANGELOG.md > CHANGELOG.md.new
mv CHANGELOG.md.new CHANGELOG.md

BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist)
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((BUILD + 1))" Info.plist
git commit -q -m "Release $VERSION" Info.plist CHANGELOG.md
git tag -a "$TAG" -m "Layout Fixer $VERSION"
git push -q origin main "$TAG"
gh release create "$TAG" --title "Layout Fixer $VERSION" --notes "$NOTES" --verify-tag
echo "Released $TAG: https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner)/releases/tag/$TAG"
