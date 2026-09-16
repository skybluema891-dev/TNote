param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\artifacts\installer')
)
$ErrorActionPreference = 'Stop'
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$release = Join-Path $project 'build\windows\x64\runner\Release'
$runtime = Join-Path $project 'artifacts\runtime'
$pubspec = Get-Content -LiteralPath (Join-Path $project 'pubspec.yaml') -Raw
$versionMatch = [regex]::Match($pubspec, '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+[0-9]+\s*$')
if (-not $versionMatch.Success) { throw 'pubspec.yamlのバージョンを読み取れません。' }
$version = $versionMatch.Groups[1].Value
$isccCandidates = @(
    'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
    'C:\Program Files\Inno Setup 6\ISCC.exe',
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
)
$iscc = $isccCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $iscc) { throw 'Inno Setup 6 was not found. Run: winget install --id JRSoftware.InnoSetup' }
if (-not (Test-Path -LiteralPath (Join-Path $release 'TNote.exe'))) {
    throw 'Run flutter build windows --release first.'
}
$vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
$vsInstall = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Redist.14.Latest -property installationPath
$redistRoot = Join-Path $vsInstall 'VC\Redist\MSVC'
$redist = Get-ChildItem -LiteralPath $redistRoot -Recurse -Filter vc_redist.x64.exe -File | Sort-Object FullName -Descending | Select-Object -First 1
if (-not $redist) { throw 'Microsoft Visual C++ x64 Redistributable was not found.' }
New-Item -ItemType Directory -Path $runtime -Force | Out-Null
Copy-Item -LiteralPath $redist.FullName -Destination (Join-Path $runtime 'vc_redist.x64.exe') -Force
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
& $iscc (Join-Path $project 'installer\TNote.iss') "/DMyAppVersion=$version" "/O$OutputDirectory"
if ($LASTEXITCODE -ne 0) { throw "Inno Setup compilation failed: $LASTEXITCODE" }
$setup = Join-Path $OutputDirectory 'TNoteSetup.exe'
if (-not (Test-Path -LiteralPath $setup)) { throw 'TNoteSetup.exe was not generated.' }
Get-FileHash -LiteralPath $setup -Algorithm SHA256

