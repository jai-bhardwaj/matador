#!/usr/bin/env bash
# Build, package, and publish a new Matador release to GitHub Releases.
#
# Mirrors the k8secret release pipeline: ad-hoc signed .app, DMG, GitHub
# release upload via gh CLI, and a latest.json manifest commit so the
# in-app updater can see it.
#
# Prerequisites (one-time):
#   sudo xcode-select -switch /Applications/Xcode.app/Contents/Developer
#   sudo xcodebuild -license accept
#   brew install gh jq
#   gh auth login
#
# Usage:
#   ./release/publish.sh <version> [release notes]
#   ./release/publish.sh 0.1.0
#   ./release/publish.sh 0.1.1 "Faster queue scan"

set -euo pipefail

VERSION="${1:?Usage: ./publish.sh <version> [release notes]}"
NOTES="${2:-Matador v${VERSION}}"
TAG="v${VERSION}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$ROOT_DIR/build"
APP_BUNDLE="$BUILD_DIR/Matador.app"
DMG_PATH="$ROOT_DIR/dmg/Matador-${VERSION}.dmg"
PLIST_TEMPLATE="$SCRIPT_DIR/Info.plist.template"
ICON_PATH="$SCRIPT_DIR/AppIcon.icns"

step() { printf "\n==> %s\n" "$*"; }
ok()   { printf "    ✓ %s\n" "$*"; }
fail() { printf "\n✗ %s\n" "$*" >&2; exit 1; }

step "Preflight"

command -v gh >/dev/null 2>&1   || fail "gh CLI not found. brew install gh"
command -v jq >/dev/null 2>&1   || fail "jq not found. brew install jq"
command -v swift >/dev/null 2>&1 || fail "swift not found in PATH"
gh auth status >/dev/null 2>&1  || fail "gh CLI not authenticated. gh auth login"

XCODE_DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
case "$XCODE_DEV_DIR" in
    *Xcode.app/Contents/Developer*) ok "Xcode active at $XCODE_DEV_DIR" ;;
    *) fail "Xcode (full app) is not active. Currently using: ${XCODE_DEV_DIR:-none}
   Install Xcode from the App Store, then:
     sudo xcode-select -switch /Applications/Xcode.app/Contents/Developer
     sudo xcodebuild -license accept" ;;
esac

PLATFORM_PATH="$(xcrun --sdk macosx --show-sdk-platform-path 2>/dev/null || true)"
[[ -n "$PLATFORM_PATH" ]] || fail "xcrun can't resolve macosx SDK platform path."
ok "macOS SDK: $(xcrun --sdk macosx --show-sdk-version)"

[[ -f "$PLIST_TEMPLATE" ]] || fail "Missing $PLIST_TEMPLATE"

if git -C "$ROOT_DIR" rev-parse "$TAG" >/dev/null 2>&1; then
    fail "Tag $TAG already exists. Bump the version."
fi

if [[ -n "$(git -C "$ROOT_DIR" status --porcelain 2>/dev/null || true)" ]]; then
    printf "    ⚠ Working tree is dirty. Continue anyway? [y/N] "
    read -r REPLY
    [[ "$REPLY" =~ ^[Yy]$ ]] || exit 1
fi

ok "All prerequisites met"

step "Bumping AppConstants.swift to $VERSION"
CONSTANTS="$ROOT_DIR/Sources/Matador/AppConstants.swift"
sed -i '' "s/static let version = \".*\"/static let version = \"${VERSION}\"/" "$CONSTANTS"
ok "AppConstants.swift updated"

step "Compiling release binary"
cd "$ROOT_DIR"
swift build -c release
ARCH="$(uname -m)"
BINARY="$ROOT_DIR/.build/${ARCH}-apple-macosx/release/Matador"
[[ -x "$BINARY" ]] || fail "Built binary not found at $BINARY"
ok "Compiled: $BINARY"

step "Building .app bundle"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

sed "s/__VERSION__/${VERSION}/g" "$PLIST_TEMPLATE" > "$APP_BUNDLE/Contents/Info.plist"
ok "Info.plist rendered"

cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/matador"
chmod +x "$APP_BUNDLE/Contents/MacOS/matador"
ok "Binary in place"

if [[ -f "$ICON_PATH" ]]; then
    cp "$ICON_PATH" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    ok "Icon embedded"
else
    printf "    (no AppIcon.icns — add one at release/AppIcon.icns to embed)\n"
fi

xattr -cr "$APP_BUNDLE"
codesign --force --deep --sign - "$APP_BUNDLE"
ok "Ad-hoc signed"

step "Creating DMG"
mkdir -p "$ROOT_DIR/dmg"
rm -f "$DMG_PATH"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP_BUNDLE" "$STAGING/Matador.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Matador" -fs HFS+ -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH" >/dev/null
ok "Created $DMG_PATH"

SHA="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
SIZE_HUMAN="$(du -h "$DMG_PATH" | awk '{print $1}')"
ok "sha256: $SHA"
ok "size:   $SIZE_HUMAN"

step "Tagging $TAG"
cd "$ROOT_DIR"
git add "$CONSTANTS"
if ! git diff --cached --quiet; then
    git commit -m "release: bump to ${VERSION}"
    ok "Committed version bump"
fi
git tag "$TAG"
ok "Tag $TAG created"

git push >/dev/null
git push origin "$TAG" >/dev/null
ok "Pushed commits + tag $TAG"

step "Creating GitHub release"
gh release create "$TAG" "$DMG_PATH" \
    --title "Matador ${VERSION}" \
    --notes "${NOTES}

**sha256:** \`${SHA}\`
**size:**   ${SIZE_HUMAN}
**macOS:**  14.0+

### Install

\`\`\`bash
curl -fsSL https://raw.githubusercontent.com/jai-bhardwaj/matador/main/release/install.sh | bash
\`\`\`

Or download the DMG directly. The app is ad-hoc signed — the installer strips the quarantine bit so Gatekeeper won't prompt." \
    >/dev/null

ok "Release v${VERSION} published"

step "Updating release manifest"
TODAY="$(date +%Y-%m-%d)"
DMG_URL="https://github.com/jai-bhardwaj/matador/releases/download/${TAG}/$(basename "$DMG_PATH")"
jq -n \
    --arg version "$VERSION" \
    --arg url "$DMG_URL" \
    --arg notes "$NOTES" \
    --arg date "$TODAY" \
    '{
        version: $version,
        url: $url,
        notes: $notes,
        minOS: "14.0",
        date: $date
    }' > "$SCRIPT_DIR/latest.json"

git add "$SCRIPT_DIR/latest.json"
git commit -m "release: ${VERSION} manifest" >/dev/null
ok "Manifest committed"

step "Pushing manifest"
git push >/dev/null
ok "Manifest live on main"

printf "\n✓ Matador v${VERSION} live.\n"
printf "  Release: https://github.com/jai-bhardwaj/matador/releases/tag/${TAG}\n"
printf "  DMG:     %s\n" "$DMG_URL"
printf "  Try it:  curl -fsSL https://raw.githubusercontent.com/jai-bhardwaj/matador/main/release/install.sh | bash\n"
