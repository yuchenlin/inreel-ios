# Signing

Inreel never commits an Apple Developer Team ID, certificates, provisioning
profiles, or keys. Everything personal lives in a gitignored xcconfig.

## Simulator

No signing setup needed:

```bash
xcodegen generate
xcodebuild -project Inreel.xcodeproj -scheme Inreel \
  -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO build
```

## Your own device

```bash
cp Config/Signing.xcconfig.example Config/Signing.xcconfig
# edit: DEVELOPMENT_TEAM = <your team id>, INREEL_BUNDLE_ID = <a bundle id you own>
xcodegen generate
open Inreel.xcodeproj   # pick your iPhone and Run (automatic signing)
```

How it fits together:

- `project.yml` attaches `Config/Base.xcconfig` to both targets.
- `Config/Base.xcconfig` sets `DEVELOPMENT_TEAM = $(INREEL_DEVELOPMENT_TEAM)` (empty unless
  you export that env var) and `INREEL_BUNDLE_ID = app.inreel.ios`, then does
  `#include? "Signing.xcconfig"` so your local file overrides both.
- `PRODUCT_BUNDLE_IDENTIFIER` is `$(INREEL_BUNDLE_ID)` (tests: `$(INREEL_BUNDLE_ID).tests`).

Forks distributing their own build must use their own bundle id **and** their own app
name and icon (see NOTICE).

## App Store archive (maintainers)

```bash
# team / bundle id / profile come from env or Config/Signing.xcconfig
INREEL_PROFILE_NAME="My App Store Profile" bash scripts/archive-appstore.sh
```

Output goes to `build/archive/` (gitignored). The script uses manual signing with an
"Apple Distribution" certificate installed on your Mac and a matching App Store provisioning profile.
