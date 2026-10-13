# drill for windows

A native windows app (C#, .NET 10, WPF), a port of the mac app with the same
look and every feature. Sessions sync with the mac, android and web apps
([sync protocol](../docs/SYNC.md)).

## layout

- `Drill.Core` — timer engine, storage (SQLite), stats, sync and updates.
  No UI and nothing windows-only, so it builds and tests on any OS. A port
  of `Sources/DrillCore`.
- `Drill.Core.Tests` — its tests (xunit).
- `Drill` — the WPF app: the window, the tray icon and its flyout,
  settings, sign-in and inspo, notifications, and the updater.
- `installer/drill.iss` — the Inno Setup script for the per-user installer.

The inspo list is `Support/inspo.json` at the repo root, built straight in.

## build

Needs the [.NET 10 SDK](https://dotnet.microsoft.com/download). Everything
compiles on mac and linux too (`EnableWindowsTargeting`); only running the
app needs windows.

```sh
dotnet test windows/Drill.Core.Tests          # tests, on any OS
dotnet run --project windows/Drill            # run it (windows)
```

A release build, as CI makes it, for `x64` or `arm64`:

```sh
dotnet publish windows/Drill/Drill.csproj -c Release -r win-x64 --self-contained \
  -p:Version=1.2.3 -p:PublishReadyToRun=true -o build/windows/x64
iscc /DVersion=1.2.3 /DArch=x64 /DSource=build\windows\x64 /DOutputDir=build windows\installer\drill.iss
```

That makes `build/drill_1.2.3_x64.exe`. Releases from main ship both
installers ([release.yml](../.github/workflows/release.yml)); pushes to other
branches build one with screenshots ([windows.yml](../.github/workflows/windows.yml)).

The icon, `Drill/Assets/drill.ico`, comes from `docs/icon.png` by
`scripts/make-windows-icon.sh`.

## trying things out

- `Drill.exe --render <folder>` renders every screen, light and dark, to
  PNGs in the folder and exits, without opening a window. CI uses it for
  screenshots.
- `DRILL_HOME=<folder>` keeps the database and settings there instead of
  `%LOCALAPPDATA%\Drill`.
- `DRILL_FAST=1` shrinks minutes to seconds.
- `DRILL_THEME=light` or `dark` overrides the saved theme.

## where things live

- the app: `%LOCALAPPDATA%\Programs\drill`
- your sessions and settings: `%LOCALAPPDATA%\Drill` (kept on uninstall)
