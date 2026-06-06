param(
  [string]$Version = "1.4.0",
  [switch]$BuildInstaller
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $root "dist"
$zip = Join-Path $dist "lekalo_cutting.zip"
$rbz = Join-Path $dist "lekalo_cutting.rbz"
$checksum = "$rbz.sha256"

New-Item -ItemType Directory -Force -Path $dist | Out-Null
Remove-Item -Force -ErrorAction SilentlyContinue $zip, $rbz, $checksum

Compress-Archive `
  -Path (Join-Path $root "lekalo_cutting.rb"), (Join-Path $root "lekalo_cutting") `
  -DestinationPath $zip `
  -CompressionLevel Optimal

Move-Item -Path $zip -Destination $rbz
$hash = (Get-FileHash -Algorithm SHA256 -Path $rbz).Hash.ToLowerInvariant()
"$hash  lekalo_cutting.rbz" | Set-Content -Encoding ASCII -NoNewline $checksum

if ($BuildInstaller) {
  $isccCommand = Get-Command iscc.exe -ErrorAction SilentlyContinue
  $isccPath = if ($isccCommand) { $isccCommand.Source } else { $null }
  if (-not $isccPath) {
    $knownPaths = @(
      "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
      "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
      "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
    )
    $isccPath = $knownPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $isccPath) {
      throw "Inno Setup 6 не найден. Установите его или запустите сборку без -BuildInstaller."
    }
  }
  & $isccPath "/DAppVersion=$Version" (Join-Path $root "installer\LekaloCutting.iss")
  if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup завершился с кодом $LASTEXITCODE."
  }
}

Write-Host "RBZ: $rbz"
Write-Host "SHA256: $hash"
