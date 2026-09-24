# Physical Apple TV verification checklist

Only checks run on a real Apple TV count as verification of iCloud loading. Automated tests use a fake image provider, and the simulator has no iCloud Photos library.

Record each result as ✅ / ❌ / ⚠️ with notes, and keep the filled-in copy in the repo.

| Field | Value |
|---|---|
| Date | |
| Apple TV model and storage | (e.g. Apple TV 4K 3rd gen, 32 GB) |
| tvOS version | |
| AlbumLoop version (build) | (About screen) |
| Network | (Wi‑Fi / Ethernet, approximate speed) |
| Library size and iCloud Photos setting on the Apple TV | |
| Test album name, photo count in Photos, number of videos | |

## 0. Setup

- [ ] **0.1** Apple TV: Settings › Users and Accounts › *you* › iCloud › **iCloud Photos is on**. Note how long ago it was turned on.
- [ ] **0.2** Apple TV storage: Settings › General › Storage (or equivalent). Note the free space before testing: ______
- [ ] **0.3** Install AlbumLoop from Xcode (see README). On the Mac, open Console.app, select the Apple TV, filter on `subsystem:com.dennisfriedrichsen.AlbumLoop`, and start streaming.
- [ ] **0.4** Pick a **large test album** (ideally several hundred photos) that includes photos you haven't viewed on the Apple TV recently, so they're likely to be cloud-only. Note its photo count as shown in Photos on iPhone or Mac, and how many of its items are videos.

## 1. Permissions and states

- [ ] **1.1** First launch shows the explanation screen **with no system prompt on top of it**. **Continue** shows the system prompt, and its text matches the app's usage description.
- [ ] **1.2** Choose **Allow access to all Photos**, not "Select" (limited access), and the album grid appears. Optional: on a reinstall, try "Select" and confirm the header says "Limited access."
- [ ] **1.3** Deny path: delete and reinstall the app, deny access, and confirm the "Photos Access Is Off" screen. Follow its Settings path. **Is the path shown correct on this tvOS version?** Actual path: ______
- [ ] **1.4** Re-enable access in Settings, return to the app, and confirm the grid appears without relaunching.

## 2. Albums and counts

- [ ] **2.1** Every ordinary album you expect is listed, including albums inside folders. Shared Albums are not listed.
- [ ] **2.2** For at least 3 albums, compare the card count with Photos on iPhone or Mac: the card should equal *items − videos*. Note any mismatch: ______
- [ ] **2.3** Album covers load, including for albums you haven't opened on the Apple TV.
- [ ] **2.4** Turn on **Diagnostics Overlay** in an album's settings. The Albums header shows "eligible albums: N"; confirm N matches the albums that have photos.

## 3. Is iCloud loading real? (the key feasibility check)

- [ ] **3.1** Open the large album › **Test iCloud Loading**. Record the summary line: ______
- [ ] **3.2** At least some rows say **"iCloud only"** or **"not local"**, which shows that photos not on the device are being tested. If every row says "on device," pick an older, rarely viewed album and repeat.
- [ ] **3.3** The cloud-only rows show **✓** with a time. Record the median and slowest times: ______
- [ ] **3.4** Run the probe a second time. Previously downloaded rows may now say "on device" (a system cache). This is expected and purgeable; the app doesn't rely on it.

> If 3.3 fails (downloads error or never finish) with a working network, that is a platform-level finding. Record the error text and the Console log lines; do not treat the app as working.

## 4. Order

- [ ] **4.1** With Order = **Album Order** and Shuffle off, play the album with the counter on. Compare the first 10 and last 5 photos with the album's order in Photos on iPhone or Mac. Match? ______
- [ ] **4.2** If they don't match, note the order actually used (date? added order?) and try **Oldest First**. Record which option matches Photos: ______

## 5. Full sequential cycle (large album)

Settings: Shuffle off, Loop on, 3‑second slides (to save time), counter on, diagnostics on.

- [ ] **5.1** Start playback. "Photo 1 of N" shows the **full album count N** (the same as the album card), not a small number.
- [ ] **5.2** Watch the counter go past photo 11, 20, 50, and 100 without jumping back to 1. *(The failure seen in the built-in Photos slideshow.)*
- [ ] **5.3** When a photo isn't ready, the previous photo stays up with "Loading next photo…" or "Downloading from iCloud N%", then advances. The next slide lasts the full duration after it appears.
- [ ] **5.4** Diagnostics while playing: **Buffered ≤ 7**, **Memory ≤ budget**, **loading ≤ 2**. Note the peak memory: ______
- [ ] **5.5** Let it reach photo N and wrap to **Photo 1 of N, cycle 2**. If anything was skipped, a summary notice appears at the wrap.
- [ ] **5.6** Diagnostics at the wrap, or the Console "Cycle 1 complete" line: **Displayed = N** (or N minus the skipped and removed photos, each listed). Record: ______
- [ ] **5.7** Time for the full cycle, and how many times it stopped to load: ______

## 6. Full shuffle cycle

Settings: Shuffle on, Loop on, 3‑second slides.

