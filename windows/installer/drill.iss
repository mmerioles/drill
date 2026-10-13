; The windows installer: one per architecture, built by CI after
; `dotnet publish` (see .github/workflows/release.yml):
;
;   iscc /DVersion=1.2.3 /DArch=x64 /DSource=build\windows\x64 /DOutputDir=build drill.iss
;     → build\drill_1.2.3_x64.exe
;
; Installs for the current user only, into %LOCALAPPDATA%\Programs\drill, so
; it never asks for admin. Your sessions live in %LOCALAPPDATA%\Drill and
; stay put through updates and uninstalls. The app updates itself by
; running a newer installer with /VERYSILENT /SUPPRESSMSGBOXES, which waits
; for the old drill to quit and opens the new one when it's done.

#ifndef Version
  #define Version "0.0.0"
#endif
#ifndef Arch
  #define Arch "x64"
#endif
#ifndef Source
  #define Source "..\..\build\windows\" + Arch
#endif
#ifndef OutputDir
  #define OutputDir "..\..\build"
#endif

; Matches the app: its single-instance mutex and its AppUserModelID, which
; ties the Start menu shortcut to the app's notifications and taskbar button.
#define AppMutex "drill-mmerioles-app"
#define AppId "mmerioles.drill"
; Signalling this asks a running drill to quit (see InitializeSetup).
#define QuitEvent "drill-mmerioles-quit"

[Setup]
; Never change AppId: it's how an update finds the install it replaces.
AppId={{6B0C5E2A-6F1D-4E8B-9C3A-D7A1F0E4B2C9}
AppName=drill
AppVersion={#Version}
AppVerName=drill {#Version}
AppPublisher=mmerioles
AppPublisherURL=https://mmerioles.github.io/drill/
AppSupportURL=https://github.com/mmerioles/drill/issues
AppUpdatesURL=https://github.com/mmerioles/drill/releases
VersionInfoVersion={#Version}
VersionInfoProductName=drill
VersionInfoDescription=drill setup
PrivilegesRequired=lowest
DefaultDirName={userpf}\drill
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableWelcomePage=yes
DisableReadyPage=yes
AllowNoIcons=yes
UninstallDisplayName=drill
UninstallDisplayIcon={app}\Drill.exe
SetupIconFile=..\Drill\Assets\drill.ico
WizardStyle=modern
WizardSizePercent=100
OutputDir={#OutputDir}
OutputBaseFilename=drill_{#Version}_{#Arch}
Compression=lzma2/ultra64
SolidCompression=yes
; Restart Manager asks a running drill to close before files are replaced;
; drill relaunches itself afterwards (see [Run]), not through Restart Manager.
CloseApplications=yes
RestartApplications=no
#if Arch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif
MinVersion=10.0.17763

[Messages]
SetupAppTitle=drill
SetupWindowTitle=drill %1
SelectTasksDesc=one small extra.
SelectTasksLabel2=
WizardSelectTasks=almost there
InstallingLabel=putting drill in place…
WizardInstalling=installing
FinishedHeadingLabel=drill is ready
FinishedLabelNoIcons=drill is installed.
FinishedLabel=drill is installed. find it in the start menu.
ClickFinish=
RunEntryExec=open drill
ButtonFinish=&done
ButtonInstall=&install
ExitSetupTitle=leave setup
ExitSetupMessage=drill isn't installed yet. leave anyway?

[Tasks]
Name: desktopicon; Description: "a shortcut on the desktop"; Flags: unchecked

[Files]
Source: "{#Source}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

; Files from the previous version that this one no longer ships are swept
; away, so an update leaves exactly this build behind. Your data isn't here.
[InstallDelete]
Type: filesandordirs; Name: "{app}\*"

[Icons]
Name: "{autoprograms}\drill"; Filename: "{app}\Drill.exe"; AppUserModelID: "{#AppId}"
Name: "{autodesktop}\drill"; Filename: "{app}\Drill.exe"; AppUserModelID: "{#AppId}"; Tasks: desktopicon

[Run]
; By hand: a checkbox on the last page. From the updater (silent): straight back in.
Filename: "{app}\Drill.exe"; Description: "open drill"; Flags: nowait postinstall skipifsilent
Filename: "{app}\Drill.exe"; Flags: nowait; Check: WizardSilent

[Code]
// drill lives in the tray, so it's often running. Setup asks it to quit
// (the app listens for this named event), then waits for it to go, so an
// install or update never has to ask you to quit it by hand. The updater
// also quits drill itself right after starting setup.
function OpenEvent(Access: Cardinal; Inherit: Boolean; Name: String): THandle;
  external 'OpenEventW@kernel32.dll stdcall';
function SetEvent(Handle: THandle): Boolean;
  external 'SetEvent@kernel32.dll stdcall';
function CloseHandle(Handle: THandle): Boolean;
  external 'CloseHandle@kernel32.dll stdcall';

const
  EVENT_MODIFY_STATE = $0002;

procedure AskDrillToQuit();
var
  Handle: THandle;
begin
  Handle := OpenEvent(EVENT_MODIFY_STATE, False, '{#QuitEvent}');
  if Handle <> 0 then begin
    SetEvent(Handle);
    CloseHandle(Handle);
  end;
end;

function WaitForDrill(Milliseconds: Integer): Boolean;
var
  Waited: Integer;
begin
  Waited := 0;
  while CheckForMutexes('{#AppMutex}') and (Waited < Milliseconds) do begin
    Sleep(100);
    Waited := Waited + 100;
  end;
  Result := not CheckForMutexes('{#AppMutex}');
end;

function InitializeSetup(): Boolean;
begin
  Result := True;
  AskDrillToQuit();
  if WaitForDrill(30000) or WizardSilent() then exit;
  // Still open after all that (it shouldn't be): ask, as a last resort.
  while CheckForMutexes('{#AppMutex}') do begin
    if MsgBox('drill is still open. quit it from the tray (right-click its icon, then quit), then press ok.',
              mbInformation, MB_OKCANCEL) <> IDOK then begin
      Result := False;
      exit;
    end;
  end;
end;

function InitializeUninstall(): Boolean;
begin
  Result := True;
  AskDrillToQuit();
  WaitForDrill(10000);
end;
