# drill for mac

The mac app (SwiftUI, macOS 15+), as a Swift package:

- `Sources/DrillCore` — timer engine, storage (SQLite), stats, sync and
  updates. No UI; meant to be shared with an iOS app later.
- `Sources/InkKit` — the hand-drawn ink design system.
- `Sources/DrillApp` — the app: window, menu bar item, settings, sign-in, inspo.
- `Sources/IconMaker` — draws the app icon from InkKit.
- `Tests/DrillCoreTests` — the core's tests.
- `Support` — Info.plist and the icon, bundled into the .app.

Everything below runs from this folder (`cd mac`); the scripts work from anywhere.

```sh
swift test                 # tests
swift run Drill            # run it unbundled (no notifications or updates)
scripts/install.sh         # build Drill.app and put it in /Applications
scripts/bundle.sh --open   # build build/Drill.app and open it
scripts/dmg.sh             # pack build/Drill.app into build/drill_<version>.dmg
scripts/make-icon.sh       # redraw Support/AppIcon.icns and docs/icon.png
```

`DRILL_DB`, `DRILL_FAST=1` and `DRILL_THEME=light|dark` are for trying
things out (see `AppModel.live()`).
