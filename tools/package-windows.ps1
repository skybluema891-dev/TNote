param(
    [string]$Destination = (Join-Path $PSScriptRoot '..\..\artifacts\TNote-Windows')
)
$ErrorActionPreference = 'Stop'
$tnoteProject = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$tnoteSource = Join-Path $tnoteProject 'build\windows\x64\runner\Release'
$tnoteDestination = [IO.Path]::GetFullPath($Destination)
if (-not (Test-Path -LiteralPath (Join-Path $tnoteSource 'TNote.exe'))) {
    throw '先にFlutterプロジェクト内で flutter build windows --release を実行してください。'
}
if (Test-Path -LiteralPath $tnoteDestination) {
    throw '既存ファイル保護のため、まだ存在しない出力フォルダを指定してください。'
}
New-Item -ItemType Directory -Path $tnoteDestination | Out-Null
Get-ChildItem -LiteralPath $tnoteSource -Force | Copy-Item -Destination $tnoteDestination -Recurse
Write-Output "配置先: $tnoteDestination"
Write-Output 'TNote.exeだけではなく、このフォルダ全体を任意の場所へコピーして使用してください。'
Write-Output 'ユーザーデータの保存先は、アプリ内の保存ダイアログで別途選択します。'
