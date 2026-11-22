@echo off
setlocal
chcp 65001 >nul
title TNote 共同編集の準備
set "probeApp=%LOCALAPPDATA%\Programs\TNote\TNote.exe"
if not exist "%probeApp%" goto missing
set "probeDir=%LOCALAPPDATA%\TNote-check\%RANDOM%-%RANDOM%"
if exist "%probeDir%" goto missing
mkdir "%probeDir%" || goto missing
set "probeFile=%probeDir%\TNote-GUI.txt"
echo TNote GUI check>"%probeFile%"
echo 検証専用のメモが開きます。本文に「入力確認」を追記し、Ctrl+S で保存して、そのウィンドウを閉じてください。
start "" /wait "%probeApp%" "%probeFile%"
powershell -NoProfile -Command "$ok=([IO.File]::ReadAllText($env:probeFile)).Contains('入力確認'); $report=[ordered]@{ok=$ok;version=(Get-Item -LiteralPath $env:probeApp).VersionInfo.ProductVersion;time=[DateTimeOffset]::Now.ToString('o')}; $report|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $env:probeDir 'result.json') -Encoding UTF8; if($ok){Write-Host '保存した文字を確認しました。'}else{Write-Host '保存した文字を確認できませんでした。'}"
pause
exit /b
:missing
echo 検証用ファイルまたはインストール先を準備できませんでした。
pause