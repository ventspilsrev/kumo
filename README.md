# Kumo

A manga reader for an old iPad: built for the **iPad Air 2 on iOS 15**, installed with
**TrollStore**, and built entirely on GitHub (no Mac needed).

Kumo runs **Paperback 0.8 extensions** that you add yourself from repository addresses, and has
**MangaDex built in** through the official MangaDex API.

> **Status: early and personal.** Version 0.6.0. It is developed for one device and tested on that
> device only. Parts of it have never been run (see [What works](#what-works-and-what-does-not)).

## Features

- **Library** with unread counts, a "Continue reading" banner that reopens your chapter and page,
  recent history and a few reading numbers.
- **Browse** manga from your sources: suggestions based on what you saved and read, the source's
  own rows, search, one-tap genres, and a filter page where each tag can be included or excluded.
- **Reader** that reads right to left like a printed book:
  - two pages side by side in landscape, one page in portrait
  - double-page scans are shown on their own
  - tap the left or right third to turn the page, the middle to show the bar
  - pinch or double-tap to zoom
  - the position is saved on every page turn
- **Sources**
  - MangaDex is built in and cannot be removed.
  - Other sources come from Paperback 0.8 repositories you add in Settings. Kumo ships none.
  - Each source runs in its own sandbox.
- **Site verification**: when a site asks you to prove you are human, it opens in a web view;
  you pass the check and Kumo takes over the cookies.
- **Log screen** (Settings → Log) for when something fails, since there is no debugger on the iPad.

## What works and what does not

| Area | State |
|---|---|
| MangaKatana, MangaFox (netsky repository) | Used on the iPad |
| Library, history, saved position, two-page reader | Used on the iPad |
| MangaDex (built in) | Passes the PC test harness; not yet confirmed on the iPad |
| Site verification web view, saved cookies | Compiles; never run |
| ComixTo page un-scrambling | Compiles; never run |
| Source settings menus | Not built |
| Backup/export, downloads, long-strip (webtoon) mode, tap-zone settings | Not built |

Not possible with a TrollStore install on iOS 15: push notifications, iCloud sync, and dependable
background update checks. Updates are checked when you open the app.

Some sources are slow by design. MangaFox fetches each page address separately, so a chapter can
take half a minute to open.

## Install

You need an iPad or iPhone on iOS 15 with [TrollStore](https://github.com/opa334/TrollStore)
already installed.

1. On the device, open the [Releases page](https://github.com/ventspilsrev/kumo/releases) in Safari.
2. Under the newest build, tap **Kumo.ipa** and choose **Download**.
3. Open the **Files** app, go to **Downloads**, press and hold **Kumo.ipa**, tap **Share**, then
   **TrollStore**.
4. Tap **Install**.

Installing a newer build the same way updates the app and keeps your library.

## Adding sources

MangaDex works straight away. To add more:

1. Open **Settings → Sources and repositories → Add repository**.
2. Enter the address of a Paperback **0.8** repository (it must start with `https://`).
3. Tap **Install** next to a source, then pick it with the source button at the top of **Browse**.

Sources are programs written by other people. Only add repositories you trust.

## Privacy and security

- No analytics, no telemetry, no accounts. Nothing leaves the device except the requests your
  sources make to their own sites when you browse or read.
- Extensions are treated as untrusted code. Each one runs in its own JavaScript context with no
  access to files, to other sources, or to the app's data. Its only way out is a small bridge:
  HTTPS requests, its own cookies, its own settings, timers and logging.
- HTTPS only. Plain `http://` addresses and redirects are upgraded to `https://`, never used as is.
- Each source has its own cookie jar, saved in a private file inside the app.
- An installed extension may do its own reporting. ComixTo, for example, sends request timings to
  its author. That is the extension's behaviour, not Kumo's.

## How it works

```
App/
  Core/      extension runtime, database, library, images, suggestions
  UI/        screens (SwiftUI) and the reader (UIKit)
runtime/
  prelude.js   builds the `App` object that Paperback 0.8 extensions expect
  mangadex.js  the built-in MangaDex source
harness/
  run.js       runs a real extension on a PC, end to end
tools/
  make_icon.py draws the app icon
```

- **Runtime.** `runtime/prelude.js` is loaded into an empty JavaScriptCore context before the
  extension. The same file is used by the PC harness, so what passes there is what the iPad runs.
  The API shape comes from the public `@paperback/types` 0.8.7 declarations and from reading real
  extension bundles. No Paperback code is included.
- **Data.** The library, history and reading positions live in SQLite with versioned migrations,
  so an update never wipes them.
- **Images.** Pages are downloaded through the source (so its headers and un-scrambling apply),
  stored on disk, and decoded straight to display size. The disk cache is capped at 500 MB.
- **Memory.** The device has 2 GB of RAM. The reader keeps only the visible spread and its two
  neighbours alive.

## Building

Every push to `main` is built by GitHub Actions and published as a release:

1. `xcodegen generate` creates the Xcode project from `project.yml`.
2. `xcodebuild` compiles with Xcode 16.4 for iOS 15.0, without Apple code signing.
3. `ldid -S` fake-signs the app so TrollStore accepts it.
4. The app is zipped into `Kumo.ipa`.

See [BUILDING.md](BUILDING.md) for the step-by-step version.

## Testing an extension on a PC

Requires [Node.js](https://nodejs.org).

```
node harness/run.js https://thenetsky.github.io/netskys-extensions/0.8 MangaKatana one piece
node harness/run.js --file runtime/mangadex.js MangaDex berserk
```

The harness loads the extension in an empty context and runs home, filters, search, details,
chapters, pages and page images against the live site.

## Project documents

- [docs/BRIEF.md](docs/BRIEF.md): the original project brief.
- [NOTES.md](NOTES.md): decisions, verified facts, known problems and the next step.
- [BUILDING.md](BUILDING.md): how builds and installs work.

## Notes

- Kumo is an independent project. It is not affiliated with Paperback, MangaDex, or any extension
  author or site.
- Kumo contains no manga and no third-party sources. What you read comes from the sources you
  choose, and you are responsible for how you use them.
- The repository has no licence file yet, so all rights are reserved by default.
