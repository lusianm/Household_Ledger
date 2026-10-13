#ifndef AppVersion
  #error AppVersion must be supplied by the GitHub build script
#endif
#ifndef AppBuild
  #error AppBuild must be supplied by the GitHub build script
#endif
[Setup]
AppId={{BA3E5F3A-3568-4A44-8948-A24F96AD8B21}
AppName=차곡
AppVersion={#AppVersion}
VersionInfoVersion={#AppVersion}.{#AppBuild}
DefaultDirName={localappdata}\Programs\Chagok
DefaultGroupName=차곡
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\build\dist
OutputBaseFilename=chagok-windows-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\chagok.exe
UsePreviousAppDir=yes
CloseApplications=yes
RestartApplications=no
; Application-support data is outside {app}; updates never delete the ledger.
[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
[Icons]
Name: "{group}\차곡"; Filename: "{app}\chagok.exe"
[Run]
Filename: "{app}\chagok.exe"; Description: "차곡 실행"; Flags: nowait postinstall skipifsilent
