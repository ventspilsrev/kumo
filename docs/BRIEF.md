# Project brief: custom manga reader for iPad Air 2 (iOS 15.8.7, TrollStore)

Paste this whole brief as the first message. Read all of it before writing code.

## 0. About me and how to work with me

- I'm Rev. I'm a Python beginner and have never used GitHub or Xcode. Explain every step I must do by hand as exact taps/clicks, and keep explanations plain.
- Be direct. If something I ask for is a bad idea or won't work, say so and propose an alternative. Don't flatter me and don't hide uncertainty.
- Never say something works until it has actually been run. Separate "verified by running it" from "should work but untested".
- I can't debug on the iPad. Anything that fails on the device must show a readable error screen in the app, and I will send you screenshots of it.

## 1. Goal

Build a native iOS app (IPA) that replaces Paperback for me. Paperback's UI is ugly, filtering is hard, it has no suggestions page, and my installed version is outdated, so I need constant workarounds. The new app must:

1. Run the same kind of **Paperback 0.8 extensions** I use now, loaded from repository URLs I add myself.
2. Have a clean modern UI, good filtering, and a "Suggested for you" page.
3. Handle Cloudflare the same way Paperback does (section 5).

The app ships with **no sources bundled**. The user adds repository URLs, like Paperback does.

## 2. Target device and constraints (hard)

These are the limits of my device. Design around them from the start. Items marked **(verify)** are from my own knowledge and may be wrong, so check them against Apple's documentation and tell me what you find before relying on them.

