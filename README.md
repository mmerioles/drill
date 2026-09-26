<p align="center"><img src="docs/icon.png" width="128" alt="tetodoro icon"></p>

# tetodoro

A quiet pomodoro timer for macOS, with a hand-drawn ink look, a year-long
study heatmap and a Kasane Teto theme. Built to sync across your devices
through your own home server later.

<p align="center">
  <img src="docs/screenshots/light-running.png" width="49%" alt="teto theme, timer running">
  <img src="docs/screenshots/dark.png" width="49%" alt="ink theme, idle">
</p>

## Install

You need macOS 15 or later and Apple's command line tools. If you've never
installed them, run `xcode-select --install` once and click through the prompt.

Then paste this into Terminal:

```sh
git clone https://github.com/mmerioles/tetodoro.git && cd tetodoro && ./scripts/install.sh
```

This builds the app, puts it in `/Applications` (or `~/Applications` if you
can't write to `/Applications`), and opens it. Allow notifications when asked,
so you get a heads-up when a phase ends.

**Update:** `cd tetodoro && git pull && ./scripts/install.sh`. Your sessions
are kept.

**Uninstall:** drag Tetodoro to the Trash. To erase your history too, delete
`~/Library/Application Support/Tetodoro`.

## Use

- Type what you're studying, press **start** (or **space**), and focus.
- The ring fills as the time passes. Breaks start on their own, and the
  dots count toward the long break.
- The heatmap shows a year of focus time. Hover a day to see its total, or
  filter by tag in the top right.
- The drill in the menu bar shows the countdown and has its own
  start/pause/skip panel, so you can close the window while you work.
- **Settings** (⌘,): light/dark, phase lengths, auto-start, sound.

Shortcuts: `space` or `⌘↩` start/pause · `⌘→` skip · `⌘R` reset.

## Develop

```sh
swift test                  # core logic tests
scripts/bundle.sh --open    # build build/Tetodoro.app and launch it
scripts/install.sh          # build and install to /Applications
scripts/make-icon.sh        # regenerate Support/AppIcon.icns from the drill glyph
open Package.swift          # or work in Xcode (scheme: Tetodoro)
```

| env var | effect |
| --- | --- |
| `TETODORO_FAST=1` | focus 20s, short break 5s, long break 10s |
| `TETODORO_DB=/path/x.sqlite` | use another database file instead of your real one |
| `TETODORO_THEME=light\|dark` | override the saved theme |

### Layout

```
Sources/
  TetodoroCore/     no UI; shared by every future client
    Model/          FocusSession: the only record, sync-ready (UUID, updatedAt, tombstone)
    Timer/          PomodoroEngine: pure state machine, time passed in
    Store/          SessionStore protocol + SQLite implementation
    Stats/          HeatmapBuilder: year grid, today/week totals, streak
    Sync/           SyncService protocol (DisabledSync for now), device ID
  InkKit/           the design system: palette, wobble/boil, DoodleRing, glyphs, buttons
  TetodoroApp/      macOS app shell
    AppModel        owns engine and store, drives the clock, logs sessions, theme
    Views/          main window, heatmap, menu bar item + panel, settings
  IconMaker/        renders the app icon from the same InkKit drill as the logo
Tests/TetodoroCoreTests/
Support/            Info.plist, AppIcon.icns
scripts/            bundle, install, make-icon
docs/SYNC.md        wire contract for the home-server sync
```

Dependencies only point downward: App → InkKit, Core. InkKit and Core don't
know about each other, so an iOS app can reuse both.

### Design rules

The look comes from bord's ink prototype (`bord/ios/Bord/Prototypes/ProtoInk.swift`).

- Two themes, each tied to an appearance. **ink** (dark) is pure black and
  white. **teto** (light) uses Kasane Teto's SV palette: off-white paper,
  charcoal and greys, and her crimson as the only accent. The crimson is
  used just for progress: the ring, the heatmap and the logo.
- Strokes are hand-drawn: seeded jitter that "boils" every 0.4s, but only
  while the timer runs. Idle screens and the heatmap stay still. Reduce
  Motion stops all boiling.
- Copy is lowercase and short. Every sentence lives in `Copy.swift`.
- One filled capsule button per screen. Everything else is an underlined word.

### Behaviour notes

- The engine uses deadlines, not counting ticks, so it never drifts. After a
  sleep, the Mac wakes to a single phase transition, not a burst of made-up
  sessions.
- Skipped or reset focus blocks still log the time you actually studied, if
  it was at least a minute.
- Heatmap levels use fixed thresholds (<30m, <1.5h, <3h, 3h+), so a cell's
  shade means the same thing all year.

## Roadmap

1. **mvp (this)**: mac timer, menu bar, tags, heatmap, themes, local SQLite
2. **sync**: small self-hosted server (Docker) implementing `docs/SYNC.md`
3. **ios**: SwiftUI shell over Core + InkKit; widgets and a Live Activity
4. **web**: read-only heatmap served by the home server
5. **later**: edit or delete sessions, launch at login, export, signed downloadable builds
