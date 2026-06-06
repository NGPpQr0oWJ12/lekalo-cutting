#ifndef AppVersion
  #define AppVersion "1.4.0"
#endif

#define AppName "Лекало ткани для SketchUp"
#define AppPublisher "Малкаров Сослан"

[Setup]
AppId={{1BDCF9A2-4BCB-4B3A-A95D-C3E73CB3B493}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\LekaloCutting
DisableDirPage=yes
PrivilegesRequired=lowest
OutputDir=..\dist
OutputBaseFilename=LekaloCuttingSetup_{#AppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
Uninstallable=yes

[Tasks]
Name: "su2021"; Description: "SketchUp 2021"; GroupDescription: "Установить для:"; Check: SketchUpInstalled('2021')
Name: "su2022"; Description: "SketchUp 2022"; GroupDescription: "Установить для:"; Check: SketchUpInstalled('2022')
Name: "su2023"; Description: "SketchUp 2023"; GroupDescription: "Установить для:"; Check: SketchUpInstalled('2023')
Name: "su2024"; Description: "SketchUp 2024"; GroupDescription: "Установить для:"; Check: SketchUpInstalled('2024')
Name: "su2025"; Description: "SketchUp 2025"; GroupDescription: "Установить для:"; Check: SketchUpInstalled('2025')
Name: "su2026"; Description: "SketchUp 2026"; GroupDescription: "Установить для:"; Check: SketchUpInstalled('2026')

[Files]
Source: "..\lekalo_cutting.rb"; DestDir: "{userappdata}\SketchUp\SketchUp 2021\SketchUp\Plugins"; Tasks: su2021; Flags: ignoreversion
Source: "..\lekalo_cutting\*"; DestDir: "{userappdata}\SketchUp\SketchUp 2021\SketchUp\Plugins\lekalo_cutting"; Tasks: su2021; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\lekalo_cutting.rb"; DestDir: "{userappdata}\SketchUp\SketchUp 2022\SketchUp\Plugins"; Tasks: su2022; Flags: ignoreversion
Source: "..\lekalo_cutting\*"; DestDir: "{userappdata}\SketchUp\SketchUp 2022\SketchUp\Plugins\lekalo_cutting"; Tasks: su2022; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\lekalo_cutting.rb"; DestDir: "{userappdata}\SketchUp\SketchUp 2023\SketchUp\Plugins"; Tasks: su2023; Flags: ignoreversion
Source: "..\lekalo_cutting\*"; DestDir: "{userappdata}\SketchUp\SketchUp 2023\SketchUp\Plugins\lekalo_cutting"; Tasks: su2023; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\lekalo_cutting.rb"; DestDir: "{userappdata}\SketchUp\SketchUp 2024\SketchUp\Plugins"; Tasks: su2024; Flags: ignoreversion
Source: "..\lekalo_cutting\*"; DestDir: "{userappdata}\SketchUp\SketchUp 2024\SketchUp\Plugins\lekalo_cutting"; Tasks: su2024; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\lekalo_cutting.rb"; DestDir: "{userappdata}\SketchUp\SketchUp 2025\SketchUp\Plugins"; Tasks: su2025; Flags: ignoreversion
Source: "..\lekalo_cutting\*"; DestDir: "{userappdata}\SketchUp\SketchUp 2025\SketchUp\Plugins\lekalo_cutting"; Tasks: su2025; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\lekalo_cutting.rb"; DestDir: "{userappdata}\SketchUp\SketchUp 2026\SketchUp\Plugins"; Tasks: su2026; Flags: ignoreversion
Source: "..\lekalo_cutting\*"; DestDir: "{userappdata}\SketchUp\SketchUp 2026\SketchUp\Plugins\lekalo_cutting"; Tasks: su2026; Flags: ignoreversion recursesubdirs createallsubdirs

[Code]
function SketchUpInstalled(Version: String): Boolean;
begin
  Result := DirExists(ExpandConstant('{userappdata}\SketchUp\SketchUp ' + Version + '\SketchUp'));
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssDone then
    MsgBox('Расширение установлено. Перезапустите SketchUp.', mbInformation, MB_OK);
end;
