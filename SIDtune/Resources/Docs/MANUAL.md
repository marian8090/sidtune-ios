# SIDtune manual

SIDtune plays Commodore 64 music. It emulates the C64 and its SID sound chip cycle by cycle, so tunes sound the way they did on the real
machine. Everything runs on your device: your library, playlists, favorites and settings stay here and nothing is uploaded.

## 1. Getting music

There are two ways to fill your library, and you can use both at once.

**The online HVSC catalogue.** Nothing is included with the app. Tap *Download the HVSC* in the empty library (or turn on
*Settings → Online HVSC*) and the whole High Voltage SID Collection (HVSC, more than 60,000 tunes) appears in your library. Only the
list is downloaded up front (about 2 MB); each tune is fetched the first time you play it and kept for next time. It refreshes itself
when a new HVSC release comes out. Turning it off removes the list again.

**Download the whole collection.** *Settings → Online HVSC → Download the whole collection* stores every tune on this device (about
350 MB) so everything plays without a connection. Keep SIDtune open until it finishes. *Remove offline copy* frees the space again.

**Your own files.** Tap **+** (or *Add folder, files or zip…* in the sidebar) and pick:

- an unpacked HVSC folder (pick the `C64Music` folder),
- loose `.sid` files,
- a `.zip` containing either.

You can also open a `.sid` file in SIDtune from the Files app or another app's share sheet. Tunes you import are copied into SIDtune, so
they stay available offline. If an imported tune has the same path as one in the online catalogue, your copy wins.

### Song lengths and STIL notes

SID tunes usually loop forever, so SIDtune needs to know how long each one is. HVSC's `DOCUMENTS/Songlengths.md5` provides that, and
`DOCUMENTS/STIL.txt` adds background notes (composer comments, cover versions, trivia) shown in Now Playing. Both are picked up
automatically when you import an HVSC folder, and the online catalogue includes them. You can also load them under *Settings →
Collection data*. Tunes without a known length play for the default length set in Settings (3 minutes unless you change it).

### C64 ROMs

A small number of tunes (RSID tunes and some that rely on BASIC) need the C64's own KERNAL, BASIC and CHARGEN ROMs. These are
copyrighted, so SIDtune cannot include them. If you own copies, add them under *Settings → C64 ROMs*.

## 2. Finding and playing tunes

- **Library** lists everything. Use the sort button to sort by title, composer or release; otherwise tunes are listed by path.
- **Search** (the field at the top) matches title, composer, year and path as you type.
- **Tap a tune** to play it. Next and previous then follow the list you started from, including your current search or sort.
- **Play** and **Shuffle** at the top of a list play the whole list.
- **Shuffle** and **Repeat** sit next to the play button. Repeat cycles through off, all, and one.
- **Seek** with the slider. Seeking is instant once the background render has caught up (see *Instant seeking* below).

### Subtunes

Many SID files contain several tunes (a title tune, in-game music, jingles). Now Playing lists them as numbered chips. The tune starts on
the subtune its author marked as the default.

### Favorites, playlists and history

- **Swipe right** on a tune, or tap the heart, to make it a favorite. Favorites have their own list in the sidebar.
- **Long-press** a tune for *Add to Playlist*, *Share* and more. Create playlists with *New Playlist* in the sidebar; long-press a
  playlist to rename or delete it. In a playlist, *Edit* lets you reorder tunes and swiping left removes one.
- **History** keeps the last 500 tunes you played.

## 3. Now Playing

Tap the tune in the player bar to open Now Playing. On iPad it opens as a column on the right. It shows:

- the title, composer, release and chip details (6581 or 8580, PAL or NTSC, number of SID chips);
- a **visualiser**: a scrolling piano roll of every voice on every SID chip, coloured by waveform, plus an oscilloscope and the filter
  settings;
