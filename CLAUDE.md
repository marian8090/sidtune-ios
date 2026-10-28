# SIDtune for iOS

Native SwiftUI port of the SIDtune web app (a Commodore 64 SID music player) for iPhone and iPad. `PLAN.md` holds the plan,
the web-to-iOS module map and the milestones. Remote: `origin` = github.com/marian8090/sidtune-ios (`main`).

The web app is the specification: `reference/SIDtune` is a read-only clone of github.com/marian8090/SIDtune (git-ignored). Read it to
port behaviour; never edit or commit it. If it's missing: `git clone --depth 1 https://github.com/marian8090/SIDtune.git reference/SIDtune`.

## Commands

```bash
xcodegen generate                                   # regenerate SIDtune.xcodeproj after editing project.yml or adding/removing files
xcodebuild -project SIDtune.xcodeproj -scheme SIDtune -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build/DerivedData build
(cd Packages/SIDEngine && swift test -c release)    # engine tests + speed benchmark (prints BENCH lines)
```

The built app is `build/DerivedData/Build/Products/Debug-iphonesimulator/SIDtune.app`. Check UI changes in both an iPhone and an iPad
simulator.

## Layout

- `project.yml`: XcodeGen spec, the source of truth for the Xcode project (targets, Info.plist keys, background audio). Don't hand-edit
  `SIDtune.xcodeproj`.
- `SIDtune/`: the app.
  - `App/AppModel.swift`: all app state and logic (port of the web app's `state.ts`): library, HVSC catalogue, queue,
    shuffle/repeat, favorites/playlists/history, deep links. The HVSC catalogue is opt-in
    (`settings.onlineCatalogue`, off by default): nothing from HVSC ships in the app bundle. `App/Settings.swift`: `Settings` (UserDefaults), `Storage` paths.
  - `Audio/`: `PlaybackEngine` (render thread → ring buffer → `AVAudioSourceNode`, seek, mutes, FX, visualiser snapshots),
    `RenderCache` (instant-seek pre-render on its own thread), `NowPlayingCenter` (lock screen).
  - `Library/`: `HVSCClient` (catalogue, Range requests, offline packs), `Importer` (folders, files, zips), `LibraryIndex`.
  - `UI/`: SwiftUI views. `RootView` is a `NavigationSplitView` (collapses to a stack on iPhone) with Now Playing as an
    `.inspector` on iPad and a sheet on iPhone, and `PlayerBar` along the bottom. Themes and fonts live in `Theme.swift`.
  - `Resources/Docs/MANUAL.md`: the in-app Help (iOS edition of the web manual). Keep it in step with user-visible changes.
- `Packages/SIDEngine/`: local Swift package with three libraries: `SIDEngine` (emulator), `SIDLibrary` (PSID, Songlengths,
  STIL, catalogue index, zip reader, search; pure Foundation) and `SIDFX` (the audio quality modes and EQ, port of `fx.ts`).
  - `Sources/CSIDPlayFP/libsidplayfp` (3.1.2) and `libresidfp` (1.2.3): vendored upstream sources. Don't modify them. The only
    hand-written files there are the ones `configure` would generate: `libsidplayfp/config.h`, `libsidplayfp/sidplayfp/sidversion.h`,
    `libsidplayfp/builders/sidlite-builder/sidlite/sl_defs.h`, `libresidfp/siddefs-fp.h`, `libresidfp/residfp/sidversion.h`. To upgrade,
    replace the trees from the release tarballs (leaving out hardware builders, STILview, `Makefile*`, `*.in`, `*.a65`) and update those
    headers' version numbers.
  - `Sources/CSIDPlayFP/sidengine.cpp` + `include/sidengine.h`: a small C facade, so Swift needs no C++ interop.
  - `Sources/SIDEngine/SIDPlayer.swift`: the Swift API (`SIDPlayer`, `SIDConfig`, `SIDTuneInfo`).
- `SIDtune/Audio/PlaybackEngine.swift`: render thread → lock-free ring buffer (`Synchronization.Atomic`) → `AVAudioSourceNode`. Loads
  and song changes run under a lock and set `flushTo`, so the audio thread drops queued audio from the previous tune.

## Things that bite

- The emulator is compiled with `-O3` via `unsafeFlags` in `Package.swift`, including Debug builds; at `-O0` it can't keep up.
- Subtune numbers are 1-based everywhere in the Swift API (`0` passed to the C facade means "the tune's default").
- `SIDPlayer` isn't thread-safe. In the app only the render thread touches it, with `PlaybackEngine.lock` held.
- The power-on delay is fixed (`POWER_ON_DELAY` in `sidengine.cpp`) so a tune renders the same way every time. reSIDfp still dithers its
  filter tables from a counter shared by all instances, so separate runs differ by a few LSB. Compare audio with a tolerance, not `==`.
- Never do allocation, locking, Swift `print` or Objective-C messaging in `PlaybackEngine.pull` (the audio thread).
- The FX chain runs per sample on the render thread, so the app target builds with `-O` in Debug too (`project.yml`) and `SIDFX`
  with `-Ounchecked`. Changing FX settings goes through `fxPending` (main thread) → applied at the next chunk (render thread).
- The library has 60,000+ tunes: merging, search indexing and sorting run off the main thread (`LibraryIndex`, `sortOrder()`).
  Keep per-keystroke work (`refreshVisible`) to the memmem search plus an array map.
- Control calls on `PlaybackEngine` (load, seek, mute) can fast-forward the emulator for seconds; they run on `controlQueue` and
  report back on the main queue. `isBusy` drives the spinner.
- The simulator's screenshots can lag a second behind; wait before judging a tap.
- `UIBackgroundModes: audio` and the `.playback` audio session keep playback alive in the background. Keep both.

## Conventions

- Swift 6, strict concurrency, SwiftUI with `@Observable`, iOS/iPadOS 18+. One universal target.
- Port behaviour from the web app (`reference/SIDtune/src`); PLAN.md maps each web file to its Swift counterpart. Keep the web app's
  defaults and parameter values (for example the FX tables in `fx.ts`) unless there's a reason to differ.
- Match the existing style: small files, no comments that restate code, comments explain *why*.
- Add tests to `Packages/SIDEngine/Tests` (Swift Testing) for engine and parsing logic.
- Commit or push only when asked.
