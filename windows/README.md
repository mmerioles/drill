# drill for windows

C# / .NET 10 / WPF. Needs the [.NET 10 SDK](https://dotnet.microsoft.com/download); builds on any OS, runs on windows.

- `Drill.Core` timer, storage, stats, sync (no UI)
- `Drill.Core.Tests` its tests
- `Drill` the app
- `installer/drill.iss` the installer (Inno Setup)

```sh
dotnet test windows/Drill.Core.Tests
dotnet run --project windows/Drill
dotnet publish windows/Drill/Drill.csproj -c Release -r win-x64 --self-contained -p:PublishReadyToRun=true -o build/windows/x64
iscc /DVersion=1.2.3 /DArch=x64 /DSource=build\windows\x64 /DOutputDir=build windows\installer\drill.iss
```

`Drill.exe --render <folder>` saves every screen as PNGs. `DRILL_HOME`, `DRILL_FAST=1` and `DRILL_THEME=light|dark` are for trying things out.
