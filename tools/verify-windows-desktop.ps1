# Run as the logged-in user. Only the uniquely named disposable text can receive input.
$ErrorActionPreference='Stop'
$reg='HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{5D33876C-42D7-4DBB-B769-859706D4D663}_is1'
$app=Join-Path (Get-ItemProperty -LiteralPath $reg).InstallLocation 'TNote.exe'
$run=Join-Path $env:LOCALAPPDATA ('TNote-check\'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run|Out-Null
$id='TNote-GUI-'+[guid]::NewGuid().ToString('N').Substring(0,12)
$file=Join-Path $run ($id+'.txt')
[IO.File]::WriteAllText($file,"TNote GUI check`r`n",[Text.UTF8Encoding]::new($false))
$result=[ordered]@{ok=$false;version=(Get-Item -LiteralPath $app).VersionInfo.ProductVersion;stage='opening'}
try {
 $start=@{FilePath=$app;WorkingDirectory=(Split-Path -Parent $app);PassThru=$true;ArgumentList=('"'+$file+'"')}
 $process=Start-Process @start
 $limit=(Get-Date).AddSeconds(30)
 do {Start-Sleep -Milliseconds 250;$process.Refresh();if($process.HasExited){throw 'Early exit'}} while(!$process.MainWindowTitle.Contains($id) -and (Get-Date) -lt $limit)
 if(!$process.MainWindowTitle.Contains($id) -or $process.Path -ine $app){throw 'Test window unavailable'}
 Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class TNoteTestFocus {
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
}
"@
 $shell=New-Object -ComObject WScript.Shell
 if(!$shell.AppActivate($process.Id)){throw 'Unable to activate the test window'}
 Start-Sleep -Milliseconds 300
 if([TNoteTestFocus]::GetForegroundWindow() -ne $process.MainWindowHandle){throw 'Test window is not in the foreground'}
 $result.stage='editing'
 $shell.SendKeys('TNoteInputCheck')
 Start-Sleep -Milliseconds 300
 if([TNoteTestFocus]::GetForegroundWindow() -ne $process.MainWindowHandle){throw 'Test window lost focus'}
 $shell.SendKeys('^s')
 $limit=(Get-Date).AddSeconds(8)
 do {Start-Sleep -Milliseconds 250;$text=[IO.File]::ReadAllText($file)}while(!$text.Contains('TNoteInputCheck') -and (Get-Date) -lt $limit)
 if(!$text.Contains('TNoteInputCheck')){throw 'Saved text did not contain the test input'}
 $process.Refresh()
 if(!$process.MainWindowTitle.Contains($id) -or $process.MainWindowTitle.Contains(' *')){throw 'Test document has unsaved changes'}
 if(!$process.CloseMainWindow() -or !$process.WaitForExit(12000)){throw 'Normal close did not finish'}
 $result.ok=$true;$result.stage='saved-and-closed'
} catch {$result.stage=$_.Exception.Message}
finally {$result|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $run 'result.json') -Encoding UTF8}
if(!$result.ok){exit 1}