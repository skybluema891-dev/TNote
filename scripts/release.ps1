param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version,
    [int]$Build = 0
)
$ErrorActionPreference = 'Stop'
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Set-Location $project

if (-not (Test-Path -LiteralPath '.git')) { throw '先にGitリポジトリを初期化してください。' }
if (git status --porcelain) { throw '未コミットの変更があります。先に内容を確認してコミットしてください。' }
$pubspec = Get-Content -LiteralPath 'pubspec.yaml' -Raw
$match = [regex]::Match($pubspec, '(?m)^version:\s*([0-9.]+)\+([0-9]+)\s*$')
if (-not $match.Success) { throw 'pubspec.yamlのバージョンを読み取れません。' }
if ($Build -le 0) { $Build = [int]$match.Groups[2].Value + 1 }
if (-not (Select-String -LiteralPath 'CHANGELOG.md' -Pattern "^## $([regex]::Escape($Version))" -Quiet)) {
    throw "CHANGELOG.mdに ## $Version の変更内容を先に追加してください。"
}

$pubspec = [regex]::Replace($pubspec, '(?m)^version:\s*[0-9.]+\+[0-9]+\s*$', "version: $Version+$Build")
Set-Content -LiteralPath 'pubspec.yaml' -Value $pubspec -Encoding utf8 -NoNewline
flutter pub get
if ($LASTEXITCODE -ne 0) { throw '依存関係の取得に失敗しました。' }
flutter analyze
if ($LASTEXITCODE -ne 0) { throw '静的解析に失敗しました。' }
flutter test
if ($LASTEXITCODE -ne 0) { throw 'テストに失敗しました。' }

git add pubspec.yaml pubspec.lock CHANGELOG.md
git commit -m "TNote $Version"
if ($LASTEXITCODE -ne 0) { throw 'リリースコミットに失敗しました。' }
git tag "v$Version"
if ($LASTEXITCODE -ne 0) { throw 'タグ作成に失敗しました。' }

$answer = Read-Host "mainとタグ v$Version をGitHubへpushしますか？（はい/いいえ）"
if ($answer -eq 'はい') {
    git push origin main
    if ($LASTEXITCODE -ne 0) { throw 'mainのpushに失敗しました。' }
    git push origin "v$Version"
    if ($LASTEXITCODE -ne 0) { throw 'タグのpushに失敗しました。' }
    Write-Host 'GitHub ActionsのWindows・macOS自動リリースが開始されました。'
} else {
    Write-Host "pushは行いませんでした。後で git push origin main と git push origin v$Version を実行できます。"
}
