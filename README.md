# LBrowser

A tiny native macOS browser (Swift + WebKit, ~2 MB) with built-in ad blocking and tab groups,
styled after [ORBIS](https://github.com/999Gabriel/ORBIS): white canvas, black ink, hairlines,
one amber accent, Zen Dots labels and Alumni Sans Pinstripe numerals.

## Download and install

Download **LBrowser-1.1.dmg** from the [latest release](https://github.com/Replace-Big-Tech-Apps/LBrowser/releases/latest).
Requires macOS 15 or later; the release supports Apple Silicon and Intel Macs.
Open the disk image, drag **LBrowser.app** to **Applications**, and eject the disk image.

The app is ad-hoc signed and is not notarized by Apple. If macOS blocks the first launch,
attempt to open the app, then use **System Settings → Privacy & Security → Open Anyway**
if you trust the download.

## Build from source

```bash
./build.sh            # -> build/LBrowser.app
./build.sh --install  # also copies to /Applications
./build.sh --universal --dmg  # -> build/LBrowser-1.1.dmg (Apple Silicon + Intel)
```

Requires Xcode (the SwiftUI macros aren't in the Command Line Tools).
The DMG includes an Applications shortcut and installation instructions; a SHA-256
checksum is written alongside it. To package an existing build, run `./scripts/make-dmg.sh`.

## Features

- **Ad blocking**: WebKit content-blocker rules for ~70 ad/tracker networks plus cosmetic hiding.
  On YouTube, a script strips ads from the player data, hides promo slots, and skips/fast-forwards
  any ad that still gets through. Toggle with the shield button.
- **Private browsing**: press ⇧⌘N or use the Private toggle inside the address bar.
  Private tabs share temporary cookies and website storage, have no password autofill/saving,
  and are excluded from session restore and recently closed tabs. Turning Private off closes
  those tabs and returns to your regular session. Downloads remain in ~/Downloads.
- **Smart address bar**: sites you visit often are completed inline as you type (Enter opens them),
  and a dropdown shows matching history plus live suggestions from your search engine (↑/↓ to pick,
  Esc to close). History stays on your Mac; private tabs are never recorded and fetch no suggestions.
  Turn suggestions off or clear history in Settings.
- **Tab groups**: colored, collapsible, renameable groups in the sidebar. Drag tabs between groups,
  or right-click a tab → Move to Group.
- **Passwords via [Safespace](../Safespace-for-Mac)**: focus a login field to pick a saved login
  (Safespace must be running and unlocked; the dropdown offers to open it otherwise). Logins you
  submit are saved to Safespace automatically, and changed passwords are updated. If the vault is
  locked, LBrowser holds the login and saves it as soon as you unlock. Toggle in Settings.
- ORBIS-style start page with a drifting dot-matrix cloud, live clock and session stats.
- Light / dark / system appearance (Settings), session restore, downloads to ~/Downloads, can be set as default browser.

## Shortcuts

| | |
|---|---|
| ⌘T / ⌘W | New / close tab |
| ⇧⌘N | New private tab / enter private mode |
| ⇧⌘T | Reopen closed tab |
| ⇧⌘G | New tab group |
| ⌘L | Focus address bar |
| ⌘S | Toggle sidebar |
| ⌃Tab / ⌃⇧Tab | Next / previous tab |
| ⌘1…9 | Jump to tab |
| ⌘[ / ⌘] / ⌘R | Back / forward / reload |
| ⌘= / ⌘- / ⌘0 | Zoom |

Design tokens (colors, radii, fonts) live in `Sources/LBrowser/Theme.swift`.
Fonts in `Fonts/` are under the SIL Open Font License (see the OFL files there).
