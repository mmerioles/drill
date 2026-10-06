<p align="center"><img src="docs/icon.png" width="112" alt="tetodoro"></p>

<h1 align="center">tetodoro</h1>

<p align="center">
  <a href="https://github.com/mmerioles/tetodoro/releases/latest"><img src="https://img.shields.io/github/v/release/mmerioles/tetodoro?style=flat-square&color=2B2A2F&label=version" alt="version"></a>
  <a href="https://github.com/mmerioles/tetodoro/actions/workflows/release.yml"><img src="https://img.shields.io/github/actions/workflow/status/mmerioles/tetodoro/release.yml?style=flat-square&label=build" alt="build"></a>
  <img src="https://img.shields.io/badge/macOS-15%2B-2B2A2F?style=flat-square&logo=apple" alt="macOS 15+">
  <img src="https://img.shields.io/badge/android-8%2B-2B2A2F?style=flat-square&logo=android" alt="android 8+">
</p>

<p align="center">
  a quiet pomodoro timer<br>
  <a href="https://mmerioles.github.io/tetodoro/"><b>mmerioles.github.io/tetodoro</b></a>
</p>

<p align="center">
  <img src="docs/screenshots/light-running.png" width="49%" alt="light">
  <img src="docs/screenshots/dark.png" width="49%" alt="dark">
</p>

- pomodoro timer with auto breaks
- tag what you're studying
- a year heatmap of your focus time
- menu bar countdown on mac, a notification countdown on android
- light and dark themes
- a self-hosted web app that syncs through your own server

## install

**[download the latest .dmg](https://mmerioles.github.io/tetodoro/)**, open it, and drag tetodoro into Applications.
needs macOS 15+. on first open, if macOS can't verify the app: system settings → privacy & security → open anyway.

or build it yourself (needs `xcode-select --install`):

```sh
git clone https://github.com/mmerioles/tetodoro.git && cd tetodoro && ./scripts/install.sh
```

update with `git pull && ./scripts/install.sh`.

### android

open **[the site](https://mmerioles.github.io/tetodoro/)** on your phone and tap download: it
picks the apk for you. open the download, and if android asks, let your browser install apps.
needs android 8+. updates install the same way, over the top; settings shows when one is out.
building it yourself is in [android/README.md](android/README.md).

## web app and sync server

tetodoro also runs in the browser, served by a small self-hosted server that
is also the sync server. syncing needs an account (just an email and a
password), and each account keeps its own history. it's one container:

```sh
docker run -d --name tetodoro -p 8080:8080 \
  -e TETODORO_PUBLIC_URL=https://tetodoro.example.com \
  -v tetodoro-data:/data --restart unless-stopped \
  ghcr.io/mmerioles/tetodoro:latest
```

or `cd web && docker compose up -d`. open the server in a browser, or put its
address under server in the mac app's settings, then press sync to sign in or
create an account. confirmation emails go out through `TETODORO_MAIL_URL` (any endpoint
that takes `{ to, subject, text }`, such as a Cloudflare Worker); until
that's set, the links are printed to the server log. the details are in the
[sync protocol](docs/SYNC.md).

the server is plain Python with no dependencies, so `python3 web/server.py`
works too (data goes to `web/data`).

## shortcuts

`space` start/pause · `⌘→` skip · `⌘R` reset · `⌘,` settings
