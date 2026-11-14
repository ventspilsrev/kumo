# NOTES

Working notes for the manga reader project. The full brief is in `docs/BRIEF.md`.
A new session should read the brief, then this file, then continue at **Next step**.

Last updated: 2026-11-14 (session 1)

## Status

- Step 0 (save brief, verify limits, ask questions): done, **waiting for Rev's answers** (see "Open questions").
- Step 1 (study repos and typings): done, summary below. **Waiting for Rev's go-ahead** before building.
- No app code written yet. Nothing has been built or run on the iPad.

## Next step

1. Get Rev's answers to the open questions.
2. Step 2: test harness that loads the real MangaKatana bundle and runs search, details, chapters, pages
   against the live site. Node is NOT installed on Rev's PC (only git and Python 3.14), and `gh` is not installed.
   Either Rev installs Node LTS locally (faster feedback) or the harness only runs on GitHub Actions.
3. Step 1b in parallel: feature research (7a) and design directions (7b). Do not build full UI before Rev answers.

## Open questions for Rev

- iPad storage size and free space
- Does the iPad have cellular
- Paperback version in use (Settings, About)
- Usual reading direction and favourite genres
- Hide adult/NSFW-tagged content by default?
- Name idea for the app
- ComixTo telemetry: block it? (see below; recommendation: block)
- Install Node.js on the PC for the test harness, or CI only?

## Repositories (verified by fetching on 2026-11-14)

All three URLs load. Layout is the same for all:

- `<repo>/versioning.json`: `{ buildTime, sources: [...], builtWith }`
- `<repo>/<SourceId>/source.js`: one bundled JS file (0.8 repos have no `index.js`; the 0.7 repo has both)
- `<repo>/<SourceId>/includes/<icon>`: icon, file name from the `icon` field

Per-source fields in `versioning.json`: `id, name, author, desc, website, contentRating (EVERYONE|MATURE|ADULT),
version, icon, tags[{text,type}], websiteBaseURL, intents` (bit mask, 0.8 only).

| Repo | builtWith | Sources |
|---|---|---|
| thenetsky.github.io/netskys-extensions/0.8 | toolchain 0.8.7, types 0.8.7 | 14 sources, MangaKatana 3.0.3 (intents 21). 6 of them are rated ADULT. |
| acepilot147.github.io/pb-extensions/0.8 | toolchain 0.8.7, types 0.8.7 | ComixTo 1.9.34 (intents 53) |
| thenetsky.github.io/extensions-sources/primary | cli 2.0.0-alpha.11, commons 5.0.0-alpha.5 (= 0.7) | MangaDex 2.1.10, Webtoons 2.1.4. No `intents` field. |

Compatibility rule for the app: `builtWith.types` starting with `0.8` = supported. Missing `builtWith.types`
or missing `intents` = show "incompatible" badge (this is how the 0.7 repo is told apart).

Intents bit mask (from the bundled types): MANGA_CHAPTERS 1, MANGA_TRACKING 2, HOMEPAGE_SECTIONS 4,
COLLECTION_MANAGEMENT 8, CLOUDFLARE_BYPASS_REQUIRED 16, SETTINGS_UI 32.

## Typings

- npm `@paperback/types` version **0.8.7**, licence ISC (package.json), repo Paperback-iOS/paperback-toolchain.
  Used as the API contract. We re-implement from the declarations, we do not ship the package.
- The extension repos (netskys-extensions, pb-extensions) have **no licence file** on GitHub. We only download
  and run them at the user's request, like Paperback does. We never bundle or redistribute them.

## How a 0.8 bundle works (read from the real bundles)

- The file defines `var _Sources = (...)()` and ends with `this.Sources = _Sources`. No module system, no `require`.
- `Sources.<Id>` is the source class, `Sources.<Id>Info` is the metadata object. The app does `new Sources.<Id>()`
  (ComixTo extends `Source`, whose constructor takes a `cheerio` argument it never uses).
- Everything the app provides is on one global object: **`App`**. cheerio and the HTML parser are bundled
  inside the extension itself, so the runtime needs **no HTML parsing helpers**.

### What the runtime must implement

Used by MangaKatana (small set):
- `App.createRequestManager({requestsPerSecond, requestTimeout, interceptor})` with `.schedule(request, retry)`,
  `.getDefaultUserAgent()`, and the interceptor hooks `interceptRequest` / `interceptResponse`
- `App.createRequest`, response object `{data (string), rawData, status, headers, request}`
- Plain data constructors: `createSourceManga, createMangaInfo, createPartialSourceManga, createChapter,
  createChapterDetails, createHomeSection, createPagedResults, createTag, createTagSection`
- Source methods called by the app: `getMangaDetails, getChapters, getChapterDetails, getSearchResults,
  getSearchTags, getHomePageSections(callback), getViewMoreItems, getMangaShareUrl`

Extra for ComixTo (large set):
- `App.createSourceStateManager()` with `store/retrieve` (and `.keychain` per the typings)
- `requestManager.cookieStore` with `getAllCookies / addCookie / removeCookie`, `App.createCookie`
- `App.createPBImage({data})`, `App.createPBCanvas()` with `setSize / drawImage / encode("image/webp"|"image/png")`:
  page images are **scrambled** and the extension un-scrambles them in `interceptResponse`. Implement natively
  with CoreGraphics.
- `App.createByteArray(rawData)`: used to decrypt images **in place**. The returned Uint8Array must share memory
  with `response.rawData` (the extension does not assign the result back). Needs a test.
