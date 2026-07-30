; Inno Setup script for Money Manager (Windows desktop installer).
; Packages the same `flutter build windows --release` output used for the
; portable ZIP - the only difference is this one never gets a
; portable.txt marker, so the installed app stores its preferences in the
; user's Windows profile (see lib/state/app_preferences.dart) like any
; normal installed application.
;
; Build with: "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer\money_manager.iss
; (run from the App directory so the relative paths below resolve)

#define MyAppName "Money Manager"
#define MyAppVersion "1.0.18"
#define MyAppPublisher "Money Manager"
#define MyAppExeName "money_manager.exe"
#define MyReleaseDir "..\build\windows\x64\runner\Release"

[Setup]
AppId={{B6C1A6C4-3B4B-4C7B-9B2A-6F5A0F7E9C21}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=..\dist
OutputBaseFilename=MoneyManager-{#MyAppVersion}-setup-win64
SetupIconFile=..\windows\runner\resources\app_icon.ico
Compression=lzma
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\{#MyAppExeName}

[Languages]
Name: "french"; MessagesFile: "compiler:Languages\French.isl"

[Tasks]
Name: "desktopicon"; Description: "Créer un raccourci sur le Bureau"; GroupDescription: "Raccourcis supplémentaires:"; Flags: unchecked

[Files]
; Everything the Flutter Windows build produces (exe, DLLs, data/ assets) -
; deliberately NOT including a portable.txt marker (see app_preferences.dart)
; so the installed app uses the normal per-user Windows storage location.
Source: "{#MyReleaseDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Désinstaller {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Lancer {#MyAppName}"; Flags: nowait postinstall skipifsilent
