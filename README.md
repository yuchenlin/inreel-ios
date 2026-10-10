# Inreel

**Your photo library, as a private, offline reel.**

Inreel turns the Photos library on your iPhone into a full-screen, random, short-video-style
feed. Swipe up through old photos, Live Photos, videos, and screenshots you forgot you had;
keep the ones you love, jot a note on a memory, and set aside the ones you don't need so you
can clear them out in one go. Rediscovering is the point — freeing up space is a side effect.

- No account, no uploads, no ads, no analytics, no subscriptions.
- Everything stays on your device. Media never leaves the system Photos library.

App Store: TODO (link after App Review approval)  
TestFlight (public beta): https://testflight.apple.com/join/rZEVmaq2

## Features

- **Random Feed** — full-screen, vertical paging. Swipe **up** for the next item, **down**
  to go back (session history). Swipe up never deletes anything.
- **Tracks** — Mixed, Photos, Videos, or Screenshots.
- **Like / star** — double-tap to like. Likes go to the system **Favorites** album and show
  up in the **Liked** tab (grid, filter by photos/videos, full-screen viewer).
- **Basket** — swipe left (or tap trash) to set items aside, with undo. Review the basket and
  move everything to *Recently Deleted* in one batch; deletion always goes through the
  system confirmation dialog and is recoverable for 30 days.
- **Notes** — write private notes on any photo or video; browse them in the Notes tab and
  export them as JSON or plain text.
- **Cooldown** — once you've seen something in the Feed, it won't come back for
  30 / 90 / 180 (default) / 365 days, or until you've seen everything once. Reset any time.
- **Video** — autoplay, scrubbable progress bar, **long-press for 2× speed**.
- **Global mute** — mute once and every video stays muted (next, back, new items, even after
  relaunch) until you unmute, flip "Videos start with sound" in Settings, or press a
  hardware volume key.
- **Details overlay** — optional capture date (exact or relative), time, location, camera,
  albums, and estimated file size, all read on-device from PhotoKit / EXIF.
- **Stats** — a "done list" of what you've seen, liked, deleted, and written.
- **Limited Photos access** handled honestly — Inreel tells you when it can only see a
  selection instead of pretending to browse your whole library.
- Localized: English, Simplified & Traditional Chinese, Japanese, Korean, Spanish, French,
  German, Brazilian Portuguese.

Requires iOS 17 or later (iPhone).

## Privacy

Inreel runs entirely on your device. It has no servers, no accounts, no analytics or
advertising SDKs, and collects no data (`PrivacyInfo.xcprivacy` declares no collected data
types and no tracking). Likes, notes, seen history, and the basket are stored locally with
SwiftData / UserDefaults. If you use iCloud Photos, Apple's PhotoKit may download originals
from iCloud to display them — that traffic is between your device and Apple, not Inreel.

Privacy policy: https://inreel-privacy.vercel.app/

## Building

Requirements: Xcode 27+ (the project targets iOS 17.0), and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
git clone https://github.com/yuchenlin/inreel-ios.git
cd inreel-ios
xcodegen generate        # creates Inreel.xcodeproj (not committed; project.yml is the source of truth)

# Simulator — no signing setup needed
xcodebuild -project Inreel.xcodeproj -scheme Inreel \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO build

# Unit tests
xcodebuild -project Inreel.xcodeproj -scheme Inreel \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

To run on your own iPhone, configure signing with your own team and bundle id:

```bash
cp Config/Signing.xcconfig.example Config/Signing.xcconfig   # gitignored
# set DEVELOPMENT_TEAM and INREEL_BUNDLE_ID, then:
xcodegen generate && open Inreel.xcodeproj
```

See [docs/SIGNING.md](docs/SIGNING.md) for details and the App Store archive script.

## Project layout

```
Inreel/
  App/          app entry, root tab view
  Feed/         random feed, paging, photo/video cards, player pool, mute state
  Liked/        liked grid + viewer
  Basket/       set-aside basket + batch delete via PhotoKit
  Notes/        per-asset notes
  Settings/     settings + stats
  Onboarding/   onboarding + photo-access gate
  Data/         PhotoKit access, SwiftData models, stores
  Design/ Motion/  theme, haptics, animation helpers
InreelTests/    unit tests
project.yml     XcodeGen spec — run `xcodegen generate` to create Inreel.xcodeproj
Config/         xcconfig signing setup (Signing.xcconfig is yours, gitignored)
scripts/        App Store archive helper
```

## Contributing

Issues and pull requests are welcome. By contributing you agree that your contributions are
licensed under GPL-3.0. Please keep the app fully offline: no network features, accounts,
analytics, or ads.

## License

Source code: [GNU General Public License v3.0](LICENSE).

**Name and icon are not covered by the GPL.** "Inreel" and the Inreel app icon are not
licensed for reuse. If you distribute your own build, you must rebrand it with a different
name, icon, and bundle identifier. See [NOTICE.md](NOTICE.md).
