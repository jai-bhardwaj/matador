#!/usr/bin/env bash
# Matador installer — fetches the latest DMG, mounts it, copies to /Applications,
# strips the quarantine bit so Gatekeeper won't prompt.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/jai-bhardwaj/matador/main/release/install.sh | bash

set -euo pipefail

MANIFEST_URL="https://raw.githubusercontent.com/jai-bhardwaj/matador/main/release/latest.json"
APP_NAME="Matador.app"
DEST="/Applications/${APP_NAME}"

step() { printf "\n==> %s\n" "$*"; }
ok()   { printf "    ✓ %s\n" "$*"; }
fail() { printf "\n✗ %s\n" "$*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || fail "curl required"
command -v hdiutil >/dev/null 2>&1 || fail "hdiutil required (macOS only)"

step "Fetching latest manifest"
MANIFEST="$(curl -fsSL "$MANIFEST_URL")"
VERSION="$(printf "%s" "$MANIFEST" | sed -n 's/.*"version" *: *"\([^"]*\)".*/\1/p')"
URL="$(printf "%s" "$MANIFEST" | sed -n 's/.*"url" *: *"\([^"]*\)".*/\1/p')"
[[ -n "$VERSION" && -n "$URL" ]] || fail "Could not parse manifest"
ok "Latest: v${VERSION}"

step "Downloading DMG"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; if [[ -n "${MOUNTED:-}" ]]; then hdiutil detach "$MOUNTED" -quiet || true; fi' EXIT
DMG="$TMP/Matador.dmg"
curl -fsSL "$URL" -o "$DMG"
ok "Downloaded"

step "Mounting DMG"
MOUNTED="$(hdiutil attach "$DMG" -nobrowse -readonly | tail -n1 | awk '{print $3}')"
[[ -n "$MOUNTED" ]] || fail "Mount failed"
ok "Mounted at $MOUNTED"

step "Installing to /Applications"
if [[ -d "$DEST" ]]; then
    rm -rf "$DEST"
fi
cp -R "$MOUNTED/$APP_NAME" "$DEST"
ok "Copied $APP_NAME to /Applications"

step "Removing quarantine"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
ok "Gatekeeper bypass set"

step "Unmounting DMG"
hdiutil detach "$MOUNTED" -quiet || true
MOUNTED=""
ok "Unmounted"

printf "\n✓ Matador v${VERSION} installed.\n"
printf "  Launch from Spotlight or run: open -a Matador\n"
