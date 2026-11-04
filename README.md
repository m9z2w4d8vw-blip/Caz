# Caz

A storage cleaner for iPhones with TrollStore (iOS 17.0 and later builds). Caz measures and
clears the junk iOS doesn't clean up on its own, with a live log of everything it does.

| Category | What it clears |
|---|---|
| System logs | The diagnostic log archive in `/var/db/diagnostics` (refills over a few days) |
| Abandoned downloads | `CFNetworkDownload_*.tmp` files nobody has touched for an hour |
| Crash reports | Crash, hang and analytics reports (optionally keeps SpringBoard and Jetsam ones) |
| System caches | Symbol, Memoji and QuickLook caches, Photos' temporary export copies, sideload staging |
| App caches | Every app's `Library/Caches` and `tmp`, plus in-app browser caches (pick apps in the list) |
| Messages previews | Attachment thumbnails (the attachments themselves are untouched) |
| Maps tiles | The Maps tile cache (off by default; leave off if you use offline maps) |
| Leftover installers | `.ipa`, `.tipa` and `.deb` files left in app inboxes (off by default) |

Caz never touches photos, messages, music, app documents (other than installers in an inbox),
Spotify's cache (it holds downloaded music) or anything outside the paths in `RootHelper/main.c`.

**Trim logs automatically** (Settings) needs a Dopamine jailbreak. It installs a background
job that deletes log files older than a day every 6 hours.

## Build

Push to `main` and GitHub Actions builds it: **Actions → latest "Build Caz" run → Artifacts → Caz**.
The download is a zip with `Caz.tipa` inside. Open `Caz.tipa` with TrollStore to install.

The workflow runs on `macos-15`: XcodeGen generates the project, `xcodebuild` builds the app
unsigned, `clang` builds the root helper, and `scripts/package.sh` signs both with `ldid` using
their entitlements and zips the `.tipa`.

## Why TrollStore

A normal app is sandboxed and can't read or delete system files. Caz ships a small root helper
(`cazhelper`) and starts it as root through TrollStore's persona spawn, the same way other
TrollStore apps do. On iOS 17, TrollStore works on 17.0 only.

## Layout

```
Caz/                 SwiftUI app (model, views, Objective-C spawn bridge, assets)
Config/              Info.plist and the app's entitlements
RootHelper/          cazhelper (C) and its entitlements
scripts/package.sh   signs and packages Caz.tipa
project.yml          XcodeGen spec
```

## Testing the helper on a computer

The helper builds on Linux or macOS in test mode, where every path is prefixed with `CAZ_ROOT`:

```sh
gcc -DCAZ_TEST -std=c11 -D_DEFAULT_SOURCE -O2 -Wall -o cazhelper_test RootHelper/main.c
CAZ_ROOT=/path/to/fake/root ./cazhelper_test scan --keep-sb
```
