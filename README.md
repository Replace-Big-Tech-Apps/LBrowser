# LBrowser

A tiny native macOS browser (Swift + WebKit, ~2 MB) with built-in ad blocking and tab groups,
styled after [ORBIS](https://github.com/999Gabriel/ORBIS): white canvas, black ink, hairlines,
one amber accent, Zen Dots labels and Alumni Sans Pinstripe numerals.

## Download and install

Download **LBrowser-1.2.dmg** from the [latest release](https://github.com/Replace-Big-Tech-Apps/LBrowser/releases/latest).
Requires macOS 15 or later; the release supports Apple Silicon and Intel Macs.
Open the disk image, drag **LBrowser.app** to **Applications**, and eject the disk image.

The app is ad-hoc signed and is not notarized by Apple. If macOS blocks the first launch,
attempt to open the app, then use **System Settings → Privacy & Security → Open Anyway**
if you trust the download.

## Build from source

```bash
./build.sh            # -> build/LBrowser.app
./build.sh --install  # also copies to /Applications
./build.sh --universal --dmg  # -> build/LBrowser-1.2.dmg (Apple Silicon + Intel)
```

Requires Xcode (the SwiftUI macros aren't in the Command Line Tools).
The DMG includes an Applications shortcut and installation instructions; a SHA-256
checksum is written alongside it. To package an existing build, run `./scripts/make-dmg.sh`.

## Features

- **Ad blocking**: WebKit content-blocker rules for ~70 ad/tracker networks plus cosmetic hiding.
  On YouTube, a script strips ads from the player data, hides promo slots, and skips/fast-forwards
  any ad that still gets through. Toggle with the shield button.
- **Smart address bar**: sites you visit often are completed inline as you type (Enter opens them),
  and a dropdown shows matching history plus live suggestions from your search engine (↑/↓ to pick,
  Esc to close). History stays on your Mac; private tabs are never recorded and fetch no suggestions.
- **Tab groups, Safari-style**: each group is its own set of tabs. Pick a group in the sidebar's
  group list and the tab list shows only that group's tabs; new tabs open in it, and switching back
  returns to the tab you last used there. Drag a tab onto a group (or right-click → Move to Tab Group).
- **Pinned tabs** (right-click → Pin Tab) stay at the top of the sidebar in every group.
  Tabs playing sound show a speaker — click it to mute. **Search Tabs** (⇧⌘K) finds any open tab.
  ⇧⌘T reopens closed tabs in their group with their back/forward history.
- **Multiple windows** (⌘N, or right-click a tab → Move to New Window); all windows come back on relaunch.
- **Profiles** (Settings → Profiles): separate cookies, logins, history, bookmarks, extensions and
  windows, e.g. Personal and Work. File → New Window in Profile.
- **Bookmarks**: ☆ in the address bar or ⌘D adds a favorite; a favorites bar (⇧⌘B) and the start page
  show them, the Bookmarks menu lists all. Import from Safari, Chrome, Brave, Edge, Arc, Vivaldi,
  Firefox or an HTML export; export as HTML.
- **Find on page** (⌘F, ⌘G / ⇧⌘G), **Print** (⌘P), **Export as PDF**, **Save Page As** web archive
  (⌥⌘S), **Share** button and **Copy Link** (⇧⌘C).
- **Reader** (⇧⌘R) for articles, with text size and serif/sans options. **Translate** pages in
  other languages on-device with Apple's Translation. **Picture in Picture** for videos (View menu).
- **Website settings**: click the lock (or "Not Secure" on plain-HTTP pages) for camera, microphone, location and
  JavaScript per site and to remove that site's cookies. Settings → Websites manages saved choices and
  all website data.
- **AutoFill** (⇧⌘A): your address and payment cards, stored in the Keychain; cards need Touch ID or
  your password, security codes are never saved.
- **Downloads panel** with progress, speed and time left; pick the download folder or ask every time.
- **Extensions** (macOS 15.4+): add WebExtensions (Safari/Chrome/Firefox format) as an unpacked folder or
  .zip in Settings → Extensions; their toolbar buttons and popups appear next to the downloads button.
- **iCloud sync** (Settings → Sync): bookmarks and history sync between your Macs through iCloud Drive.
- **Developer tools**: Develop menu → Developer Tools adds Inspect Element.
- **Private browsing**: press ⇧⌘N or use the Private toggle. Private tabs share temporary cookies and
  website storage, have no password autofill/saving, and are excluded from history, session restore and
  recently closed tabs. Turning Private off closes those tabs and returns to your regular session.
- **Passwords via [Safespace](../Safespace-for-Mac)**: focus a login field to pick a saved login
  (Safespace must be running and unlocked). Logins you submit are saved to Safespace automatically.
- ORBIS-style start page with a drifting dot-matrix cloud, live clock and session stats.
- Light / dark / system appearance, session restore, can be set as default browser.

## Shortcuts

| | |
|---|---|
| ⌘T / ⌘W | New / close tab |
| ⇧⌘N | New private tab / enter private mode |
| ⇧⌘T | Reopen closed tab |
| ⌃⌘N | New tab group |
| ⌘N | New window |
| ⌘L | Focus address bar |
| ⌘F / ⌘G / ⇧⌘G | Find / next / previous |
| ⌘D / ⇧⌘B | Add bookmark / favorites bar |
| ⇧⌘R | Reader |
| ⇧⌘A | AutoFill form |
| ⇧⌘K | Search tabs |
| ⌘P | Print |
| ⌘S | Toggle sidebar |
| ⌃Tab / ⌃⇧Tab | Next / previous tab |
| ⌥⌘↓ / ⌥⌘↑ | Next / previous tab group |
| ⌘1…9 | Jump to tab |
| ⌘[ / ⌘] / ⌘R | Back / forward / reload |
| ⌘= / ⌘- / ⌘0 | Zoom |

Design tokens (colors, radii, fonts) live in `Sources/LBrowser/Theme.swift`.
Fonts in `Fonts/` are under the SIL Open Font License (see the OFL files there).
