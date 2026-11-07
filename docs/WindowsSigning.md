# Prepare Apple distribution signing on Windows

These helpers prepare this application's signing identity on the authorized
Windows workstation. They use Windows PowerShell 5.1, native Windows
cryptography, `certreq.exe`, and an authenticated GitHub CLI account with access
to the repository's `testflight` environment. The selected Apple team and key
container are fixed in the scripts; review those settings before adapting them
for another application or team.

The macOS archive, export, and optional upload stages are documented in
[Manual TestFlight distribution](TestFlight.md).

## Recover an existing identity or create a new request

A downloaded `.cer` contains the public certificate. Downloading it again cannot
recover its private key. First look for the original signing machine, an
encrypted P12/PFX backup, or an export from the certificate's creator. Apple's
[missing-key guidance](https://help.apple.com/xcode/mac/current/en.lproj/devd1432da9a.html)
describes these recovery routes.

If the key is unavailable, an authorized Account Holder or Admin can issue a new
distribution certificate from a new CSR. If the portal reports that the
**Apple Distribution** quota is full but offers **iOS Distribution (App Store
Connect and Ad Hoc)**, that certificate type supports this iOS application's
distribution path. Its installed identity is named `iPhone Distribution:`;
the release validator accepts that identity. This option does not require
revoking unrelated team certificates. Availability and limits must be checked
in the authenticated portal; they are not inferred from this guide. See Apple's
[certificate overview](https://developer.apple.com/help/account/certificates/certificates-overview/).

## 1. Create the Windows request once

From PowerShell in the repository:

```powershell
.\scripts\windows\New-AppleSigningRequest.ps1 -ValidateOnly
.\scripts\windows\New-AppleSigningRequest.ps1 -Email (Read-Host 'Apple account email')
```

The first command loads definitions only. The second creates an exportable
RSA-2048 signing key in the current Windows user's cryptographic store and a
SHA-256 PKCS#10 request. Use the public CSR path printed by the script. Upload
that CSR in the selected Apple certificate flow, then download the issued
`.cer` to the same workstation.

The request marker prevents accidental repeated generation. A successful rerun
reuses the CSR; an incomplete attempt stops for inspection. Preserve the Windows
user profile and request state after any error. Do not delete the marker or
generate another key to troubleshoot a later transport or build failure.
The CSR includes the supplied identity metadata and belongs outside source
control. Microsoft's [certreq reference](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/certreq_1)
documents request creation and certificate acceptance.

## 2. Complete and store the distribution identity

```powershell
.\scripts\windows\Complete-AppleSigningRequest.ps1 -ValidateOnly
.\scripts\windows\Complete-AppleSigningRequest.ps1 -CertificatePath 'C:\path\distribution.cer'
```

Completion opens the **existing** key, checks that its RSA public key matches
the certificate, and validates the configured team, certificate type, validity,
and critical extensions before installation. It installs the matching leaf in
`CurrentUser\My` and the Apple intermediate in `CurrentUser\CA`.

The helper exports the leaf, private key, and intermediate as a P12 in memory,
protected with a cryptographically generated password. It writes
`APPLE_DISTRIBUTION_P12_BASE64` and `APPLE_DISTRIBUTION_P12_PASSWORD` to the
existing GitHub environment through standard input. The password and private
key are not displayed or placed in command-line arguments. The helper does not
dispatch the distribution workflow.

### Apple chain verification on Windows

Apple identifies [WWDR G3](https://developer.apple.com/help/account/certificates/wwdr-intermediate-certificates/)
as the intermediate for iOS Distribution. Windows can reject the legitimate
critical Apple distribution marker as unsupported. The helper checks every
critical leaf extension against its expected semantics, pins the downloaded
Apple G3 and root certificates, and verifies both issuer signatures with
[CryptVerifyCertificateSignatureEx](https://learn.microsoft.com/en-us/windows/win32/api/wincrypt/nf-wincrypt-cryptverifycertificatesignatureex).
It rejects unexpected chain errors and critical extensions. The Apple root is
used in memory; it is never installed as a trusted Windows root. Local checks
do not establish current revocation status.

## 3. Preserve recovery and finish the profile

The helper saves the P12 and its generated password together in a **CurrentUser
DPAPI-encrypted** `.dpapi` file. Its recovery directory allows the current user
and SYSTEM. This recovery copy depends on the Windows user's DPAPI credentials
and profile; copying it alone to another computer or account is not a portable
backup. Preserve that profile and arrange an authorized portable backup before
retiring the workstation.

If a GitHub update fails, the helper reports how many secret writes completed.
Rerun completion using the same certificate and Windows user: it reuses the
protected recovery data and password. Do not regenerate the certificate.

Create an **App Store Connect** provisioning profile for the explicit App ID and
select this exact new distribution certificate. Store that profile and the
matching team/bundle variables as described in [TestFlight setup](TestFlight.md#2-protect-the-github-environment).
An ASC API key is needed only for a later explicit upload.

## Validation snapshot — 2026-11-07 UTC

The Windows request, certificate/key matching, installation, encrypted P12
export, and DPAPI recovery path were exercised successfully. Public-certificate
tests accepted both Apple issuer signatures and rejected an incorrect issuer
and a modified signature.

The first attempt of
[signed macOS run 42420624092](https://github.com/timelabs-npo/Rhea-RF-Spanner/actions/runs/42420624092)
failed while decoding base64, before certificate import. A nonsecret stdin
fixture proved that .NET Framework's `Process.StandardInput` writer emitted a
UTF-8 preamble before the helper's direct byte write: input `QUJD` arrived as
seven bytes, `EF BB BF 51 55 4A 44`, instead of four bytes, `51 55 4A 44`.

Both Windows helpers now select `UTF8Encoding(false)` before `Process.Start()`
and restore the caller's input encoding in `finally`. The repeated fixture
received exactly the four intended bytes and confirmed encoding restoration.
The original DPAPI-protected identity was resubmitted; the key and certificate
were not regenerated to fix this transport issue. An intake window that was
already running must be relaunched to load the corrected helper.

**Attempt 2 succeeded:** source `9bed85a1787aafabd919994e38eae66d3169c448`
produced a signed archive and App Store Connect IPA for version **0.2.0**, build
**2**. Local certificate/profile/product checks and cleanup passed. Apple
validation and upload were not requested. See
[signed export validation](SIGNED_EXPORT_VALIDATION.md) for the manifest,
artifact fingerprints, and exact result boundaries.
