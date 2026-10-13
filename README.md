<p align="center"><img src="docs/icon.png" width="112" alt="drill"></p>

<h1 align="center">drill</h1>

<p align="center">
  <a href="https://github.com/mmerioles/drill/releases/latest"><img src="https://img.shields.io/github/v/release/mmerioles/drill?style=flat-square&color=2B2A2F&label=version" alt="version"></a>
  <a href="https://github.com/mmerioles/drill/actions/workflows/release.yml"><img src="https://img.shields.io/github/actions/workflow/status/mmerioles/drill/release.yml?style=flat-square&label=build" alt="build"></a>
  <img src="https://img.shields.io/badge/macOS-15%2B-2B2A2F?style=flat-square&logo=apple" alt="macOS 15+">
  <img src="https://img.shields.io/badge/android-8%2B-2B2A2F?style=flat-square&logo=android" alt="android 8+">
  <img src="https://img.shields.io/badge/windows-10%2B-2B2A2F?style=flat-square" alt="windows 10+">
</p>

<p align="center">
  a quiet pomodoro timer<br>
  <a href="https://mmerioles.github.io/drill/"><b>mmerioles.github.io/drill</b></a>
</p>

<p align="center">
  <img src="docs/screenshots/light-running.png" width="49%" alt="light">
  <img src="docs/screenshots/dark.png" width="49%" alt="dark">
</p>

## install

download from **[mmerioles.github.io/drill](https://mmerioles.github.io/drill/)**. it picks the right file for your device.

- **mac**: open the .dmg, drag drill into applications.
- **windows**: run the installer. if windows warns you: more info → run anyway.
- **android**: open the .apk and allow installs if asked.

updates install themselves.

## sync

press sync and sign in. to use your own server instead:

```sh
docker run -d -p 8080:8080 -v drill-data:/data ghcr.io/mmerioles/drill:latest
```

then put its address under server in settings. details in [docs/SYNC.md](docs/SYNC.md).

## repo

`mac/` · `windows/` · `android/` · `ios/` · `web/` (web app, sync server, site) · `shared/` · `docs/` · `supabase/`

## shortcuts

`space` start/pause · `⌘/ctrl →` skip · `⌘/ctrl R` reset · `⌘/ctrl ,` settings