- `App.createRawData`
- Settings UI ("DUI"): `createDUISection, createDUIForm, createDUIBinding, createDUISwitch, createDUISelect,
  createDUIButton, createDUINavigationButton, createDUIInputField, createDUILabel`; source methods
  `getSourceMenu`, `supportsTagExclusion`, `getCloudflareBypassRequestAsync`
- JS globals: `TextEncoder`, `TextDecoder`, `atob`, `btoa`, `console.log`, `Proxy`, `Reflect`, `new Function`.
  JavaScriptCore has no TextEncoder/TextDecoder/atob/btoa/console/setTimeout built in, so the runtime adds them.

Consequence for the reader: **page images must be downloaded through the source's request manager** so that the
interceptors run (referer header for MangaKatana, un-scramble/decrypt for ComixTo). A plain image loader is not enough.

### Cloudflare / verification mechanism (confirmed from code)

- The typings define **no Cloudflare error type**. The contract is: intent bit 16 plus
  `getCloudflareBypassRequestAsync()` which returns the request (URL + headers incl. User-Agent) to open in the web view.
  The app has to detect the challenge itself from the response (403/503 + `cf-mitigated: challenge` header or
  challenge markers in the body).
- Both sources send `requestManager.getDefaultUserAgent()` as their User-Agent. **Decision: the runtime returns the
  WKWebView's real User-Agent from `getDefaultUserAgent()`**, so web view and URLSession match without overriding
  anything. If a source sets a different UA (ComixTo has a UA setting), the bypass request carries that UA and the web
  view uses it as `customUserAgent`.
- MangaKatana: answered HTTP 200 without any challenge from Rev's PC on 2026-11-14 (server nginx).
- **ComixTo does not use Cloudflare's `cf_clearance` as its main check.** comix.to has its own check: cookie
  `waf_pass`, which the extension says lasts **about 5 minutes**, tied to the User-Agent. The bypass URL is
  `https://comix.to/@waf/challenge?return=%2F`. The extension can also solve the picture captcha itself
  ("Auto-solve" setting). So for ComixTo the web view flow must copy **all** cookies for the domain, not just
  `cf_clearance`, and re-verification will be frequent unless auto-solve works.

### ComixTo risks (be honest with Rev about these)

- **Telemetry:** every API call sends label, hashed path, HTTP status, sizes and timings to
  `https://telemetry.comix-ext.workers.dev/log`. This conflicts with the "no telemetry" rule in the brief.
  Plan: per-source host allow-list (source's own domain + image hosts seen in chapter pages), everything else
  blocked and logged; the extension already ignores the failure. Needs Rev's decision.
- It downloads comix.to's own JavaScript and runs it inside a fake browser `window` (via `new Function`) to extract
  request-signing keys, and decrypts API responses. This is fragile by design (version 1.9.34, rebuilt 2026-11-04,
  so the author updates it often) and CPU-heavy for an A8X without JIT. It is the hardest source to support.
  Still sandboxed: it can only reach the network through our bridge.
- Un-scrambling re-encodes every page image. Memory and speed on the iPad need measuring.

## Device limits check (brief section 2)

Verified against documentation / live lookups:
- GitHub Actions (checked 2026-11-14): `macos-latest` = macOS 26 arm64, default Xcode 26.6. `macos-15` has Xcode 16.4
  (default) and 26.x. Apple's table lists iOS 15 as the minimum deployment target for Xcode 16 through 27, so
  **iOS 15.0 is still buildable** but it is now the floor: a future Xcode may drop it. Plan: pin `runs-on: macos-15`
  and select Xcode 16.4 explicitly. macOS 14 runners were retired 2026-11-02.
- `xcodegen` and `ldid` are **not preinstalled** on the runners: install with `brew install xcodegen ldid` in the workflow.
- iOS 16+ only SwiftUI APIs in the brief's list (NavigationStack, NavigationSplitView, Grid, Charts,
  presentationDetents, scrollContentBackground, scrollIndicators): correct, all iOS 16+.
- WebP native since iOS 14: correct. AVIF is iOS 16+, JPEG XL is iOS 17+: correct, neither works on iOS 15.
- Swift concurrency: native on iOS 15, no back-deploy library needed.

From general knowledge, not re-checked this session (treat as "should be right"):
- A8X Metal max texture size 8192 px. Tall pages must be tiled or split.
- Per-app memory kill limit on 2 GB iPads is reported around 1.3-1.4 GB, so 300-400 MB is a safe working budget,
  not the hard limit. The danger is spikes from decoding big images.
- JavaScriptCore inside an app has no JIT unless the app has the `dynamic-codesigning` entitlement. TrollStore can
  grant entitlements and the A8X has no PPL, so JIT may be possible. Not relied on; can be tested later as a bonus.
- Keychain under TrollStore needs the right entitlements (`keychain-access-groups`, `application-identifier`) in the
  ldid entitlements file; without them calls fail with error -34018. Plan: self-test at launch, fall back to an
  app-private file, and show which one is in use in Settings.
- Push notifications and iCloud do not work with a fake-signed app. Background refresh is unreliable.

Corrections / additions to the brief:
- The runtime does not need HTML parsing helpers (bundled in the extensions).
- There is no "Cloudflare error" thrown by extensions in 0.8; detection is the app's job.
- ComixTo's check is the site's own WAF with a short-lived cookie, not classic Cloudflare clearance.
- The netsky 0.8 repo also contains adult-rated sources; the source list needs a content-rating filter.

## Decisions so far

- User-Agent: runtime reports the web view's real UA as the default UA (see above).
- CI: `macos-15` + Xcode 16.4, tools via Homebrew.
- Page images go through the source's request manager.

## Licences

- `@paperback/types` 0.8.7: ISC. Used as reference for the API shape only.
