#ifndef MyAppVersion
  #define MyAppVersion "2.2.6"
#endif

#ifndef SourceDir
  #define SourceDir "..\\..\\build\\windows\\x64\\runner\\Release"
#endif

#ifndef OutputDir
  #define OutputDir "..\\..\\dist"
#endif

[Setup]
AppId={{9C3F4B2A-529A-4B8A-A7B9-5C1B9A49267C}
AppName=Kazumi HDR
AppVersion={#MyAppVersion}
AppPublisher=FairyBand
AppPublisherURL=https://github.com/FairyBand/Kazumi_HDR
AppSupportURL=https://github.com/FairyBand/Kazumi_HDR/issues
AppUpdatesURL=https://github.com/FairyBand/Kazumi_HDR/releases/latest
DefaultDirName={autopf}\Kazumi HDR
DefaultGroupName=Kazumi HDR
DisableProgramGroupPage=yes
DisableDirPage=no
UsePreviousAppDir=yes
OutputDir={#OutputDir}
OutputBaseFilename=Kazumi_HDR_{#MyAppVersion}_windows_x64_setup
SetupIconFile=..\..\assets\images\logo\logo_windows.ico
UninstallDisplayIcon={app}\kazumi.exe
UninstallDisplayName=Kazumi HDR
Uninstallable=yes
CloseApplications=yes
RestartApplications=no
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "chinesesimp"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Kazumi HDR\Kazumi HDR"; Filename: "{app}\kazumi.exe"; WorkingDir: "{app}"
Name: "{autoprograms}\Kazumi HDR\Uninstall Kazumi HDR"; Filename: "{uninstallexe}"

[Run]
Filename: "{app}\kazumi.exe"; Description: "{cm:LaunchProgram,Kazumi HDR}"; Flags: nowait postinstall skipifsilent

[Code]
function FindPreviousInstallDirInRoot(const RootKey: Integer): String;
var
  Subkeys: TArrayOfString;
  Index: Integer;
  UninstallKey: String;
  DisplayName: String;
  InstallLocation: String;
begin
  Result := '';
  if not RegGetSubkeyNames(RootKey,
      'Software\Microsoft\Windows\CurrentVersion\Uninstall', Subkeys) then
    exit;

  for Index := 0 to GetArrayLength(Subkeys) - 1 do
  begin
    UninstallKey := 'Software\Microsoft\Windows\CurrentVersion\Uninstall\' + Subkeys[Index];
    if RegQueryStringValue(RootKey, UninstallKey, 'DisplayName', DisplayName) and
       (Pos('Kazumi', DisplayName) > 0) and
       RegQueryStringValue(RootKey, UninstallKey, 'InstallLocation', InstallLocation) and
       DirExists(InstallLocation) then
    begin
      Result := InstallLocation;
      exit;
    end;
  end;
end;

function FindPreviousInstallDir(): String;
begin
  Result := FindPreviousInstallDirInRoot(HKLM);
  if Result = '' then
    Result := FindPreviousInstallDirInRoot(HKCU);
end;

procedure InitializeWizard;
var
  PreviousDir: String;
begin
  PreviousDir := FindPreviousInstallDir();
  if PreviousDir <> '' then
    WizardForm.DirEdit.Text := PreviousDir;
end;
