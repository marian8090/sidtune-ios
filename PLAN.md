# SIDtune for iOS and iPadOS: plan

Goal: a native, universal (iPhone + iPad) app with feature parity to the SIDtune web app (v0.7.0, `reference/SIDtune`, used read-only
for reference). It should also do what a browser can't do well on iOS: reliable background playback, lock-screen controls, Files
integration and a hardware-keyboard layout on iPad.

Repository: https://github.com/marian8090/sidtune-ios (`main`). The web app (github.com/marian8090/SIDtune) is cloned into
`reference/SIDtune` and git-ignored.

## 1. Architecture: native SwiftUI + native libsidplayfp

The web app is about 5,000 lines of TS/TSX with clean separation (engine, state, library, UI), so it serves as the specification for a
Swift port. Each Swift module below names the TS file it ports.

Why native rather than a WKWebView wrapper:

- **Background audio and lock screen:** `AVAudioSession` and `MPNowPlayingInfoCenter` work properly; Web Audio is suspended when the
  app goes to the background.
- **Speed:** libsidplayfp compiled for ARM is several times faster than WASM, so reSIDfp should be usable on phones.
- **iPad:** split view, keyboard shortcuts, pointer, Stage Manager.

## 2. Target and tooling

- Xcode 27.1 (installed), Swift 6 with strict concurrency, SwiftUI with `@Observable`.
- Deployment target: iOS/iPadOS 18. That covers almost every active device and gives `@Observable`, `NavigationSplitView` and modern
  `TimelineView`/`Canvas`.
- One universal app target, plus a local Swift package for the engine:

```
SIDtune-iOS/
  SIDtune.xcodeproj
  SIDtune/                 app target (SwiftUI)
    App/                   SIDtuneApp, AppModel (port of state.ts)
    Audio/                 PlaybackEngine, FX, Export, NowPlaying/RemoteCommands
    Library/               Database, PSID, Songlengths, STIL, Importer, HVSCClient
    UI/                    Sidebar, TrackList, PlayerBar, NowPlaying, Viz, Settings, About, Docs
    Resources/             fonts (byte-identical), MANUAL.md, CHANGELOG.md
  Packages/SIDEngine/      libsidplayfp C++ sources plus a small C/ObjC++ or Swift-C++-interop facade
  reference/SIDtune/       web app, read only, git-ignored
```

- cmake is not installed. Build libsidplayfp from vendored sources inside the Swift package with a handwritten `config.h`, so no
  autotools or cmake is needed. Pin an upstream release and record its version.

## 3. Module map: web to iOS