### 2.1 Hardware
- **Device:** iPad Air 2 (9.7"), Apple A8X (3 cores, about 1.5 GHz), arm64 (not arm64e), PowerVR GXA6850 GPU. Old and slow by today's standards, and it throttles when hot.
- **RAM:** 2 GB total, shared with the OS and everything else. iOS kills apps that use too much memory without warning. My estimate: aim to stay **under about 300-400 MB** in normal use and test with large chapters **(verify the practical limit)**.
- **Screen:** 2048x1536 at 2x scale (1024x768 points), 60 Hz only (no ProMotion), no Apple Pencil support. Touch ID home button, no Face ID.
- **Storage:** unknown capacity (16/32/64/128 GB models exist). Don't fill it. Ask me how much is free before designing downloads, and add a visible storage-usage screen.
- **Network:** Wi-Fi only (the model may or may not have cellular). Assume slow or unstable connections: use timeouts, retries and cancellation.
- **GPU texture limits:** a single image larger than about 8192 px on one side may fail to render **(verify)**. Webtoon/long-strip pages are often very tall (for example 800x20000 px). A decoded image costs width x height x 4 bytes of RAM, so one tall page can be 60-120 MB. **Tile or downsample tall images** and never decode full-size images for thumbnails or covers.

### 2.2 Operating system
- **iOS 15.8.7 is the last version this device can run.** It never gets newer APIs. Deployment target: **iOS 15.0**. Use only APIs available on iOS 15.
- **SwiftUI on iOS 15 is limited.** Not available: `NavigationStack`, `NavigationSplitView`, `Grid`, Swift Charts, `.presentationDetents`, `.scrollContentBackground`, `.scrollIndicators`, many newer modifiers and SF Symbols **(verify each one you use)**. Use `NavigationView`, `LazyVGrid`, UIKit and SF Symbols that exist in iOS 15. For the reader and large image lists, **prefer UIKit** (`UICollectionView` / `UIScrollView`) over SwiftUI for performance and control.
- **Image formats:** WebP is supported (iOS 14+). **AVIF and JPEG XL are not natively supported on iOS 15** **(verify)**. Some sites serve AVIF, so add a fallback: request another format if the source allows it, or bundle an AVIF decoder (check that it supports iOS 15 and its memory use).
- **WebKit is Safari 15.** Cloudflare and some sites may behave differently on this old WebKit. The web view used for the Cloudflare step must use the same engine and User-Agent as the app's own requests (see section 5).
- **JavaScript:** `JavaScriptCore` works. Assume **no JIT** (JavaScript runs in the slower interpreter). Some JIT-related entitlements are reported to be locked on iOS 15 by PPL, but PPL only exists on A12 and newer chips, so it may behave differently on my A8X **(verify)**. Do not depend on JIT either way. Keep the bridge efficient, avoid huge JS objects and avoid running heavy parsing on the main thread.
- **TLS/certificates:** the system trust store on iOS 15 is older. Some sites with newer certificate chains may fail TLS validation **(verify)**. Surface TLS errors clearly in the log screen. Do **not** disable certificate validation globally to fix them.
- **Swift/async:** Swift concurrency (`async/await`) can back-deploy to iOS 15 with a recent Xcode, but check each language feature and library you use.
- **Third-party libraries:** many libraries now require iOS 16/17+. Before adding any dependency, **check its minimum deployment target** and its memory use. Prefer few dependencies.
- **Multitasking:** Split View and Slide Over exist on this iPad, Stage Manager does not. Layouts must handle narrow widths (Slide Over) without breaking.
- **Performance:** keep animations cheap, avoid blur/shadow-heavy views over scrolling lists, use lazy loading and cell reuse, and decode images off the main thread.

### 2.3 Install method (TrollStore) limits
- Installed through **TrollStore** (permanent install of an unsigned/fake-signed IPA). There is no App Store, no TestFlight, no Apple ID signing and no developer account.
- **Updating = reinstalling the new IPA in TrollStore.** Keep the **bundle identifier constant** so my library and settings survive updates. Never change it casually. Also keep a backup/export feature, since reinstalling the wrong way can wipe data.
- **No push notifications, iCloud, or App Store features** unless you can show they work under TrollStore on iOS 15 **(verify)**. Background refresh/update checks are likely unreliable. Say clearly what will not work instead of pretending.
- No debugger or Xcode connection. All debugging is via an in-app log/error screen and my screenshots.

### 2.4 Build-side limits (no Mac)
- Builds run on a **GitHub Actions macOS runner**. Check that the Xcode version available there can still target iOS 15.0 and the SDK you use. If a newer Xcode drops iOS 15 deployment targets or removes needed tools, tell me and pick a runner image/Xcode version that works.
- `swift` packages and build settings must all use `IPHONEOS_DEPLOYMENT_TARGET = 15.0`.
- I cannot test builds locally. Keep the CI workflow simple and the build log readable.

### 2.5 What this means
- **Memory and image handling are the top risks.** Downsample, tile, cache to disk, cancel off-screen loads and handle memory warnings. Test with a long-strip webtoon chapter and a 200-page chapter.
- The app must be **iPad-first** (landscape and portrait, split layouts). iPhone support is optional.
- Before writing code, give me a short list of the limits above that you **verified**, ones that turned out **wrong**, and any **extra limits you found**.

## 3. Build pipeline (I have no Mac)

- I have no Mac and no Xcode. Build with a **GitHub Actions macOS runner**.
- Workflow: `xcodebuild` with code signing disabled, then fake-sign with `ldid -S` (include an entitlements file if needed), then zip `Payload/App.app` into an `.ipa` and upload it as a downloadable build artifact. Check which Xcode version the macOS runner has and make sure it can still target iOS 15.0.
- Use a `project.yml` for XcodeGen (or a Swift Package plus a generated project) so the project files are readable and diff-friendly.
- GitHub setup: I'll make a free account. If you have `gh` available, tell me exactly how to log in with `gh auth login`. Otherwise give me click-by-click web steps to create the repo, upload the files, run the workflow and download the IPA on the iPad.
- Keep a short `BUILDING.md` with those steps in plain language.

## 4. Extension runtime (the hard part, do this carefully)

**Do not guess the Paperback 0.8 extension API.** Reverse-engineer it from real material, in this order:

1. Fetch the three repositories I use and study their structure (index/versioning files, per-source folders, bundled JS, icons). Do not assume the layout. Look at it.
   - `https://thenetsky.github.io/netskys-extensions/0.8` (MangaKatana)
   - `https://acepilot147.github.io/pb-extensions/0.8` (ComixTo, fork of AthK's extensions)
   - `https://thenetsky.github.io/extensions-sources/primary` (MangaDex by nar1n; its extension is built for 0.7, see below)
   - These URLs were read from blurry screenshots. Verify them. If one doesn't load, tell me.
2. Find the published 0.8 extension typings (probably the `@paperback/types` npm package, or the Paperback-iOS GitHub organisation) and use them as the contract for the API the JS expects.
3. Read the actual bundled extension code to see which globals and calls it really uses.

Then implement a runtime in Swift using **JavaScriptCore** that provides what the extensions need. Likely areas, to be confirmed from the code: network requests with interceptors and cookie handling, HTML parsing helpers, home page sections, search with filters, manga details, chapter lists, chapter pages, tracking/settings storage, and error types.

Design:
- Repositories are added by URL. The app lists sources from the repo and lets me install, update and remove them.
- Show each source's metadata (name, version, language, capability badges) like Paperback does.
- If a source needs an API version the runtime doesn't support, show a clear "incompatible" badge instead of failing.
- A source crashing must never crash the app. Catch JS exceptions and show the message.
- **MangaDex:** do not run the 0.7 extension. Implement MangaDex natively against the official API (`api.mangadex.org`, including the at-home server for page images, tag filtering and rate limits).
- Build a **PC-side test harness first** (Node or JavaScriptCore on the macOS CI runner) that loads the real extension bundles and calls search, details, chapters and pages. Do this **before** any UI work, so the runtime is proven on a computer before it touches the iPad.

## 4a. Security, privacy and identity

I'm interested in cybersecurity, so treat extensions as **untrusted third-party code**:
- Run each source in its own `JSContext` with no access to the file system, other sources' storage or cookies, or the app's data. The only way out is the app's bridge (network requests, parsing helpers, that source's own settings storage).
- HTTPS only by default. Validate repository URLs and manifests before installing, and show a clear "you are adding third-party code" warning when I add a repo.
- Limit request rate and concurrency per source (be polite to sites, avoid getting my IP banned). Respect the MangaDex API rate limits.
- No analytics, no telemetry, no accounts, no data leaving the device except requests I trigger. Say so in the Settings screen.
- Store cookies and any tokens in the Keychain if it works under TrollStore **(verify)**, otherwise in an app-private file, and tell me which.
- Optional app lock (Touch ID or passcode via `LocalAuthentication`) as one of the extras I may choose.
- **Identity and licensing:** pick an original app name, bundle identifier and icon. Do not use Paperback's name, logo or code. Re-implement the extension API from the public typings and the extensions' own code, and check the licences of anything you reuse (typings, libraries) and list them in `NOTES.md`.

## 5. Cloudflare flow (must match how Paperback works for me)

In Paperback, when a source hits a Cloudflare check, I press a button, the site opens in a web view, I solve the captcha by hand, press **Done**, and go back to the app with the source working. Replicate this:

1. The runtime detects a Cloudflare challenge (HTTP 403/503 with challenge markers, and/or the extension throwing its Cloudflare error; confirm the exact mechanism from the extension code).
2. The UI shows a clear "Verification needed" banner or button for that source.
3. Tapping it opens the source's URL in a full-screen `WKWebView`, using a persistent website data store, with a **Done** button.
4. On Done, read the cookies for that domain from `WKHTTPCookieStore` (especially `cf_clearance`) and store them.
5. Send those cookies on all later requests for that domain from `URLSession`. Use **exactly the same User-Agent string** as the web view, because `cf_clearance` is tied to the User-Agent (and often the IP). Extensions may set their own User-Agent header, so decide one consistent User-Agent per domain: either set the web view's `customUserAgent` to the one the runtime sends, or override the extension's User-Agent for that domain with the web view's. Tell me which you chose and why.
6. Persist the cookies across launches. When they expire, show the banner again.
7. Retry the request that failed automatically after verification.

Known risk: Cloudflare may treat old WebKit (Safari 15) differently. Paperback works for me on this iPad, so it's possible. Say so plainly if it fails.

## 6. App features

**Stage 1 (working app)**
- Library with categories/tags and sort options (title, last read, last updated, unread count).
- Source browser: home sections, search, **good filters** (genres/tags include and exclude, status, type, sort). Filter UI should be clean and fast to use on an iPad. This is my main complaint with Paperback.
- Manga details page: cover, description, tags, chapter list (read/unread marking, mark-all, sort), continue-reading button.
- Reader: right-to-left paged mode, left-to-right paged mode, vertical webtoon scroll. Zoom, tap zones, page indicator, preloading the next pages, remember reading position per chapter.
- History and continue reading.
- Local backup/export and import of the library (JSON).
- Per-source settings (the sliders icon in Paperback), source language filter and source ordering.
- Offline-friendly library: cache covers, descriptions and chapter lists so the library opens without internet.
- Settings, repository management, and a log/error screen I can screenshot for you. Logs persist to disk, and if the app crashed last time, show what was happening on the next launch.
- Basic accessibility: Dynamic Type, VoiceOver labels on controls, sufficient contrast.

**Stage 2 (suggestions)**
- A "Suggested for you" page built on-device from my library, reading history and tags (weight tags by how many library titles use them and how recently I read them). Query the sources, starting with MangaDex, for matching titles, dedupe against my library and show a short reason ("Because you read X"). No account or server needed.
- Chapter downloads for offline reading (only if Stage 1 is stable).

## 7. UI direction

- Modern and clean, dark mode first. Cover-grid library with adjustable columns, large tap targets, and consistent spacing.
- Make the filter and sort UI quick and visible, not buried in menus.
- Fast, with smooth scrolling on an A8X, so keep animations simple.

## 7a. Research phase: features, settings and options (do this before designing)

Before building Stage 1, do **detailed web research** on what manga apps and sites offer. Cover at least Paperback, Aidoku, Mihon/Tachiyomi and its forks, Tachidesk/Suwayomi, Kavita, Komga, MangaDex, MangaUpdates, MAL/AniList, Webtoon and Comick-style sites.

Research and list:
- **Reader settings:** reading modes, page layouts, zoom, tap zones, image filters (brightness, grayscale, invert), crop borders, double-page spreads, auto-scroll, keep-screen-on, volume/button navigation, preloading.
- **Library and browsing:** categories, sort/filter options, badges (unread count, downloaded), grid size, update checks, tags/genres include/exclude, saved searches, "random manga".
- **Discovery:** how other apps do recommendations, trending, popular, latest and similar-title suggestions.
- **Data and sync:** backups, tracker integration (AniList, MAL), history, import/export, migration between sources.
- **Quality of life:** per-manga reader settings, duplicate detection, notifications (probably not possible with TrollStore, say if so), downloads, storage management, source health indicators.
- **Content and privacy:** adult-content filtering/blur, app lock, incognito/no-history mode, hiding titles from history.

Then:
1. Pick the **most important** ones, ranked by how much value they add versus how hard they are to build on iOS 15 with 2 GB RAM. Mark what is realistic, what is hard, and what is not possible.
2. Show me the list **before building** (short and grouped, not a wall of text) with your recommended must-haves.
3. **Ask me which extras I want**, including features from the research that weren't in your must-have list. Don't add extras on your own and don't skip this question.
4. Put the agreed list into `NOTES.md` as the feature scope.

## 7b. Research phase: design and visual style

Research modern app design for reading and media apps (manga readers, Apple Books, Kindle, Netflix/Crunchyroll-style browsing, Letterboxd, Are.na, premium dark UIs). Look at color systems, typography, spacing, cover-grid layouts, filter sheets, empty states, micro-interactions that stay cheap on an A8X, and iPad layouts (sidebar, split view).

Then:
1. Propose **2-3 distinct design directions** with palette, fonts available on iOS 15 (system fonts or small bundled ones), layout examples and a mood description. Make them look intentional, not like a generic template.
2. Draw inspiration from **my interests**. Start with these and **ask me to add or correct them**:
   - Self-improvement and building habits (e.g. calm, focused, minimal, progress and streak-style touches that are tasteful and not gamified clutter).
   - Cybersecurity and programming (e.g. subtle terminal/monospace accents, a dark "console" mood as an optional theme).
   - I'm introverted and dislike fake, flashy behavior, so keep the feel calm, honest and understated: no loud animations, no pushy engagement tricks.
   - Manga itself: use the art and mood of the genres I read, but **do not copy any real manga's artwork, logos or characters**. Use original shapes, textures and colors only.
3. Let me choose a direction (and a light theme option if I want one) before you build the full UI. A short mockup (image or simple SwiftUI preview screenshots, not a long description) helps.
4. Use SF Symbols that exist on iOS 15 only.

## 8. Order of work and acceptance checks

0. Before anything else:
   - Save this whole brief into the repo as `docs/BRIEF.md` (so later sessions and other models can re-read it) and create `NOTES.md`.
   - Ask me these questions in **one short message**: iPad storage size and free space; whether the iPad has cellular; the Paperback version I use now (Settings, About); my usual reading direction and favourite genres (for the design and suggestions); whether I want adult/NSFW-tagged content hidden by default; whether I have a name idea for the app.
   - Verify the hardware/software limits in section 2 and report corrections.
1. Study the repos and typings. Report what you found and which API pieces the runtime must implement. **Stop and show me this summary** before building.
1b. Do the research in 7a and 7b. Show me the feature shortlist, ask which extras I want, and let me pick a design direction. These can run in parallel with step 2, but **do not build the full UI until I've answered**.
2. PC test harness running MangaKatana end to end (search, details, chapters, pages) with real network calls. Show results.
3. Minimal app: add repo, install MangaKatana, search, open a manga, read one chapter. Build the IPA through GitHub Actions and walk me through installing it in TrollStore.
4. Cloudflare web view flow, tested on ComixTo.
5. Native MangaDex source.
6. Full Stage 1 UI, then Stage 2.

After each milestone: tell me what is verified and what is not, then wait for my feedback from the real iPad.

## 9. Working rules

- Small commits with clear messages. Keep a `NOTES.md` listing decisions, verified facts, known problems and the **next step**, updated at the end of every session, because I may switch models between sessions and the new one only knows what is in the repo.
- **Data safety:** store the library, history and settings in a database with versioned **migrations** (for example SQLite or Core Data), so an app update never wipes my library. Test an upgrade from the previous build before giving me a new IPA. Keep the JSON export working at all times.
- Write code I can maintain: clear structure, comments on the tricky parts (runtime bridge, Cloudflare, memory handling).
- Ask me before adding paid services, accounts or anything that needs a Mac.
- If something is impossible on iOS 15 or with this approach, tell me early with the alternative.
