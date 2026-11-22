param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{64}$')][string]$ExpectedHash,
    [Parameter(Mandatory)][string]$Exchange,
    [Parameter(Mandatory)][string]$PrivateState,
    [Parameter(Mandatory)][string]$DisplayName
)
$ErrorActionPreference = 'Stop'
$sourceFile = (Resolve-Path -LiteralPath $Source).Path
$exchangeDir = (Resolve-Path -LiteralPath $Exchange).Path
$localDir = [IO.Path]::GetFullPath($PrivateState)
if ((Get-FileHash -LiteralPath $sourceFile).Hash -ne $ExpectedHash) {
    throw 'バックアップと元ファイルのSHA-256が一致しません。'
}
$drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($localDir))
if ($drive.DriveType -ne [IO.DriveType]::Fixed -or
    $localDir.StartsWith($exchangeDir.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or
    $localDir -eq $exchangeDir) {
    throw '参加キーの退避先には共有先の外にある端末内のフォルダーを指定してください。'
}
[IO.Directory]::CreateDirectory($localDir) | Out-Null
$credentials = [IO.Directory]::CreateDirectory((Join-Path $localDir 'enrollment'))
$protectedPath = Join-Path $credentials.FullName ($ExpectedHash.ToLowerInvariant() + '.dpapi')
$scope = [Security.Cryptography.DataProtectionScope]::CurrentUser
if (![IO.File]::Exists($protectedPath)) {
    $raw = [byte[]]::new(32)
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $part = Join-Path $credentials.FullName ([Guid]::NewGuid().ToString('N') + '.part')
    try {
        $rng.GetBytes($raw)
        $sealed = [Security.Cryptography.ProtectedData]::Protect($raw, $null, $scope)
        [IO.File]::WriteAllBytes($part, $sealed)
        try { [IO.File]::Move($part, $protectedPath) }
        catch [IO.IOException] { if (![IO.File]::Exists($protectedPath)) { throw } }
    } finally {
        $rng.Dispose()
        [Array]::Clear($raw, 0, $raw.Length)
        if ([IO.File]::Exists($part)) { [IO.File]::Delete($part) }
    }
}
$raw = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($protectedPath), $null, $scope)
try {
    if ($raw.Length -ne 32) { throw '保存した参加情報を検証できません。' }
    $key = [Convert]::ToBase64String($raw).Replace('+','-').Replace('/','_')
    $key | & dart run (Join-Path $PSScriptRoot 'stage_collaboration.dart') $sourceFile $ExpectedHash $exchangeDir $localDir $DisplayName
    $result = $LASTEXITCODE
} finally {
    [Array]::Clear($raw, 0, $raw.Length)
    $key = $null
}
if ($result -ne 0) { throw '移行先の独立した読み直しが成功しませんでした。' }
