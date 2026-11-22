param(
    [Parameter(Mandatory)][ValidateSet('test', 'build')][string]$Action,
    [string]$Version
)
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$projectParent = Split-Path -Parent $project
$projectName = Split-Path -Leaf $project

function Invoke-Flutter {
    & flutter @args
    if ($LASTEXITCODE -ne 0) { throw "Flutter failed with exit code $LASTEXITCODE." }
}

# Flutter's analysis server and MSBuild need a short ASCII project path.
# SUBST aliases the same files for this invocation, without creating a copy.
$drive = $null
foreach ($letter in 'T','U','V','W','X','Y','Z') {
    $candidate = "${letter}:"
    if (Test-Path -LiteralPath "$candidate\") { continue }
    & subst.exe $candidate $projectParent
    if ($LASTEXITCODE -eq 0) {
        $drive = $candidate
        break
    }
}
if (!$drive) { throw 'No drive letter is available for the temporary build path.' }

$shortProject = Join-Path "$drive\" $projectName
Push-Location -LiteralPath $shortProject
try {
    if ($env:CODEX_VERIFY_DIR -and $env:CODEX_VERIFY_DIR.StartsWith(
        "$project\", [StringComparison]::OrdinalIgnoreCase
    )) {
        $scratch = Join-Path $shortProject $env:CODEX_VERIFY_DIR.Substring($project.Length + 1)
        $env:TEMP = $env:TMP = $env:TMPDIR = $scratch
    }
    $cachedRust = Join-Path $shortProject '.cache\rust-tools'
    if (Test-Path (Join-Path $cachedRust 'cargo\bin\rustup.exe')) {
        $env:CARGO_HOME = Join-Path $cachedRust 'cargo'
        $env:RUSTUP_HOME = Join-Path $cachedRust 'toolchains'
        $env:Path = (Join-Path $env:CARGO_HOME 'bin') + ';' + $env:Path
    }
    if ($Action -eq 'test') {
        Invoke-Flutter analyze
        Invoke-Flutter test --no-pub
    } else {
        $current = [regex]::Match(
            (Get-Content -LiteralPath 'pubspec.yaml' -Raw),
            '(?m)^version:\s*(\d+\.\d+\.\d+)\+\d+\s*$'
        ).Groups[1].Value
        if (!$current -or $Version -ne $current -or !$env:COMMON_APP_RELEASE) {
            throw 'Specify the pubspec version and run this build through common-apps.'
        }
        Invoke-Flutter build windows --release
        $output = Join-Path $shortProject "artifacts\installer\$Version"
        & (Join-Path $shortProject 'tools\build-installer.ps1') -OutputDirectory $output
    }
} finally {
    Pop-Location
    & subst.exe $drive /d
}
