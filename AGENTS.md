# agents

- Platforms: `mac/` (Swift package; `DrillCore`/`InkKit` are shared with the future `ios/`), `windows/` (.NET), `android/` (Kotlin), `web/` (web app `static/`, sync server `server.py`, download site `site/`). Each has a README.
- `shared/inspo.json` is the one shared data file. After editing it run `scripts/make-inspo.sh`, which regenerates `mac/Sources/DrillApp/InspoVideos.swift`, `web/static/inspo-videos.js` and `android/.../core/InspoVideos.kt`. Don't edit those by hand.
- Sync protocol: `docs/SYNC.md`. Keep every client and the server in step with it.
- Tests:
  - mac: `cd mac && swift test`
  - android: `cd android && ./gradlew test`
  - windows: `dotnet test windows/Drill.Core.Tests`
  - web: `python3 -m unittest discover -s web`
- Every push to `main` cuts a release (`.github/workflows/release.yml`, version from conventional commits via `scripts/next-version.sh`). Use `feat:`/`fix:` prefixes.
- `supabase/migrations/` filenames must match the version Supabase applied them under. Never rename them.
