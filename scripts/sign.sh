#!/bin/bash
# scripts/sign.sh — codesign + notarize fusion-event binary for enterprise distribution.
# O1/release-engineering: macOS Gatekeeper blocks unsigned binaries on cross-machine deploy.
#
# EXTERNAL PREREQS (user must provide, cannot self-acquire):
#   - Apple Developer ID Application certificate installed in Keychain (codesign will find by name)
#   - App-specific password for notarytool (create at appleid.apple.com), stored in keychain:
#       xcrun notarytool store-credentials "fusion-event-notary" \
#         --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-pw"
#   - For ES entitlement (optional, blocked on Apple approval): com.apple.developer.endpoint-security.client
#
# Usage:
#   ./scripts/sign.sh           # build release + codesign + notarize + staple
#   ./scripts/sign.sh sign-only # skip notarize, just codesign existing release binary
#
# Env:
#   DEVELOPER_ID_NAME  — Keychain cert name (default "Developer ID Application: Your Name (TEAMID)")
#   NOTARY_PROFILE     — keychain profile name from notarytool store-credentials (default "fusion-event-notary")
#   ENTITLEMENTS        — path to entitlements plist (default scripts/fusion-event.entitlements)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN="$ROOT/.build/release/fusion-event"
ENTITLEMENTS="${ENTITLEMENTS:-$SCRIPT_DIR/fusion-event.entitlements}"
DEVELOPER_ID_NAME="${DEVELOPER_ID_NAME:-Developer ID Application: REPLACE_ME}"
NOTARY_PROFILE="${NOTARY_PROFILE:-fusion-event-notary}"
MODE="${1:-full}"

log() { echo "[sign] $*"; }
die() { echo "[sign][ERROR] $*" >&2; exit 1; }

if [[ ! -f "$ENTITLEMENTS" ]]; then
    die "entitlements missing: $ENTITLEMENTS (run scripts/make-entitlements.sh or create it)"
fi

# Step 1: build release if binary missing
if [[ ! -x "$BIN" ]]; then
    log "release binary missing, building..."
    (cd "$ROOT" && swift build -c release)
fi
[[ -x "$BIN" ]] || die "release build failed"

# Step 2: codesign
log "codesign $BIN with $DEVELOPER_ID_NAME"
codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$DEVELOPER_ID_NAME" \
    "$BIN"
log "verify signature"
codesign --verify --strict --verbose=2 "$BIN" 2>&1 | head -5
spctl --assess --type execute --verbose "$BIN" 2>&1 || log "WARN: spctl assess needs notarization+staple to pass"

if [[ "$MODE" == "sign-only" ]]; then
    log "sign-only mode, skipping notarization"
    exit 0
fi

# Step 3: notarize (zip + submit + wait)
ZIP="/tmp/fusion-event-$(date +%s).zip"
log "zip for notarization: $ZIP"
ditto -c -k --keepParent "$BIN" "$ZIP"

log "submit to notarytool profile=$NOTARY_PROFILE"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait || die "notarization failed — check Apple creds / profile"
log "notarization accepted"

# Step 4: staple
log "staple ticket"
xcrun stapler staple "$BIN"
xcrun stapler validate "$BIN"
rm -f "$ZIP"

log "done: signed + notarized + stapled: $BIN"
log "distribute: copy $BIN to target machine, Gatekeeper will accept"