| Web (reference) | iOS | Notes |
| --- | --- | --- |
| `libsidplayfp-wasm` + `engine-factory.ts` | `SIDEngine` package: `SIDPlayer` facade (load, selectSong, render(frames), mute(chip, voice), setConfig, setROMs, sidRegisters(chip), tuneInfo, md5) | Keep the same rules: config after the first load, 0-based song index in the engine, 1-based in metadata |
| `engine.worker.ts`, `sid-worklet.js`, `controller.ts` | `PlaybackEngine`: a render thread fills a lock-free ring buffer about 0.35 s ahead in 1024-frame chunks; an `AVAudioSourceNode` pulls from it. Each chunk carries a generation number and a register snapshot | Generation and flush logic carries over 1:1. Position = base + frames played |
| `cache.worker.ts` | Optional pre-render on a second thread into a chunk array | Measure first: native reSIDfp may fast-forward quickly enough that the cache only matters for long tunes |
| `media-anchor.ts` | `AVAudioSession(.playback)`, `MPNowPlayingInfoCenter`, `MPRemoteCommandCenter` (play/pause, next/prev, seek, like) | Replaces the silent-audio hack; add `UIBackgroundModes: audio` |
| `fx.ts` | `FXChain`: own DSP in Swift/C (biquads for the LR8 crossover and 3-band EQ, wide-mono delay, ping-pong delay, convolution reverb via Accelerate/vDSP, REAL speaker chain), run in the render path | Built-in `AVAudioUnitReverb`/`Delay` can't reproduce these modes. Same parameter tables as `fx.ts`; glide parameter changes |
| `export.worker.ts`, `flac.ts`, `encoders.ts` (dropped on iOS) | `Exporter`: offline render at 44.1 kHz. WAV and FLAC via `AVAudioFile`/ExtAudioFile, M4A (AAC/ALAC), MP3 via LAME if wanted | Apple has no built-in MP3 encoder. Hand off via `ShareLink`/`fileExporter` |
| `psid.ts`, `songlengths.ts`, `stil.ts` | `PSIDHeader`, `Songlengths` (MD5 via CryptoKit, md5 from the engine), `STIL` | Straight ports |
| `db.ts` (IndexedDB: meta, files, kv) | SQLite via GRDB: `tunes` table with FTS5 for search, `favorites`, `playlists`, `history`; tune files in Application Support / Caches | Search across 60,000+ tunes is instant with FTS5. SwiftData is too slow for this size |
| `prefs.ts`, `Settings` | `UserDefaults` / `@AppStorage` | Theme, font, tooltips, engine settings |
| `hvsc.ts` | `HVSCClient` (URLSession; manifest, index, STIL, Range requests per tune, prefetch next) | On by default, pointing at the same R2 catalogue as the web app (`HVSC_URL` build setting). Same file format (`format: 1`, same columns); index cached in the DB, played tunes cached on disk for offline use |
| `importer.ts` (folder, drop, zip) | Files app folder picker (security-scoped bookmark to `C64Music`), `.fileImporter` for `.sid`/`.zip`, drag and drop on iPad, "Open in SIDtune" (declare a `.sid` UTType) | Zip via ZIPFoundation. Also pick up `Songlengths.md5` and `STIL.txt` automatically |
| `state.ts` | `AppModel` (`@Observable`, `@MainActor`): queue, shuffle/repeat, playlists, favorites, history (500), current tune/song, voice mutes | Keep the "queue follows the list you started from" behaviour |
| Shared links `?tune=&song=` | `sidtune://tune?path=…&song=…`; later, universal links on the web app's domain that open the app or fall back to the site | |
| `App.tsx` shortcuts | `.keyboardShortcut` + `UIKeyCommand` menu on iPad (Space, ←/→, ⇧←/⇧→, 1–9, ⌘F for search, T, ?, N, S, R, ⌘E) | |
| `Viz.tsx` (pitch roll + scope) | SwiftUI `Canvas` in a `TimelineView(.animation)`, fed with the register snapshot matching the playback position | Move to Metal only if Canvas profiles too slow on iPad Pro 120 Hz |
| Themes / fonts (`styles.css`) | A `Theme` struct with colour tokens per theme (Purple, C64 Blue, Green/Amber phosphor, Mono dark/light); bundle PetMe64, PrintChar21 and JetBrains Mono | Font files stay byte-identical to the originals, as in the web app |
| `MANUAL.md`, `CHANGELOG.md` + `markdown.ts` | Bundled Markdown rendered with `AttributedString(markdown:)` per block (plus a simple table view) | Write an iOS edition of the manual (gestures instead of the mouse) |
| `Ask.tsx` | SwiftUI `.alert`/`.confirmationDialog` | |

## 4. Layout: iPhone and iPad

- **iPad (regular width):** `NavigationSplitView` with three columns: sidebar (Library, Favorites, History, Playlists, Import), track
  list (sortable `Table` with Title, Composer, Released and Length columns), and Now Playing as the detail column with the visualiser,
  subtunes, voice mutes and STIL. A persistent player bar along the bottom. Full keyboard and pointer support.
- **iPhone (compact):** a `TabView` (Library / Playlists / Search / Settings), a `List` for tunes with swipe actions (favorite, add to
  playlist) and context menus, a mini player above the tab bar, and Now Playing as a full-screen sheet with a swipe-down dismiss.
- Both: `.searchable` across title, composer, year and path; the full HVSC catalogue is there on first launch; Dynamic Type where the
  retro fonts allow it; dark/light follows the selected theme; VoiceOver labels on transport controls.

## 5. Milestones

1. **Engine spike (de-risks the whole project).** Vendor libsidplayfp, build `SIDEngine` for device and simulator, and play a tune
   through `AVAudioSourceNode`. Measure reSIDfp's realtime factor on the iPhone 17 simulator and a real device. Output: whether SIDLite
   and the pre-render cache are needed.
