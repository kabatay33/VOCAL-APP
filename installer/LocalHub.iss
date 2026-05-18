; LocalHub Inno Setup script.
; Build edilen Release klasorunu ve gerekli bagimliliklari paketler,
; kurulum sihirbazi + baslat menusu kisayollari + kaldirici saglar.
;
; Build komutu (Inno Setup 6 yuklu olmali):
;   "C:\Users\<user>\AppData\Local\Programs\Inno Setup 6\ISCC.exe" /DAppVersion=1.0.23 LocalHub.iss
;
; Cikti: installer\Output\LocalHub-Setup-X.Y.Z.exe

#define AppName "LocalHub"
#define AppPublisher "LocalHub"
#define AppURL "https://github.com/kabatay33/LocalHub"
#define AppExeName "LocalHub.exe"
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

; Code signing - imzali setup.exe ciktisi (SignTool 'standard' ile)
; ISCC.exe komutuna /Sstandard=... parametresi publish-release.ps1'den
; gectiriliyor. Lokal calistirmada sign atlanir.
#define SignToolName "standard"

[Setup]
; AppId tek surumler arasinda kalmalidir (ayni installer'in update'i icin)
AppId={{B7E8F392-4D5A-4F1B-9C2D-7E8A1B4F6C9E}
SignTool={#SignToolName}
SignedUninstaller=yes
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}/issues
AppUpdatesURL={#AppURL}/releases
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
LicenseFile=
OutputDir=Output
OutputBaseFilename=LocalHub-Setup-{#AppVersion}
SetupIconFile=..\flutter_app\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExeName}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Modern wizard arayuzu icin koyu renk benzeri
WizardImageStretch=no

[Languages]
Name: "turkish"; MessagesFile: "compiler:Languages\Turkish.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Masaustune kisayol ekle"; GroupDescription: "Ek kisayollar:"; Flags: unchecked
Name: "startupicon"; Description: "Windows ile birlikte baslat"; GroupDescription: "Otomatik baslatma:"; Flags: unchecked
Name: "quicklaunchicon"; Description: "Hizli baslat kisayolu"; GroupDescription: "Ek kisayollar:"; Flags: unchecked; OnlyBelowVersion: 6.1

[Files]
; Flutter Release ciktisinin tamami
Source: "..\flutter_app\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; Updater ek (eski surumlerden gelen kullanicilar icin)
Source: "..\updater\build\updater.exe"; DestDir: "{app}\updater"; Flags: ignoreversion; Check: FileExists(ExpandConstant('..\updater\build\updater.exe'))

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"; IconFilename: "{app}\{#AppExeName}"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; IconFilename: "{app}\{#AppExeName}"; Tasks: desktopicon
Name: "{userappdata}\Microsoft\Internet Explorer\Quick Launch\{#AppName}"; Filename: "{app}\{#AppExeName}"; IconFilename: "{app}\{#AppExeName}"; Tasks: quicklaunchicon

[Registry]
; Windows ile baslatma — HKCU/Run anahtari
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "{#AppName}"; ValueData: """{app}\{#AppExeName}"""; Flags: uninsdeletevalue; Tasks: startupicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; node_modules + uploads + DB dosyalari surekli yazilan dosyalardir,
; kullanicinin verilerini de temizleyelim mi diye soralim?
Type: filesandordirs; Name: "{app}\backend\node_modules"
Type: filesandordirs; Name: "{app}\backend\uploads"
Type: files; Name: "{app}\backend\data.db"
Type: files; Name: "{app}\backend\*.db-journal"
Type: files; Name: "{app}\version.txt"

[Code]
function NeedsAddPath(Param: string): boolean;
var
  OrigPath: string;
begin
  if not RegQueryStringValue(HKEY_CURRENT_USER, 'Environment', 'Path', OrigPath) then
  begin
    Result := True;
    exit;
  end;
  Result := Pos(';' + Param + ';', ';' + OrigPath + ';') = 0;
end;
