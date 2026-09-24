# AlbumLoop

A native Apple TV app that plays **complete** slideshows of ordinary iCloud Photos albums, including photos that aren't stored on the Apple TV, using only public PhotoKit APIs.

- Pick an album with the Siri Remote and play every still photo in it, in album order or shuffled.
- Photos load a few at a time from iCloud while you watch. The playback sequence is always the whole album, never "whatever happens to be downloaded."
- Nothing is exported, mirrored, or saved by the app, and no Mac or iPhone needs to stay on.

> **Status:** the playback logic is covered by 34 automated tests using a fake image provider. On a physical Apple TV HD (tvOS 26.6), album listing works and photos stored only in iCloud download through public PhotoKit (11 of 11 sampled). **Full playback cycles, network loss, and long runs have not been verified on the device yet.** See [Verification status](#verification-status) and the [device checklist](docs/DEVICE_TEST_CHECKLIST.md).

---

## Feasibility (checked before building)

Sources checked on 2026‑09‑22: the tvOS 27.0 SDK headers in Xcode 27.0 (`Photos.framework`), and Apple's documentation for PhotoKit, `PHImageManager`, `PHImageRequestOptions.isNetworkAccessAllowed`, `PHPhotoLibrary.requestAuthorization(for:handler:)`, and `PHAssetCollection.fetchAssetCollections(with:subtype:options:)`.

| Capability | API | tvOS availability | Notes |
|---|---|---|---|
| Framework | PhotoKit (`Photos`) | tvOS 10+ | Apple describes it as giving access to photos "on the person's device and in iCloud." |
| Authorization | `PHPhotoLibrary.requestAuthorization(for: .readWrite)` | tvOS 14+ | Needs `NSPhotoLibraryUsageDescription`. No entitlement or paid capability required. |
| Album enumeration | `PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, …)` | tvOS 10+ | Ordinary user albums. Shared Albums are a separate subtype (`.albumCloudShared`) and are excluded. |
| Asset enumeration | `PHAsset.fetchAssets(in:options:)` | tvOS 10+ | |
| iCloud download | `PHImageManager.requestImage` with `isNetworkAccessAllowed = true`, `progressHandler` | tvOS 10+ | Documented: "If true, and the requested image is not stored on the local device, Photos downloads the image from iCloud." |
| Degraded vs. final results | `PHImageResultIsDegradedKey`, `PHImageResultIsInCloudKey`, `PHImageCancelledKey`, `PHImageErrorKey` | tvOS 10+ | |
| Availability | `PHPhotoLibrary.unavailabilityReason`, availability observer | tvOS 13+ | |
| Change notifications | `PHPhotoLibraryChangeObserver` | tvOS 10+ | |
| Not on tvOS | Limited-library picker, upload-job APIs | — | Irrelevant here. `PHAuthorizationStatus.limited` is handled, but tvOS has no picker to change the selection. |

**Conclusion:** there is no documented platform limitation that prevents this design. All required APIs are public and marked available on tvOS. Private APIs, Apple Account credentials, and scraping are not used.

**Must still be validated on a real Apple TV** (the tvOS Simulator has no iCloud Photos library):

1. That `.albumRegular` returns your iCloud Photos albums on tvOS, with correct photo counts.
2. That `requestImage` with network access actually downloads photos that aren't on the Apple TV, in a 300 GB library on a device with 32 GB of storage. Use **Test iCloud Loading** in the app. *Confirmed on 2026‑09‑24 on an Apple TV HD, tvOS 26.6: 11 of 11 sampled cloud-only photos downloaded, median 0.8 s.*
3. That PhotoKit's unsorted album fetch matches the album's order in Photos (see [Ordering](#ordering)).
4. Download times and memory behaviour on your specific hardware and network.
5. The Settings paths quoted in the app's permission messages.

On the built-in slideshow looping over its first ~10 photos: that behaviour is consistent with a player that treats the locally cached subset as the whole album, but it is **not confirmed**. AlbumLoop is designed so that failure mode can't happen, whatever the cause.

---

## Requirements

| | |
|---|---|
| Deployment target | **tvOS 18.0** |
| Built and tested with | Xcode 27.0 (27A266a), tvOS 27.0 SDK, Swift 6.4; simulator-tested on tvOS 26.5 and 27.0 |
| Hardware | Any Apple TV on tvOS 18 or later: Apple TV HD and **every** Apple TV 4K generation |
| On the Apple TV | Signed in to your Apple Account, with **iCloud Photos turned on** (Settings › Users and Accounts › *your account* › iCloud) |

**Why tvOS 18:** PhotoKit's required pieces need only tvOS 14 or earlier. The deployment target is set by the app's own code: the Observation framework (`@Observable`, tvOS 17), `Synchronization.Mutex` (tvOS 18), and current SwiftUI focus and command APIs. tvOS 18 runs on every Apple TV that can run tvOS 17, so raising the target costs no hardware, and it matches the iOS 18 baseline used across these projects.

**Older Apple TVs:** tvOS 27 dropped the Apple TV HD and the **Apple TV 4K (1st generation, model A1842)**, so tvOS 26 is the last version they run. Because the minimum is tvOS 18, AlbumLoop runs on tvOS 26 with no changes; the deployment target is a minimum, not the version you build with. Building with the tvOS 27 SDK in Xcode 27 still installs on a tvOS 26 device. Don't raise the deployment target above 26 while you use one of these models. To check your model, see Settings › General › About, and compare the model number with Apple's [Identify your Apple TV model](https://support.apple.com/en-us/101605).

---

## Build

```bash
git clone https://github.com/dennisfriedrichsen/AlbumLoop ~/src/github/dennisfriedrichsen/AlbumLoop
cd ~/src/github/dennisfriedrichsen/AlbumLoop
open AlbumLoop.xcworkspace
```

Open the **workspace**, not the `.xcodeproj`. The workspace includes the local `AlbumLoopCore` package, so ⌘U runs its tests from the `AlbumLoop` scheme.

The app has no third-party dependencies.

Command-line equivalents:

```bash
# Playback-logic tests on the Mac (fastest)
cd AlbumLoopCore && swift test
```

```bash
# Same tests on the tvOS Simulator
xcodebuild -workspace AlbumLoop.xcworkspace -scheme AlbumLoop -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' test
```

```bash
# Compile for a real Apple TV without signing (checks the device SDK)
xcodebuild -workspace AlbumLoop.xcworkspace -scheme AlbumLoop -destination 'generic/platform=tvOS' CODE_SIGNING_ALLOWED=NO build
```

### Simulator demo mode (Debug builds only)

The tvOS Simulator has no iCloud Photos library. To check the slideshow screens, pass the launch argument `-demoSlideshow` (Scheme › Run › Arguments). The app then plays 60 generated, numbered images with random delays, and every 7th image fails on purpose so you can see the retry and stall states. This mode is compiled out of Release builds and never touches PhotoKit.

---

## Install on your Apple TV

### 1. Choose how to sign

You do **not** need a paid membership to run AlbumLoop on your own Apple TV.

| | Free Apple Account ("Personal Team") | Apple Developer Program ($99/year) |
|---|---|---|
| Run on your own Apple TV from Xcode | Yes | Yes |
| How long an install keeps working | **7 days.** The provisioning profile expires; after that the app won't launch until you build and run again from Xcode. | 1 year (development profile) |
| Limits | Up to 3 devices and 10 App IDs, both expiring after 7 days; up to 3 of your apps per device | 100 devices of each type per year |
| TestFlight / App Store | No | Yes |
| Capabilities this app needs | None beyond Photos permission, which needs no entitlement, so a free account works | Same |

Limits are from Apple's [membership comparison](https://developer.apple.com/support/compare-memberships/) page, checked 2026‑09‑22. With a free account, plan to reinstall from Xcode about once a week. The paid program mainly buys a 1‑year install and TestFlight, which lets the Apple TV install updates itself.

### 2. Set up signing in Xcode

1. Xcode › Settings › Accounts › **+** › Apple Account, and sign in. A free account appears as "*Your Name* (Personal Team)."
2. In the project navigator select **AlbumLoop** › target **AlbumLoop** › **Signing & Capabilities**.
3. Keep **Automatically manage signing** on, and choose your team.
4. If Xcode says the bundle identifier `com.dennisfriedrichsen.AlbumLoop` is unavailable, change it to something unique, such as `com.<yourname>.AlbumLoop`.

### 3. Pair the Apple TV with Xcode (one time)

Apple TV 4K has no USB port, so pairing happens over the network. tvOS has **no Developer Mode switch**; pairing alone enables development.

1. Put the Mac and the Apple TV on the same network.
2. On the Apple TV, open **Settings › Remotes and Devices › Remote App and Devices**, and stay on that screen.
3. In Xcode, open **Window › Devices and Simulators** (called *Device Hub* in newer Xcode versions). Your Apple TV appears under Discovered; select it and click **Pair**.
4. Enter the code shown on the TV. Xcode may take a few minutes to prepare the device for development the first time.

### 4. Run

1. In the Xcode toolbar choose the **AlbumLoop** scheme and your Apple TV as the destination.
2. Press ⌘R. The first install to a new device can take a while.
3. On first launch AlbumLoop explains why it needs Photos access. Choose **Continue**, then choose **Allow access to all Photos**. The tvOS 26 prompt also offers a **Select** (limited access) option; with that, AlbumLoop sees only the photos you picked, so albums would look incomplete.
4. After that, AlbumLoop appears on the Home screen and you can launch it without Xcode, until the profile expires (7 days with a free account).

**Troubleshooting**
- *"Untrusted developer" or the app won't open:* rebuild and run from Xcode; free-account profiles expire after 7 days.
- *Apple TV not listed in Xcode:* stay on the Remote App and Devices screen, check both are on the same network and subnet, and try toggling Wi‑Fi on the Mac.
- *No albums:* confirm iCloud Photos is on for the current Apple TV user, and give a new sign-in time to sync.

---

## Using AlbumLoop

- **Albums screen:** each card shows the album name, cover, and number of eligible still photos. Albums appear immediately; counts and covers fill in over a few seconds ("counting photos…"), which took about 9 s for 157 albums on an Apple TV HD. The cover is the album's first photo. Live Photos count and are shown as stills; videos are excluded from the count and the slideshow.
- **Album screen:** Play, plus options (saved between launches): Shuffle, Order, Loop, Slide Duration (default 8 s), the "Photo 12 of 600" counter, and the diagnostics overlay. **Test iCloud Loading** checks 12 photos spread across the album and reports which ones are already on the Apple TV and how long the others take to download.
- **During a slideshow (Siri Remote):**

| Input | Action |
|---|---|
| Right / Left (click or swipe) | Next / Previous |
| Play/Pause | Pause or resume |
| Click, or Up/Down | Show controls (Previous, Play/Pause, Next, Loop, Counter, Exit) |
| Back / Menu | Hide the controls, or exit the slideshow |

- **If a photo can't load:** the current photo stays on screen with a small "Loading…" or "retrying…" note. After automatic retries fail, AlbumLoop stops and offers **Retry**, **Skip Photo**, or **Exit**. Skipped photos are listed in the summary at the end of the cycle.

---

## Architecture

```
AlbumLoop.xcworkspace
├── AlbumLoop/                    tvOS app target (SwiftUI + PhotoKit + a little UIKit)
│   ├── App/AlbumLoopApp.swift
│   ├── Photos/                   ① authorization + album access, ② PhotoKit image loading
│   │   ├── PhotoLibraryModel.swift    authorization, availability, albums, snapshots, change observer
│   │   ├── PhotoKitRequest.swift      callback → async bridge (degraded/final, cancel, exactly-once)
│   │   ├── PhotoKitImageProvider.swift  iCloud download, error mapping, screen-sized decode
│   │   ├── ThumbnailLoader.swift       album covers (bounded in-memory NSCache)
│   │   └── CloudProbe.swift            on-device "Test iCloud Loading"
│   ├── Views/                    ④ presentation (grid, detail, slideshow, panels, diagnostics, About)
│   └── Support/                  network monitor, display metrics, settings keys, DEBUG demo provider
└── AlbumLoopCore/                Swift package, no UIKit/PhotoKit, tested on macOS and tvOS
    ├── PlaybackSequence.swift    ③ the complete album order, shuffle permutations, history
    ├── ImageBuffer.swift         ② bounded rolling buffer: priorities, concurrency, memory, retries
    ├── SlideshowController.swift ③ explicit playback state machine
    ├── Scheduler.swift           injectable clock/timers (real vs. manual in tests)
    ├── ImageProviding.swift      provider protocol, AssetID, LoadedImage, failure kinds
    └── Diagnostics.swift         os.Logger categories, counters, cycle report
```

### The key rule: the sequence and the buffer are independent

- **`PlaybackSequence`** is a snapshot of *every* eligible asset identifier, taken when playback starts. A 600‑photo album is a 600‑item sequence, whether five images are loaded or none. Position (`cycle`, `position`) only changes through `advance()` and `retreat()`. It knows nothing about downloads.
- **`ImageBuffer`** only holds a small window: the photo playback needs, the one on screen, 3 upcoming, and 2 previous. It never decides what plays next. It just reports when each image is ready or has failed.
- **`SlideshowController`** connects the two through one explicit phase:

```
            start
  idle ───────────► loading ──(target image ready)──► showing
                     ▲   │                               │
     next/prev/timer │   │ retries exhausted             │ timer (only runs while showing & not paused)
                     │   ▼                               │
                     └ stalled ◄─────────────────────────┘
                   (Retry / Skip)
  showing ──(end of cycle, loop off)──► finished     any ──(nothing could load)──► failed
```

Every input (slide timer, image completion, remote press, network change) arrives on the main actor and goes through this one state machine, so there are no competing timers or callbacks. The slide timer starts only when the target image is actually on screen, and pause simply cancels it and remembers the time left.

### Loading and memory

- **Requests:** `deliveryMode = .highQualityFormat`, `isNetworkAccessAllowed = true`, `targetSize` = the TV's native pixel size (e.g. 3840×2160), `contentMode = .aspectFit`. Original camera files are never requested.
- **Decoding:** each result is drawn off the main thread into an opaque 8‑bit bitmap that fits the screen. That decodes it before display, applies orientation, and caps it at ~33 MB on a 4K TV.
- **Bounds:** at most 2 concurrent requests. The decoded-memory budget is 7 screen-sized images (~232 MB at 4K, ~58 MB at 1080p). New prefetches aren't started if they could exceed it. The needed image can pre-empt a prefetch for a request slot.
- **Eviction and cancellation:** anything outside the window is evicted and its request cancelled on every move, on album change, and when leaving playback. Backgrounding cancels prefetches; a memory warning drops everything except the current and on-screen images and shrinks the window.
- **No persistence:** the app writes no image data to disk. PhotoKit's own caches are system-managed and purgeable; the app never assumes they hold anything, and it doesn't use preheating (`PHCachingImageManager`) as a signal that anything has downloaded.

### PhotoKit callback handling (`PhotoKitRequest`)

- Degraded previews are ignored; only the final result completes a load.
- The continuation resumes exactly once (guarded by a `Mutex`), whether the callback arrives synchronously, asynchronously, more than once, or never (after cancellation).
- Task cancellation calls `cancelImageRequest`, including when cancellation lands before PhotoKit has returned the request ID.
- Every load attempt carries a unique token. Results for a token that is no longer current — after navigation, a watchdog timeout, a new album, or leaving playback — are counted as stale and dropped. Each session also gets a fresh buffer, so another session's callback can't affect it.

### Failure handling

| Situation | Behaviour |
|---|---|
| Download error or network error | Retried automatically after 2 s, 6 s, then 15 s (4 attempts). The current photo stays on screen, with a "retrying…" note. |
| No download progress for 30 s, or one attempt over 120 s | Treated as stalled: cancelled and retried. No infinite silent waiting. |
| Retries exhausted | The slideshow holds on the current photo and offers **Retry**, **Skip Photo**, or **Exit**. Nothing advances on its own. |
| User skips | Recorded, and listed in the end-of-cycle report ("Displayed 598 of 600 · 2 skipped (couldn't load)"). |
| Network lost, then restored | Position is kept. When the path returns, every failed image, including the stalled one, is retried automatically. |
| Photo deleted after the snapshot | PhotoKit can't find it, so it is skipped without retrying and reported as "no longer in library." |
| Album edited during playback | The running cycle is never rebuilt. A notice says the changes apply after this cycle, and the fresh snapshot is used from the next cycle. |
| Every photo in a cycle skipped or missing | Playback stops with an explanation instead of looping. |
| A load fails | Never resets to the first photo and never triggers an early loop. Position only moves through the sequence. |

### Ordering

- **Album Order (default):** `PHAsset.fetchAssets(in: album, options: nil)` with no sort descriptors and no predicate; videos are filtered out afterwards so the order isn't disturbed. In practice PhotoKit returns a user album's own order, but **Apple does not document that guarantee**, so check it on your Apple TV (checklist step 4).
- **Documented fallback:** if album order doesn't match what you expect, choose **Oldest First** (capture date ascending) or **Newest First** under Order.
- **Shuffle:** a new permutation each cycle; no photo repeats within a cycle; Previous walks back through that cycle's history; the first photo of a cycle is never the same as the last photo of the previous cycle (albums of 2 or more).

### Keeping the TV awake

`isIdleTimerDisabled` is on only while a slideshow is loading or showing, not paused, and in the foreground. It's turned off when you pause, stall, finish, exit, or background the app, so the normal screen saver and sleep behaviour returns.

### Diagnostics and privacy

- **Diagnostics overlay** (turn on in album settings): session, cycle, position, eligible album count, displayed / buffered / loading / pending / failed / skipped / removed counts, decoded memory versus budget, retries, stale callbacks, network state, and the last few requests with attempt number, duration, and outcome.
- **Logging:** `os.Logger`, subsystem `com.dennisfriedrichsen.AlbumLoop`, categories `library`, `loading`, and `playback`. Asset identifiers are logged only as short one-way hashes; image contents are never logged. Nothing leaves the device. To stream logs from a paired Apple TV, use Console.app and filter on that subsystem.

---

## Tests

`AlbumLoopCore/Tests` — 34 tests (Swift Testing) with a `FakeImageProvider` whose requests stay pending until the test completes, fails, or cancels them, and a `ManualScheduler` that makes time deterministic.

| Requirement | Tests |
|---|---|
| Album larger than the buffer plays completely before repeating | `largeAlbumPlaysCompletely` (40 photos, buffer of 6), `sequentialFullCycle` (600) |
| Delayed downloads don't reset or truncate; timer starts on display | `delayedDownloadHolds` |
| Out-of-order completion doesn't reorder playback | `outOfOrderCompletion` |
| Shuffle doesn't repeat within a cycle, no boundary repeat, history | `shuffleIsPermutation` (5 seeds × 3 cycles), `shuffleBoundary` (300 seeds), `shuffleHistory`, `upcomingAcrossBoundary`, `shuffleCycle` |
| Pause, and navigation during loading | `pauseKeepsPrefetching`, `navigationDuringLoading`, `navigationWhilePaused` |
| Failures, retries, explicit skips | `retriesThenStall`, `explicitSkipReported`, `deletedAssetSkipped`, `nothingLoads`, `stallWatchdog`, `retryExhaustion` |
| Network recovery | `networkRecovery` |
| Stale callbacks | `staleCallbackFromPreviousSession` (including a photo shared by both albums), `staleCallbackAfterNavigation`, `staleAfterReset` |
| Buffer bounds | `concurrencyBounded`, `byteBudget`, `neededPreemptsPrefetch`, `eviction`, `memoryPressure` |
| Lifecycle, album edits, loop off | `backgroundLifecycle`, `stopCancels`, `albumEditDeferred`, `finishesWithoutLoop` |

The PhotoKit layer (`PhotoKitRequest`, `PhotoKitImageProvider`, `PhotoLibraryModel`) has no automated tests: the simulator has no iCloud library to test it against. It is covered by the device checklist.

---

## Verification status

| Check | Where | Result |
|---|---|---|
| Core logic tests (34) | macOS, `swift test` | ✅ Pass (5 consecutive runs) |
| Core logic tests (34) | tvOS 27.0 and tvOS 26.5 Simulators, `xcodebuild test` | ✅ Pass |
| App compiles, Swift 6 language mode | tvOS Simulator SDK and **device** SDK (unsigned) | ✅ Builds with no Swift warnings |
| Welcome screen and empty-library state | tvOS Simulator (Photos permission granted with `simctl`) | ✅ Rendered |
| Slideshow UI: letterboxing, counter, diagnostics, "retrying…" indicator, stall panel with focus on Retry | tvOS 27.0 Simulator, `-demoSlideshow` (synthetic images) | ✅ Seen in screenshots |
| App launches and plays the demo slideshow; system Photos prompt shows the usage text | tvOS 26.5 Simulator | ✅ Seen in screenshots |
| Siri Remote input (left/right, Play/Pause, click, Back) | — | ⚠️ **Not yet exercised.** Needs a person with a remote, in the Simulator or on the device |
| Album enumeration against a real iCloud library | Apple TV HD (AppleTV5,3), tvOS 26.6 | ✅ 157 albums listed in 0.4 s; counts and covers filled in within 9 s |
| Album counts match Photos | Physical Apple TV | ❌ **Not yet compared** (checklist 2.2) |
| Downloading photos that aren't on the device | Apple TV HD (AppleTV5,3), tvOS 26.6, **Test iCloud Loading** | ✅ 12 sampled: 1 on device, 11 not on device; 11/11 downloaded at screen size (median 0.8 s, slowest 2.0 s). This is a 12-photo sample, not a full cycle |
| Full cycles, network loss, memory, and screen-saver behaviour | Physical Apple TV | ❌ **Not verified** |

No claim about iCloud reliability is made from mocks. Run the [physical-device checklist](docs/DEVICE_TEST_CHECKLIST.md) and record the results there.

---

## Limitations (version 1)

- Still photos only. Live Photos are shown as stills; videos are excluded. No music, video, or elaborate transitions (a 0.6 s crossfade only).
- Ordinary user albums only; Shared Albums and smart albums (such as Favorites) are not listed.
- Album order relies on PhotoKit's undocumented default order for user albums, with date-based orders as the fallback.
- If a photo can only be downloaded very slowly, the slideshow waits for it (with a visible indicator) rather than skipping ahead; the stall watchdog bounds that wait.
- With a free Apple Account the install stops working after 7 days until you run it from Xcode again.
- PhotoKit behaviour on a multi-user Apple TV follows the current user's iCloud Photos library.
