#!/usr/bin/env bash
# Archive + export an App Store IPA with manual Distribution signing (maintainers).
#
# Team / bundle id / profile are resolved in this order (first non-empty wins):
#   1. environment: INREEL_DEVELOPMENT_TEAM, INREEL_BUNDLE_ID, INREEL_PROFILE_NAME
#   2. Config/Signing.xcconfig (gitignored; copy from Config/Signing.xcconfig.example)
#   3. defaults: bundle id app.inreel.ios, profile "Inreel App Store"
# Never commit a real team id into this script or any tracked file.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SIGNING_XCCONFIG="$ROOT/Config/Signing.xcconfig"

# Read `KEY = value` from Signing.xcconfig (ignores // comments and blank values).
xcconfig_value() {
  local key="$1"
  [[ -f "$SIGNING_XCCONFIG" ]] || return 0
  sed -n -E "s@^[[:space:]]*${key}[[:space:]]*=[[:space:]]*([^/]*[^/[:space:]])?[[:space:]]*(//.*)?\$@\\1@p" \
    "$SIGNING_XCCONFIG" | tail -n 1
}

TEAM="${INREEL_DEVELOPMENT_TEAM:-$(xcconfig_value DEVELOPMENT_TEAM)}"
BUNDLE_ID="${INREEL_BUNDLE_ID:-$(xcconfig_value INREEL_BUNDLE_ID)}"
BUNDLE_ID="${BUNDLE_ID:-app.inreel.ios}"
PROFILE_NAME="${INREEL_PROFILE_NAME:-$(xcconfig_value INREEL_PROFILE_NAME)}"
PROFILE_NAME="${PROFILE_NAME:-Inreel App Store}"

if [[ -z "$TEAM" ]]; then
  echo "ERROR: no Development Team. Set INREEL_DEVELOPMENT_TEAM or DEVELOPMENT_TEAM in" >&2
  echo "       Config/Signing.xcconfig (see Config/Signing.xcconfig.example)." >&2
  exit 1
fi

XCODEGEN="${XCODEGEN:-$(command -v xcodegen || true)}"
if [[ -z "$XCODEGEN" ]]; then
  echo "ERROR: xcodegen not found (brew install xcodegen, or set XCODEGEN=/path/to/xcodegen)." >&2
  exit 1
fi

OUT="${INREEL_ARCHIVE_DIR:-$ROOT/build/archive}"
mkdir -p "$OUT"

"$XCODEGEN" generate

ARCHIVE="$OUT/Inreel.xcarchive"
DERIVED="$OUT/DerivedData"

echo "Archiving $BUNDLE_ID to $ARCHIVE (manual Distribution, profile: $PROFILE_NAME)…"
xcodebuild \
  -project Inreel.xcodeproj \
  -scheme Inreel \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$DERIVED" \
  DEVELOPMENT_TEAM="$TEAM" \
  INREEL_BUNDLE_ID="$BUNDLE_ID" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY='Apple Distribution' \
  "PROVISIONING_PROFILE_SPECIFIER=$PROFILE_NAME" \
  archive \
  | tee "$OUT/archive.log"

EXPORT_OPTS="${INREEL_EXPORT_OPTIONS:-}"
if [[ -z "$EXPORT_OPTS" ]]; then
  EXPORT_OPTS="$OUT/ExportOptions.plist"
  cat > "$EXPORT_OPTS" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>export</string>
	<key>teamID</key>
	<string>${TEAM}</string>
	<key>signingStyle</key>
	<string>manual</string>
	<key>provisioningProfiles</key>
	<dict>
		<key>${BUNDLE_ID}</key>
		<string>${PROFILE_NAME}</string>
	</dict>
	<key>signingCertificate</key>
	<string>Apple Distribution</string>
	<key>uploadSymbols</key>
	<true/>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
</dict>
</plist>
PLIST
fi

echo "Exporting IPA …"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$OUT/export" \
  -exportOptionsPlist "$EXPORT_OPTS" \
  | tee "$OUT/export.log"

echo "Done. IPA under $OUT/export/"
ls -la "$OUT/export/" || true
