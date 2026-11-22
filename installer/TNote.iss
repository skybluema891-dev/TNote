#define MyAppName "TNote"
#ifndef MyAppVersion
  #error MyAppVersion must be supplied from pubspec.yaml by tools/build-installer.ps1
#endif
#ifndef MyBuildNumber
  #error MyBuildNumber must be supplied from pubspec.yaml
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
CloseApplications=no
RestartApplications=no
SetupMutex=TNote.Setup.5D33876C
VersionInfoVersion={#MyAppVersion}.{#MyBuildNumber}
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
Root: HKA; Subkey: "Software\Classes\TNote.TextDocument"; ValueType: string; ValueData: "TNote テキスト文書"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\TNote.TextDocument\DefaultIcon"; ValueType: string; ValueData: "{app}\{#MyAppExeName},0"
Root: HKA; Subkey: "Software\Classes\TNote.TextDocument\shell\open\command"; ValueType: string; ValueData: """{app}\{#MyAppExeName}"" ""%1"""
Root: HKA; Subkey: "Software\Classes\.txt\OpenWithProgids"; ValueType: none; ValueName: "TNote.TextDocument"; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.md\OpenWithProgids"; ValueType: none; ValueName: "TNote.TextDocument"; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.markdown\OpenWithProgids"; ValueType: none; ValueName: "TNote.TextDocument"; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.log\OpenWithProgids"; ValueType: none; ValueName: "TNote.TextDocument"; Flags: uninsdeletevalue

[Run]
Filename: "{tmp}\vc_redist.x64.exe"; Parameters: "/install /quiet /norestart"; StatusMsg: "必要なWindows実行環境を確認しています..."; Flags: waituntilterminated; Check: NeedsVCRuntime
Filename: "{app}\{#MyAppExeName}"; Description: "TNoteを起動する"; Flags: nowait postinstall skipifsilent

[Code]
const
  RunningMutex = 'TNote.Running.5D33876C';
  UninstallKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{5D33876C-42D7-4DBB-B769-859706D4D663}_is1';
  ReparsePoint = $400;
  DirectoryAttribute = $10;
  UpdateVersion = '{#MyAppVersion}+{#MyBuildNumber}';

var
  AutomaticUpdate: Boolean;
  BackupReady: Boolean;
  InstallStarted: Boolean;
  InstallCompleted: Boolean;
  RollbackDir: String;

function OpenProcess(Access: LongWord; Inherit: Boolean; ProcessID: LongWord): THandle;
  external 'OpenProcess@kernel32.dll stdcall';
function WaitForSingleObject(Handle: THandle; Milliseconds: LongWord): LongWord;
  external 'WaitForSingleObject@kernel32.dll stdcall';
function CloseHandle(Handle: THandle): Boolean;
  external 'CloseHandle@kernel32.dll stdcall';
function GetFileAttributes(FileName: String): LongWord;
  external 'GetFileAttributesW@kernel32.dll stdcall';

function InitializeSetup(): Boolean;
var
  Parent: Integer;
  ProcessHandle: THandle;
begin
  AutomaticUpdate := ExpandConstant('{param:TNOTEUPDATEPID|}') <> '';
  Result := True;
  if not AutomaticUpdate then Exit;
  Parent := StrToIntDef(ExpandConstant('{param:TNOTEUPDATEPID|}'), 0);
  Result := False;
  if Parent <= 0 then Exit;
  ProcessHandle := OpenProcess($100000, False, Parent);
  if ProcessHandle <> 0 then begin
    try
      Result := WaitForSingleObject(ProcessHandle, 30000) = 0;
    finally
      CloseHandle(ProcessHandle);
    end;
  end else begin
    // ERROR_INVALID_PARAMETER: the launching process has already exited.
    Result := DLLGetLastError = 87;
  end;
end;

function CopyRegularTree(const Source, Destination: String): Boolean;
var
  Entry: TFindRec;
  Src, Dst: String;
begin
  Result := False;
  if not DirExists(Source) or ((GetFileAttributes(Source) and ReparsePoint) <> 0) then Exit;
  if DirExists(Destination) and ((GetFileAttributes(Destination) and ReparsePoint) <> 0) then Exit;
  if not ForceDirectories(Destination) then Exit;
  if FindFirst(AddBackslash(Source) + '*', Entry) then begin
    try
      repeat
        if (Entry.Name <> '.') and (Entry.Name <> '..') then begin
          if (Entry.Attributes and ReparsePoint) <> 0 then Exit;
          Src := AddBackslash(Source) + Entry.Name;
          Dst := AddBackslash(Destination) + Entry.Name;
          if (Entry.Attributes and DirectoryAttribute) <> 0 then begin
            if not CopyRegularTree(Src, Dst) then Exit;
          end else begin
            if FileExists(Dst) and ((GetFileAttributes(Dst) and ReparsePoint) <> 0) then Exit;
            if not FileCopy(Src, Dst, False) then Exit;
          end;
        end;
      until not FindNext(Entry);
    finally
      FindClose(Entry);
    end;
  end;
  Result := True;
end;

function SnapshotApplication(const AppDir: String): Boolean;
var
  Entry: TFindRec;
begin
  Result := False;
  if not ForceDirectories(RollbackDir) then Exit;
  if not CopyRegularTree(AddBackslash(AppDir) + 'data', RollbackDir + '\data') then Exit;
  if FindFirst(AddBackslash(AppDir) + '*', Entry) then begin
    try
      repeat
        if (CompareText(Entry.Name, 'TNote.exe') = 0) or
           (CompareText(Entry.Name, 'native_assets.json') = 0) or
           (CompareText(ExtractFileExt(Entry.Name), '.dll') = 0) then begin
          if (Entry.Attributes and (ReparsePoint or DirectoryAttribute)) <> 0 then Exit;
          if not FileCopy(AddBackslash(AppDir) + Entry.Name,
                          AddBackslash(RollbackDir) + Entry.Name, True) then Exit;
        end;
      until not FindNext(Entry);
    finally
      FindClose(Entry);
    end;
  end;
  Result := FileExists(AddBackslash(RollbackDir) + 'TNote.exe');
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  AppDir, Registered: String;
begin
  Result := '';
  if CheckForMutexes(RunningMutex) then begin
    Result := '開いているTNoteを保存して閉じてから、もう一度実行してください。';
    Exit;
  end;
  if not AutomaticUpdate then Exit;
  AppDir := ExpandConstant('{app}');
  if not RegQueryStringValue(HKCU64, UninstallKey, 'InstallLocation', Registered) or
     (CompareText(RemoveBackslashUnlessRoot(Registered), RemoveBackslashUnlessRoot(AppDir)) <> 0) or
     not FileExists(AddBackslash(AppDir) + 'TNote.exe') or
     ((GetFileAttributes(AppDir) and ReparsePoint) <> 0) then begin
    Result := '現在のインストール先を確認できません。';
    Exit;
  end;
  RollbackDir := AddBackslash(AppDir) + '.tnote-update-rollback';
  if DirExists(RollbackDir) or FileExists(RollbackDir) then begin
    Result := '前回の更新用バックアップが残っています。';
    Exit;
  end;
  BackupReady := SnapshotApplication(AppDir);
  if not BackupReady then begin
    // This directory was created by this installation attempt only.
    DelTree(RollbackDir, True, True, True);
    Result := '更新前のアプリを退避できなかったため、更新しませんでした。';
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssInstall then InstallStarted := True;
  if CurStep = ssDone then begin
    InstallCompleted := True;
    if BackupReady then
      SaveStringToFile(AddBackslash(RollbackDir) + '.installed-version', UpdateVersion, False);
  end;
end;

procedure DeinitializeSetup();
begin
  if BackupReady and not InstallCompleted then begin
    if (not InstallStarted) or CopyRegularTree(RollbackDir, ExpandConstant('{app}')) then
      DelTree(RollbackDir, True, True, True)
    else
      Log('Application rollback could not finish. Previous application is retained in ' + RollbackDir);
  end;
end;

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