- [ ] **6.1** Play one full cycle (N slides). The counter shows 1…N once.
- [ ] **6.2** No photo appears twice before the counter wraps. Spot-check by photographing the TV, or enable Action › Include Debug Messages in Console and look for a repeated `Request <token> attempt 1` line within the cycle.
- [ ] **6.3** At the wrap, the first photo of cycle 2 is not the same as the last photo of cycle 1.
- [ ] **6.4** Press Left several times mid-cycle: it retraces exactly the photos just shown, in reverse. Press Right to return.

## 7. Remote controls

- [ ] **7.1** Right / Left click and swipe → next / previous, and the counter updates immediately.
- [ ] **7.2** Press Right three times quickly while the next photo is loading: the counter moves 3 ahead, the current photo stays, and then the target photo appears. It never jumps back.
- [ ] **7.3** Play/Pause pauses: a "Paused" badge appears, nothing advances for 60 s, and prefetch continues (diagnostics Buffered rises). Play/Pause again resumes with the remaining time.
- [ ] **7.4** Click → controls appear with visible focus. Left/right move focus between buttons. Back hides them; Back again exits.
- [ ] **7.5** The Loop and Counter buttons in the controls take effect immediately.
- [ ] **7.6** With Black Bars or Blurred Background, photos of every shape (portrait, landscape, panorama) show whole, with nothing cropped.

## 8. Network loss and recovery

- [ ] **8.1** During playback, disconnect the Apple TV from the network (unplug Ethernet, or turn off the Wi‑Fi router). Already-buffered photos keep playing (up to about 3).
- [ ] **8.2** At the first photo that isn't buffered: "Waiting for network…" or "retrying…" appears, and the current photo stays on screen. After about 25 s of retries a **"Couldn't Load Photo X of N"** panel appears with Retry / Skip Photo / Exit. There's no endless spinner and no jump to photo 1.
- [ ] **8.3** Record X: ______. Reconnect the network. Within a few seconds the photo loads **without pressing anything** and playback continues from X.
- [ ] **8.4** Repeat, and this time press **Skip Photo** during the outage. At the end of the cycle the summary lists it as skipped.
- [ ] **8.5** Disconnect before starting a slideshow on an album with nothing cached: you get a clear error panel, not a spinner or a loop.

## 9. Leaving and reopening playback

- [ ] **9.1** Press Back mid-slideshow → the album screen. Console shows no further "Request" lines for that session (requests are cancelled).
- [ ] **9.2** Start a *different* album right away. It starts at Photo 1 of its own count, and no photo from the previous album appears.
- [ ] **9.3** Press the TV/Home button mid-slideshow, wait 1 minute, and reopen AlbumLoop. The slideshow is at the same position and resumes if it was playing.
- [ ] **9.4** Screen saver: while playing, the screen saver never starts (leave it playing past your screen-saver delay). Pause, and the screen saver starts after the normal delay. Exit the slideshow, and normal behaviour continues.
- [ ] **9.5** Run the album for 30+ minutes with diagnostics on. Memory stays within budget, and the app isn't terminated.

## 10. Album edits during playback

- [ ] **10.1** While an album is playing, add two photos to it on your iPhone. When iCloud syncs, the notice "Album gained 2 photos — updates apply after this cycle" appears, and the counter's N does **not** change mid-cycle.
- [ ] **10.2** After the wrap, N increases by 2 ("Album updated" notice).
- [ ] **10.3** Delete a photo that hasn't been shown yet in this cycle. When it's reached, it's skipped automatically and reported as "no longer in library" at the end of the cycle.

## 11. Storage

- [ ] **11.1** Check Apple TV free storage after the tests and compare it with 0.2. Any growth should be system cache, which tvOS can purge; the app keeps no copies. Record: ______

## 12. Vertical photos

Use an album with many vertical photos. Turn on the diagnostics overlay. For each style, watch at least 20 slides.

- [ ] **12.1** The Vertical Photos setting shows "(best for older Apple TVs)" next to Blurred Background, and on an Apple TV HD or 4K (1st gen) it is the default.
- [ ] **12.2** **Blurred Background:** the side bars show a soft, darkened version of the photo; slide changes crossfade without a black flash.
- [ ] **12.3** **Slow Pan:** vertical photos fill the screen and move smoothly (no stutter); portraits end with the face in view. Play/Pause freezes the pan. Note memory versus budget and whether it ever stops to load: ______
- [ ] **12.4** **Smart Crop:** faces are inside the frame (not cut off at the top). Count bad crops out of 20: ______
- [ ] **12.5** **Side by Side:** adjacent vertical photos appear as pairs with "Photos N–N+1 of M"; Left/Right move by whole slides and return to the same pairs. A pair never contains a landscape photo (if it does, PhotoKit's stored dimensions don't match the displayed orientation; note it).
- [ ] **12.6** **Black Bars:** unchanged from before.
- [ ] **12.7** Which style do you prefer on this Apple TV? ______

## Sign-off

| Area | Result | Notes |
|---|---|---|
| iCloud loading (3) | | |
| Order (4) | | |
| Sequential cycle (5) | | |
| Shuffle cycle (6) | | |
| Remote (7) | | |
| Network (8) | | |
| Lifecycle (9) | | |
| Album edits (10) | | |
| Vertical photos (12) | | |