2. **Playback core.** Generation/flush, seek (cache or fast-forward), subtunes, voice mutes, song lengths, end-of-tune, background audio,
   lock-screen controls, interruptions (calls) and route changes (headphones unplugged pauses playback).
3. **Library.** GRDB schema, HVSC catalogue client (index, STIL, streaming, prefetch, offline cache), PSID parser, folder/zip/file
   import with progress, Songlengths + STIL, search, sort, favorites, playlists, history.
4. **UI.** iPad split view and iPhone layout, player bar, Now Playing, settings (engine, SID model, PAL/NTSC, digi boost, default length,
   seek cache, online catalogue, ROMs), themes and fonts, about, manual and changelog.
5. **Sound and visuals.** FX modes plus the 3-band EQ (ported from `fx.ts`), and the visualiser.
6. **Extras.** Export (WAV/FLAC/M4A + original `.sid`) with tags, deep links, iPad keyboard menu, Open in SIDtune.
7. **Release prep.** App icon, launch screen, privacy manifest (no tracking, no data collected), credits screen, TestFlight, App Store.

Milestone 1 is the only real unknown. Everything after it is a straightforward port of code that already works.

### Milestone 1 results (2026-10-28)

- libsidplayfp 3.x moved reSIDfp into a separate library, so both libsidplayfp 3.1.2 and libresidfp 1.2.3 are vendored. SIDLite is
  part of libsidplayfp. Everything builds from source through SwiftPM with hand-written config headers; no cmake or autotools needed.
- Speed rendering Commando (Rob Hubbard) at 48 kHz: reSIDfp **31x realtime**, SIDLite **150–166x**, on both the Mac (`swift test -c
  release`) and the iPhone 17 simulator. The web app's WASM reSIDfp manages about 7x. Still to do: measure on a real iPhone with the
  in-app "Measure emulation speed" button.
- Conclusions so far: reSIDfp can be the default on every device, with SIDLite kept as an option. A forward seek of one minute costs
  about 2 s of fast-forwarding, so the pre-render cache is still worth porting for instant seeks, but it's no longer essential.
- The spike app (`SpikeView`) plays a bundled tune through the ring-buffer `PlaybackEngine`, switches subtunes and engines, and runs
  with no underruns. Milestone 2 replaces it.

### Milestones 2–6 (2026-10-28)

Ported in one pass: playback core (seek with the instant-seek cache, subtunes, voice mutes, song lengths, auto-advance, background
audio, lock screen, interruptions), the library (online HVSC catalogue with offline download, import of folders/files/zips,
Songlengths, STIL, search, sort, favorites, playlists, history), the iPhone and iPad UI, settings, themes and fonts, the five audio
quality modes and the EQ, the visualiser, export (SID, FLAC, WAV, AAC), share links and iPad keyboard shortcuts.

Deviations from the plan above: the library stays in memory with JSON files on disk (like the web app's IndexedDB use) instead of
GRDB, which is fast enough for 61,000 tunes with the memmem search index; MP3 export is AAC instead; JetBrains Mono is the system
monospaced font.

Follow-up the same day: export (save as SID/FLAC/WAV/AAC) was removed as not needed on iOS; the HVSC catalogue became opt-in
(the empty library offers the download, nothing is bundled); the letter covers were dropped from the list and Now Playing, which now
fits an iPhone screen without scrolling.

Not checked yet: importing through the Files picker, the full offline download (about 350 MB), lock-screen controls on a device,
and the real-device speed.

## 6. Testing

Unlike the web app, the iOS app gets tests from the start where it's cheap: unit tests for the PSID parser, Songlengths/STIL parsing,
HVSC index parsing, queue/shuffle/repeat logic and the ring buffer. Then a golden test that renders the first second of a tune and
compares a checksum so engine upgrades are caught. UI is checked by running in the iPhone and iPad simulators.

## 7. Open questions

- MP3 export: needed, or are FLAC, WAV and M4A enough?
- Should the iOS app share the version number and changelog with the web app, or have its own?
- Sync favorites and playlists across devices via iCloud (CloudKit)? Easy to add later; not in the web app.
