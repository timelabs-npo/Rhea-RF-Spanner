#Requires -Version 5.1
<#
Create one local PKCS#10 request for the Rhea iOS distribution certificate.
The exportable private key stays in this Windows user's cryptographic store.
Only the public CSR and a nonsecret request marker are written to this folder.
This script neither issues/revokes an Apple certificate nor writes GitHub secrets.
#>
[CmdletBinding()]
param([switch]$ValidateOnly, [string]$Email)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($ValidateOnly) {
    Write-Output 'Request script loaded; no key generated or files written.'
    return
}
if ($Email -notmatch '^[A-Za-z0-9.!#$%&''*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$') {
    throw 'Pass the Apple account email used for this certificate request.'
}

$certreq = (Get-Command certreq.exe -CommandType Application -ErrorAction Stop).Source
if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    throw 'The current Windows user has no LOCALAPPDATA directory.'
}
$directory = Join-Path $env:LOCALAPPDATA 'RheaRFSpanner\Signing\398XACWZ7G-2026'
$requestPath = Join-Path $directory 'RheaRFSpanner.certSigningRequest'
$markerPath = Join-Path $directory 'request-created.json'
$infPath = Join-Path $directory 'request.inf'
$container = 'RheaRFSpanner-398XACWZ7G-Distribution-2026'

if (Test-Path -LiteralPath $requestPath -PathType Leaf) {
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        throw 'An untracked request already exists. Refusing to replace it or generate another key.'
    }
    $existing = [System.IO.File]::ReadAllText($requestPath)
    if ($existing -notmatch '-----BEGIN CERTIFICATE REQUEST-----' -or
        $existing -notmatch '-----END CERTIFICATE REQUEST-----') {
        throw 'The existing request is incomplete. Preserve the key and inspect the pending request before retrying.'
    }
    Write-Output ('Existing public CSR reused: ' + $requestPath)
    return
}
if (Test-Path -LiteralPath $markerPath) {
    throw 'A previous key-generation attempt is recorded. Refusing to generate another key; inspect the pending request first.'
}
[void][System.IO.Directory]::CreateDirectory($directory)
# CreateNew prevents a concurrent or repeated invocation from replacing state.
$marker = [System.IO.File]::Open($markerPath, [System.IO.FileMode]::CreateNew,
    [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
try {
    $metadata = @{ TeamID = '398XACWZ7G'; KeyContainer = $container;
        ProviderName = 'Microsoft Enhanced RSA and AES Cryptographic Provider';
        ProviderType = 24; KeySpec = 2; Context = 'CurrentUser';
        CreatedUtc = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($metadata)
    $marker.Write($bytes, 0, $bytes.Length)
} finally { $marker.Dispose() }

$inf = @'
[Version]
Signature="$Windows NT$"
[NewRequest]
Subject = "CN=Rhea RF Spanner Distribution 2026, E=__REQUEST_EMAIL__"
KeyContainer = "RheaRFSpanner-398XACWZ7G-Distribution-2026"
ProviderName = "Microsoft Enhanced RSA and AES Cryptographic Provider"
ProviderType = 24
KeySpec = AT_SIGNATURE
KeyLength = 2048
KeyAlgorithm = RSA
HashAlgorithm = SHA256
KeyUsage = 0x80
MachineKeySet = FALSE
Exportable = TRUE
UseExistingKeySet = FALSE
RequestType = PKCS10
Silent = TRUE
'@
$inf = $inf.Replace('__REQUEST_EMAIL__', $Email)
[System.IO.File]::WriteAllText($infPath, $inf, [System.Text.Encoding]::ASCII)
$toolOutput = & $certreq -new -user -q $infPath $requestPath 2>&1
$result = $LASTEXITCODE
$toolOutput = $null
if ($result -ne 0 -or -not (Test-Path -LiteralPath $requestPath -PathType Leaf)) {
    throw ('certreq did not complete (exit ' + $result + '). Keep the marker and inspect the pending request before retrying; no automatic key deletion or replacement was attempted.')
}
$request = [System.IO.File]::ReadAllText($requestPath)
$request = $request.Replace('BEGIN NEW CERTIFICATE REQUEST', 'BEGIN CERTIFICATE REQUEST').Replace('END NEW CERTIFICATE REQUEST', 'END CERTIFICATE REQUEST')
if ($request -notmatch '-----BEGIN CERTIFICATE REQUEST-----' -or
    $request -notmatch '-----END CERTIFICATE REQUEST-----') {
    throw 'certreq returned an unexpected request format. The private key and request marker were preserved.'
}
[System.IO.File]::WriteAllText($requestPath, $request, [System.Text.Encoding]::ASCII)
Write-Output ('Public CSR ready: ' + $requestPath)
Write-Output 'The matching RSA-2048 private key remains in this Windows user cryptographic store. Keep this Windows user profile until certificate installation and encrypted export are complete.'
