<p align="center"><img src="docs/icon.png" width="112" alt="tetodoro"></p>

<h1 align="center">tetodoro</h1>

<p align="center">
  <a href="https://github.com/mmerioles/tetodoro/releases/latest"><img src="https://img.shields.io/github/v/release/mmerioles/tetodoro?style=flat-square&color=2B2A2F&label=version" alt="version"></a>
  <a href="https://github.com/mmerioles/tetodoro/actions/workflows/release.yml"><img src="https://img.shields.io/github/actions/workflow/status/mmerioles/tetodoro/release.yml?style=flat-square&label=build" alt="build"></a>
  <img src="https://img.shields.io/badge/macOS-15%2B-2B2A2F?style=flat-square&logo=apple" alt="macOS 15+">
</p>

<p align="center">
  a quiet pomodoro timer for mac.<br>
  <a href="https://mmerioles.github.io/tetodoro/"><b>mmerioles.github.io/tetodoro</b></a>
</p>

<p align="center">
  <img src="docs/screenshots/light-running.png" width="49%" alt="light">
  <img src="docs/screenshots/dark.png" width="49%" alt="dark">
</p>

- pomodoro timer with auto breaks
- tag what you're studying
- a year heatmap of your focus time
- menu bar countdown
- light and dark themes

## install

**[download the latest .dmg](https://mmerioles.github.io/tetodoro/)**, open it, and drag tetodoro into Applications.
needs macOS 15+. on first open, if macOS can't verify the app: system settings → privacy & security → open anyway.

or build it yourself (needs `xcode-select --install`):

```sh
git clone https://github.com/mmerioles/tetodoro.git && cd tetodoro && ./scripts/install.sh
```

update with `git pull && ./scripts/install.sh`.

## shortcuts

`space` start/pause · `⌘→` skip · `⌘R` reset · `⌘,` settings
