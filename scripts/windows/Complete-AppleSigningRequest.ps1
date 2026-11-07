#Requires -Version 5.1
<#
Complete the existing Rhea Windows CSR with an Apple-issued iOS Distribution CER.
Never generates/replaces a key or installs a trusted root. P12 export stays in
memory; its recovery copy and generated password are protected together with
CurrentUser DPAPI. Only the two distribution secrets are sent to GitHub stdin.
No build, provisioning-profile change, certificate revocation, or upload occurs.
#>
[CmdletBinding()]
param([string]$CertificatePath, [switch]$ValidateOnly)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = 'timelabs-npo/Rhea-RF-Spanner'
$environmentName = 'testflight'
$teamID = '398XACWZ7G'
$container = 'RheaRFSpanner-398XACWZ7G-Distribution-2026'
$provider = 'Microsoft Enhanced RSA and AES Cryptographic Provider'
$script:safeFailure = ''

function Require-Condition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { $script:safeFailure = $Message; throw 'Completion check failed.' }
}

function Invoke-PrivateProcess {
    param([string]$Executable, [string[]]$Arguments, [string]$InputText = '')
    foreach ($argument in $Arguments) {
        Require-Condition ($argument -notmatch '["\r\n]') 'Invalid subprocess argument.'
    }
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $Executable
    $start.Arguments = ($Arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    $inputBytes = $null
    $previousInputEncoding = [Console]::InputEncoding
    try {
        # .NET Framework constructs StandardInput during Start and can write
        # Console.InputEncoding's BOM before a direct BaseStream write. PS 5.1
        # has no ProcessStartInfo.StandardInputEncoding; select UTF-8 without
        # a preamble for this process launch and restore the console afterward.
        [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $inputBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($InputText)
        $stream = $process.StandardInput.BaseStream
        $stream.Write($inputBytes, 0, $inputBytes.Length)
        $stream.Flush()
        $stream.Close()
        if (-not $process.WaitForExit(45000)) {
            $process.Kill()
            [void]$process.WaitForExit(5000)
            return -1
        }
        [void]$stdout.GetAwaiter().GetResult()
        [void]$stderr.GetAwaiter().GetResult()
        return $process.ExitCode
    } finally {
        [Console]::InputEncoding = $previousInputEncoding
        if ($null -ne $inputBytes) { [Array]::Clear($inputBytes, 0, $inputBytes.Length) }
        $process.Dispose()
    }
}

function Get-Sha256 {
    param([byte[]]$Bytes)
    $hash = [System.Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($hash.ComputeHash($Bytes)).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
}

function Get-ApplePublicCertificate {
    param([string]$Uri, [string]$ExpectedSha256)
    $request = [System.Net.HttpWebRequest]::Create($Uri)
    $request.Timeout = 15000
    $request.ReadWriteTimeout = 15000
    $request.AllowAutoRedirect = $false
    $response = $request.GetResponse()
    $memory = New-Object System.IO.MemoryStream
    try {
        $response.GetResponseStream().CopyTo($memory)
        $data = $memory.ToArray()
        Require-Condition ((Get-Sha256 $data) -ceq $ExpectedSha256) 'The public Apple CA download did not match the reviewed certificate fingerprint.'
        return [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($data)
    } finally { $memory.Dispose(); $response.Dispose() }
}

function Confirm-AppleCertificateSignature {
    param($SubjectCertificate, $IssuerCertificate)
    if (-not ('RheaAppleCertificateVerifier' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class RheaAppleCertificateVerifier {
    [DllImport("crypt32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool CryptVerifyCertificateSignatureEx(
        IntPtr provider, uint encoding, uint subjectType, IntPtr subject,
        uint issuerType, IntPtr issuer, uint flags, IntPtr extra);
}
'@
    }
    # Public-certificate signature verification only; no private key is read.
    return [RheaAppleCertificateVerifier]::CryptVerifyCertificateSignatureEx(
        [IntPtr]::Zero, 1, 2, $SubjectCertificate.Handle, 2,
        $IssuerCertificate.Handle, 1, [IntPtr]::Zero)
}

if ($ValidateOnly) {
    Write-Output 'Completion definitions loaded; no certificates read, keys opened, files written, or secrets sent.'
    return
}

$stage = 'initial checks'
$completed = 0
$key = $null
$certificate = $null
$publicKey = $null
$chain = $null
$intermediate = $null
$root = $null
$passwordBytes = $null
$p12Bytes = $null
$clearBackup = $null
$secretValues = @{}
try {
    Add-Type -AssemblyName System.Security
    Require-Condition (-not [string]::IsNullOrWhiteSpace($CertificatePath)) 'Supply the downloaded public Apple certificate using -CertificatePath.'
    Require-Condition ([System.IO.File]::Exists($CertificatePath)) 'The supplied Apple certificate file does not exist.'
    $CertificatePath = [System.IO.Path]::GetFullPath($CertificatePath)
    $gh = (Get-Command gh.exe -CommandType Application -ErrorAction Stop).Source
    $certreq = (Get-Command certreq.exe -CommandType Application -ErrorAction Stop).Source
    $directory = Join-Path $env:LOCALAPPDATA 'RheaRFSpanner\Signing\398XACWZ7G-2026'
    $marker = Get-Content -LiteralPath (Join-Path $directory 'request-created.json') -Raw | ConvertFrom-Json
    Require-Condition ($marker.TeamID -ceq $teamID -and $marker.KeyContainer -ceq $container -and $marker.ProviderName -ceq $provider -and $marker.ProviderType -eq 24 -and $marker.KeySpec -eq 2 -and $marker.Context -ceq 'CurrentUser') 'The request marker does not identify this application and Windows key.'
    $result = Invoke-PrivateProcess $gh @('api', "repos/$repository/environments/$environmentName")
    Require-Condition ($result -eq 0) 'GitHub authentication or access to the existing testflight environment failed.'

    $stage = 'matching the existing key and certificate'
    $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($CertificatePath)
    $commonName = $certificate.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
    $subject = $certificate.SubjectName.Decode([System.Security.Cryptography.X509Certificates.X500DistinguishedNameFlags]::UseNewLines)
    Require-Condition ($commonName.StartsWith('iPhone Distribution:') -and $subject -match '(?m)^OU\s*=\s*"?398XACWZ7G"?\s*$') 'This must be an iOS Distribution certificate for Apple team 398XACWZ7G.'
    Require-Condition ($null -ne $certificate.Extensions['1.2.840.113635.100.6.1.4']) 'The certificate lacks the Apple iOS Distribution marker.'
    # Windows does not understand Apple's critical distribution marker. Check
    # every critical leaf extension explicitly before handling that known error.
    $criticalExtensions = @{
        '2.5.29.19' = '3000';                       # End entity, not a CA.
        '2.5.29.37' = '300A06082B06010505070303';     # Code-signing EKU only.
        '2.5.29.15' = '03020780';                   # Digital-signature key usage.
        '1.2.840.113635.100.6.1.4' = '0500'         # Apple iOS Distribution marker.
    }
    foreach ($oid in $criticalExtensions.Keys) {
        $extensions = @($certificate.Extensions | Where-Object { $_.Oid.Value -ceq $oid })
        Require-Condition ($extensions.Count -eq 1 -and $extensions[0].Critical -and [BitConverter]::ToString($extensions[0].RawData).Replace('-', '') -ceq $criticalExtensions[$oid]) 'A required critical distribution-certificate extension has unexpected semantics.'
    }
    foreach ($extension in $certificate.Extensions) {
        Require-Condition (-not $extension.Critical -or $criticalExtensions.ContainsKey($extension.Oid.Value)) 'The certificate has an unsupported critical extension.'
    }
    Require-Condition ($certificate.NotBefore.ToUniversalTime() -le [DateTime]::UtcNow -and $certificate.NotAfter.ToUniversalTime() -gt [DateTime]::UtcNow) 'The Apple distribution certificate is not currently valid.'
    Require-Condition ($certificate.PublicKey.Oid.Value -eq '1.2.840.113549.1.1.1') 'The certificate must contain the requested RSA public key.'
    $parameters = [System.Security.Cryptography.CspParameters]::new(24, $provider, $container)
    $parameters.KeyNumber = 2
    # UseExistingKey is mandatory: this constructor must never generate a key.
    $parameters.Flags = [System.Security.Cryptography.CspProviderFlags]::UseExistingKey -bor [System.Security.Cryptography.CspProviderFlags]::NoPrompt
    $key = [System.Security.Cryptography.RSACryptoServiceProvider]::new($parameters)
    $key.PersistKeyInCsp = $true
    $publicKey = $certificate.PublicKey.Key
    Require-Condition ($key.KeySize -eq 2048 -and $publicKey.KeySize -eq 2048 -and $key.CspKeyContainerInfo.Exportable) 'The pending key must be the original exportable RSA-2048 signing key.'
    $pendingPublic = $key.ExportParameters($false)
    $issuedPublic = $publicKey.ExportParameters($false)
    Require-Condition (([Convert]::ToBase64String($pendingPublic.Modulus) -ceq [Convert]::ToBase64String($issuedPublic.Modulus)) -and ([Convert]::ToBase64String($pendingPublic.Exponent) -ceq [Convert]::ToBase64String($issuedPublic.Exponent))) 'The downloaded certificate does not match this Windows private key. No certificate was installed.'

    $stage = 'checking the pinned Apple issuer chain'
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    # Public Apple PKI files reviewed over HTTPS. No root trust-store changes.
    $g3Hash = 'dcf21878c77f4198e4b4614f03d696d89c66c66008d4244e1b99161aac91601f'
    $rootHash = 'b0b1730ecbc7ff4505142c49f1295e6eda6bcaed7e2c68c5be91b5a11001f024'
    $intermediate = Get-ApplePublicCertificate 'https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer' $g3Hash
    $root = Get-ApplePublicCertificate 'https://www.apple.com/appleca/AppleIncRootCertificate.cer' $rootHash
    $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
    $chain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
    $chain.ChainPolicy.VerificationFlags = [System.Security.Cryptography.X509Certificates.X509VerificationFlags]::AllowUnknownCertificateAuthority
    $chain.ChainPolicy.UrlRetrievalTimeout = [TimeSpan]::FromSeconds(10)
    [void]$chain.ChainPolicy.ExtraStore.Add($intermediate)
    [void]$chain.ChainPolicy.ExtraStore.Add($root)
    $built = $chain.Build($certificate)
    Require-Condition ($chain.ChainElements.Count -eq 3) 'The leaf certificate did not form the expected Apple distribution chain.'
    Require-Condition ((Get-Sha256 $chain.ChainElements[1].Certificate.RawData) -ceq $g3Hash -and (Get-Sha256 $chain.ChainElements[2].Certificate.RawData) -ceq $rootHash) 'The certificate chain does not match the pinned Apple WWDR G3 and Apple Root certificates.'
    $appleMarkerStatus = [System.Security.Cryptography.X509Certificates.X509ChainStatusFlags]::HasNotSupportedCriticalExtension -bor [System.Security.Cryptography.X509Certificates.X509ChainStatusFlags]::InvalidExtension
    $untrustedRootStatus = [System.Security.Cryptography.X509Certificates.X509ChainStatusFlags]::UntrustedRoot
    foreach ($chainStatus in $chain.ChainStatus) {
        Require-Condition (($chainStatus.Status -band (-bnot ($appleMarkerStatus -bor $untrustedRootStatus))) -eq 0) 'The Apple certificate chain has an unexpected validation error.'
    }
    $leafStatus = 0
    for ($index = 0; $index -lt 3; $index++) {
        $allowedStatus = 0
        if ($index -eq 0) { $allowedStatus = $appleMarkerStatus }
        if ($index -eq 2) { $allowedStatus = $untrustedRootStatus }
        foreach ($elementStatus in $chain.ChainElements[$index].ChainElementStatus) {
            Require-Condition (($elementStatus.Status -band (-bnot $allowedStatus)) -eq 0) 'An Apple chain element has an unexpected validation error.'
            if ($index -eq 0) { $leafStatus = $leafStatus -bor $elementStatus.Status }
        }
    }
    Require-Condition ($built -or (($leafStatus -band [System.Security.Cryptography.X509Certificates.X509ChainStatusFlags]::HasNotSupportedCriticalExtension) -ne 0)) 'Windows rejected the chain for a reason other than the explicitly checked Apple critical marker.'
    Require-Condition ($certificate.SignatureAlgorithm.Value -eq '1.2.840.113549.1.1.11' -and $intermediate.SignatureAlgorithm.Value -eq '1.2.840.113549.1.1.11') 'The leaf and intermediate must use RSA with SHA-256 certificate signatures.'
    Require-Condition ((Confirm-AppleCertificateSignature $certificate $intermediate) -and (Confirm-AppleCertificateSignature $intermediate $root)) 'An Apple issuer signature failed direct Windows cryptographic verification.'

    $stage = 'installing the matched certificate'
    $caStore = [System.Security.Cryptography.X509Certificates.X509Store]::new('CA', 'CurrentUser')
    try {
        $caStore.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        $caStore.Add($intermediate)
    } finally { $caStore.Close() }
    # certreq links and removes the pending request when Windows accepts it.
    # If Windows lacks the Apple trusted root, associate the already-matched
    # CAPI key directly instead. This installs no root and grants no root trust.
    $acceptResult = Invoke-PrivateProcess $certreq @('-accept', '-user', '-q', $CertificatePath)
    $myStore = [System.Security.Cryptography.X509Certificates.X509Store]::new('My', 'CurrentUser')
    try {
        $myStore.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        $installed = $myStore.Certificates.Find([System.Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint, $certificate.Thumbprint, $false)
        if ($acceptResult -ne 0 -or $installed.Count -ne 1 -or -not $installed[0].HasPrivateKey) {
            $certificate.PrivateKey = $key
            $myStore.Add($certificate)
        }
        $installed = $myStore.Certificates.Find([System.Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint, $certificate.Thumbprint, $false)
        Require-Condition ($installed.Count -eq 1 -and $installed[0].HasPrivateKey) 'The matched certificate could not be linked to the existing Windows private key.'
        $certificate = $installed[0]
    } finally { $myStore.Close() }

    $stage = 'preparing the protected recovery copy'
    $backupDirectory = Join-Path $directory 'Recovery'
    [void][System.IO.Directory]::CreateDirectory($backupDirectory)
    $owner = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetOwner($owner)
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @($owner, [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')
        [void]$acl.AddAccessRule($rule)
    }
    [System.IO.Directory]::SetAccessControl($backupDirectory, $acl)
    $backupPath = Join-Path $backupDirectory ($certificate.Thumbprint + '.dpapi')
    $entropy = [System.Text.Encoding]::UTF8.GetBytes('RheaRFSpanner.TestFlight.398XACWZ7G.v1')
    if ([System.IO.File]::Exists($backupPath)) {
        $clearBackup = [System.Security.Cryptography.ProtectedData]::Unprotect([System.IO.File]::ReadAllBytes($backupPath), $entropy, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        $recovery = [System.Text.Encoding]::UTF8.GetString($clearBackup) | ConvertFrom-Json
        Require-Condition ($recovery.TeamID -ceq $teamID -and $recovery.CertificateSha256 -ceq (Get-Sha256 $certificate.RawData)) 'The protected recovery copy does not match the current Apple certificate.'
        $secretValues['APPLE_DISTRIBUTION_P12_BASE64'] = $recovery.P12Base64
        $secretValues['APPLE_DISTRIBUTION_P12_PASSWORD'] = $recovery.Password
    } else {
        $passwordBytes = New-Object byte[] 32
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($passwordBytes) } finally { $rng.Dispose() }
        $secretValues['APPLE_DISTRIBUTION_P12_PASSWORD'] = [Convert]::ToBase64String($passwordBytes)
        $collection = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
        [void]$collection.Add($certificate)
        [void]$collection.Add($intermediate)
        $p12Bytes = $collection.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $secretValues['APPLE_DISTRIBUTION_P12_PASSWORD'])
        $secretValues['APPLE_DISTRIBUTION_P12_BASE64'] = [Convert]::ToBase64String($p12Bytes)
        $recovery = @{ Version = 1; TeamID = $teamID; CertificateSha256 = (Get-Sha256 $certificate.RawData);
            P12Base64 = $secretValues['APPLE_DISTRIBUTION_P12_BASE64']; Password = $secretValues['APPLE_DISTRIBUTION_P12_PASSWORD'] }
        $clearBackup = [System.Text.Encoding]::UTF8.GetBytes(($recovery | ConvertTo-Json -Compress))
        $protected = [System.Security.Cryptography.ProtectedData]::Protect($clearBackup, $entropy, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        $backupFile = [System.IO.File]::Open($backupPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try { $backupFile.Write($protected, 0, $protected.Length) } finally { $backupFile.Dispose() }
    }
    Require-Condition ($secretValues['APPLE_DISTRIBUTION_P12_BASE64'].Length -le 49152 -and $secretValues['APPLE_DISTRIBUTION_P12_BASE64'].Length -gt 0 -and -not [string]::IsNullOrEmpty($secretValues['APPLE_DISTRIBUTION_P12_PASSWORD'])) 'The exported distribution secret is empty or exceeds GitHub secret size limits.'

    $stage = 'storing the distribution secrets in GitHub'
    foreach ($name in @('APPLE_DISTRIBUTION_P12_BASE64', 'APPLE_DISTRIBUTION_P12_PASSWORD')) {
        $result = Invoke-PrivateProcess $gh @('secret', 'set', $name, '--repo', $repository, '--env', $environmentName) $secretValues[$name]
        Require-Condition ($result -eq 0) ('GitHub secret update failed after ' + $completed + ' completed updates. Keep the DPAPI recovery copy and rerun this completion script; no key regeneration is needed.')
        $completed++
    }
    Write-Output ('Stored both distribution secrets in ' + $repository + ' / testflight.')
    Write-Output ('Public certificate thumbprint: ' + $certificate.Thumbprint)
    Write-Output ('CurrentUser DPAPI recovery copy: ' + $backupPath)
    Write-Output 'No trusted root, provisioning profile, build, or TestFlight upload was added or started. Local chain verification did not check certificate revocation.'
} catch {
    if ($script:safeFailure) { [Console]::Error.WriteLine($script:safeFailure) }
    else { [Console]::Error.WriteLine('Completion stopped during ' + $stage + ' (error code ' + $_.Exception.HResult + '). Credential values and raw subprocess output were suppressed.') }
    [Console]::Error.WriteLine(('Completed GitHub secret updates: ' + $completed + '. The original Windows key was not deleted or replaced.'))
    exit 1
} finally {
    foreach ($buffer in @($passwordBytes, $p12Bytes, $clearBackup)) {
        if ($null -ne $buffer) { [Array]::Clear($buffer, 0, $buffer.Length) }
    }
    $secretValues.Clear()
    $recovery = $null
    if ($null -ne $chain) { $chain.Dispose() }
    if ($null -ne $publicKey) { $publicKey.Dispose() }
    if ($null -ne $certificate) { $certificate.Dispose() }
    if ($null -ne $intermediate) { $intermediate.Dispose() }
    if ($null -ne $root) { $root.Dispose() }
    if ($null -ne $key) { $key.PersistKeyInCsp = $true; $key.Dispose() }
}
