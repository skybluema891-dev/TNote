#define MyAppName "TNote"
#ifndef MyAppVersion
  #error MyAppVersion must be supplied from pubspec.yaml by tools/build-installer.ps1
#endif
#define MyAppPublisher "TNote Project"
#define MyAppExeName "TNote.exe"

[Setup]
AppId={{5D33876C-42D7-4DBB-B769-859706D4D663}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={localappdata}\Programs\TNote
DefaultGroupName=TNote
DisableProgramGroupPage=yes
OutputDir=..\artifacts\installer
OutputBaseFilename=TNoteSetup
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
ChangesAssociations=yes
CloseApplications=yes
RestartApplications=no
VersionInfoVersion={#MyAppVersion}.0
VersionInfoProductName={#MyAppName}
VersionInfoDescription=TNote セットアップ

[Languages]
Name: "japanese"; MessagesFile: "compiler:Languages\Japanese.isl"

[Tasks]
Name: "desktopicon"; Description: "デスクトップにショートカットを作成する"; GroupDescription: "追加のショートカット:"; Flags: unchecked

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\artifacts\runtime\vc_redist.x64.exe"; DestDir: "{tmp}"; Flags: deleteafterinstall

[Icons]
Name: "{group}\TNote"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\TNote"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Registry]
Root: HKA; Subkey: "Software\Classes\.tnote"; ValueType: string; ValueData: "TNote.Document"; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\TNote.Document"; ValueType: string; ValueData: "TNote 文書"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\TNote.Document\DefaultIcon"; ValueType: string; ValueData: "{app}\{#MyAppExeName},0"
Root: HKA; Subkey: "Software\Classes\TNote.Document\shell\open\command"; ValueType: string; ValueData: """{app}\{#MyAppExeName}"" ""%1"""

[Run]
Filename: "{tmp}\vc_redist.x64.exe"; Parameters: "/install /quiet /norestart"; StatusMsg: "必要なWindows実行環境を確認しています..."; Flags: waituntilterminated; Check: NeedsVCRuntime
Filename: "{app}\{#MyAppExeName}"; Description: "TNoteを起動する"; Flags: nowait postinstall skipifsilent

[Code]
function NeedsVCRuntime(): Boolean;
var
  Installed: Cardinal;
begin
  Result :=
    not RegQueryDWordValue(
      HKLM64,
      'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64',
      'Installed',
      Installed
    ) or (Installed <> 1);
end;