- **V1, V2, V3** buttons that mute individual voices, handy for picking apart how a tune is built;
- the subtunes, the STIL notes, and buttons to favorite, add to a playlist and share.

## 4. Sound

### Audio quality modes

The button with the mode's name (Magic by default) picks how the chip output is presented:

| Mode | What it does |
|---|---|
| Real | Through a tiny monitor speaker, as most people heard it in the eighties |
| Pure | The raw chip, nothing added |
| Magic | Mild stereo widening, light delay and reverb. The recommended default |
| Epic | The same chain turned up: wide, deep delay and reverb, bold bass |
| Mythic | Everything cranked to 11 |

The same panel has a 3-band equalizer (low, mid, high).

### Emulation settings

Under *Settings → Sound*:

- **Emulation engine**: reSIDfp is the accurate reference; SIDLite is much lighter.
- **SID chip**: *Auto* uses the chip the tune was written for. You can force the original 6581 or the later 8580; they sound noticeably
  different, especially the filter.
- **Machine clock**: PAL or NTSC. This changes tempo and pitch; *Auto* follows the tune.
- **Digi boost** makes sample playback audible on the 8580.
- **Instant seeking** renders the whole tune into memory in the background so the seek slider responds immediately. It uses a second CPU
  thread and about 11 MB of memory per minute of music (tunes up to 5 minutes on iPhone, 10 on iPad). Turn it off to save memory and
  battery; seeks then take a moment.

## 5. Sharing

*Share* in Now Playing (or on a long-pressed tune) sends a link that opens the tune (and subtune) in SIDtune on another iPhone or iPad.

## 6. Appearance

Choose a theme under *Settings → Appearance*: **SIDtune Purple** (the default), **C64 Blue**, **Green Phosphor**, **Amber Phosphor**,
**Monochrome Dark** and **Monochrome Light**. The same section picks the **font**: the system's own, the Apple II's 40-column lettering
(Print Char 21), the C64's (Pet Me 64), or a monospaced font. The two retro fonts are by Kreative Korp. Try C64 Blue with the C64 font, or
Green Phosphor with the Apple II one.

## 7. Controls outside the app

SIDtune keeps playing in the background and with the screen locked. The lock screen, Control Center, headphone buttons and CarPlay can
play, pause, skip and seek.

With a hardware keyboard on iPad:

| Key | Action |
|---|---|
| `Space` | Play or pause |
| `←` / `→` | Seek back or forward 10 seconds |
| `Shift+←` / `Shift+→` | Previous or next tune |
| `1` – `9` | Play subtune 1 to 9 |
| `+` / `-` | Volume up or down |
| `S` | Shuffle on or off |
| `R` | Repeat: off, all, one |
| `F` | Favorite the playing tune |
| `N` | Open or close Now Playing |
| `T` / `Shift+T` | Next or previous theme |
| `?` | This manual |
| `Ctrl+E` | Audio quality and equalizer |
| `Cmd+,` | Settings |

Hold `Cmd` to see them all.

## 8. Your data

- Everything SIDtune stores (imported tunes, playlists, favorites, history, settings) lives on this device. Deleting the app removes it.
- *Settings → Library → Clear library* removes imported tunes, song lengths and STIL notes but keeps favorites and playlists.
- The only network traffic is fetching the online catalogue and the tunes you play from it.

## 9. Troubleshooting

- **No sound**: check the volume. SIDtune plays even with the silent switch on.
- **Stuttering on an older device**: choose SIDLite under *Settings → Sound → Emulation engine*, and turn off Instant seeking.
- **A tune plays silence or garbage**: it may need the C64 ROMs (see *C64 ROMs* above).
- **A tune stops too early or runs on**: its length is missing or wrong in the song-length database; the default length is used instead.

## About the music

The tunes belong to their composers. HVSC is a volunteer archive. SIDtune is free software, inspired by ultraSID but an independent
project. The emulation is libsidplayfp (reSIDfp and SIDLite).
