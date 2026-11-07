#Requires -Version 5.1
<#
Local Windows credential intake for the Rhea TestFlight environment.
Select existing Apple files in the native dialog. Secret values travel to gh
over redirected standard input, never command-line arguments or saved copies.
This script does not dispatch a build or upload an app to Apple.
#>
[CmdletBinding()]
param([switch]$ValidateOnly)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = 'timelabs-npo/Rhea-RF-Spanner'
$environmentName = 'testflight'

function Invoke-GhPrivate {
    param([string[]]$Arguments, [AllowEmptyString()][string]$InputText = '')
    $gh = (Get-Command gh.exe -CommandType Application -ErrorAction Stop).Source
    # All arguments are fixed strings or validated, nonsecret identifiers.
    foreach ($argument in $Arguments) {
        if ($argument -match '["\r\n]') { throw 'Invalid GitHub CLI argument.' }
    }
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $gh
    $start.Arguments = ($Arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    $previousInputEncoding = [Console]::InputEncoding
    try {
        # Process.Start constructs the StandardInput writer. On .NET Framework
        # it can emit Console.InputEncoding's BOM before a BaseStream write.
        # Select UTF-8 without a preamble, then restore the caller's encoding.
        [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        # Windows PowerShell 5.1 lacks ProcessStartInfo.StandardInputEncoding.
        # Write UTF-8 bytes explicitly, preserving non-ASCII P12 passwords.
        $inputBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($InputText)
        try {
            $stream = $process.StandardInput.BaseStream
            $stream.Write($inputBytes, 0, $inputBytes.Length)
            $stream.Flush()
            $stream.Close()
        } finally {
            [Array]::Clear($inputBytes, 0, $inputBytes.Length)
        }
        if (-not $process.WaitForExit(45000)) {
            $process.Kill()
            throw 'GitHub did not respond within 45 seconds. Check the connection.'
        }
        [void]$stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            # Do not echo subprocess output from a credential-handling command.
            throw ('GitHub CLI failed (exit ' + $process.ExitCode + '). Check login, repository permission, and the testflight environment.')
        }
        return $stdout.GetAwaiter().GetResult().Trim()
    } finally {
        [Console]::InputEncoding = $previousInputEncoding
        $process.Dispose()
    }
}

function Get-ProfileIdentifiers {
    param([string]$Path)
    Add-Type -AssemblyName System.Security
    $cms = New-Object System.Security.Cryptography.Pkcs.SignedCms
    $cms.Decode([System.IO.File]::ReadAllBytes($Path))
    $xmlText = [System.Text.Encoding]::UTF8.GetString($cms.ContentInfo.Content)
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Ignore
    $settings.XmlResolver = $null
    $reader = [System.Xml.XmlReader]::Create((New-Object System.IO.StringReader($xmlText)), $settings)
    $document = New-Object System.Xml.XmlDocument
    $document.XmlResolver = $null
    try { $document.Load($reader) } finally { $reader.Dispose() }
    $team = $document.SelectSingleNode('/plist/dict/key[.="TeamIdentifier"]/following-sibling::*[1]/string')
    $app = $document.SelectSingleNode('/plist/dict/key[.="Entitlements"]/following-sibling::*[1]/key[.="application-identifier"]/following-sibling::*[1]')
    if ($null -eq $team -or $null -eq $app -or $app.InnerText -notmatch '^[^.]+\.(.+)$') {
        throw 'The profile does not contain an explicit iOS application identifier.'
    }
    return @{ Team = $team.InnerText; Bundle = $Matches[1] }
}

function Get-FileSecret {
    param([string]$Path, [string]$Extension)
    if (-not [System.IO.File]::Exists($Path) -or [System.IO.Path]::GetExtension($Path) -ine $Extension) {
        throw ('Select an existing ' + $Extension + ' file.')
    }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    try {
        if ($bytes.Length -eq 0) { throw 'The selected file is empty.' }
        $encoded = [Convert]::ToBase64String($bytes)
        if ($encoded.Length -gt 49152) { throw 'The encoded file exceeds the GitHub secret size limit (48 KB).' }
        return $encoded
    } finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
}

if ($ValidateOnly) {
    Write-Output 'Credential intake definitions loaded; no files read, secrets sent, or dialogs opened.'
    return
}
if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    throw 'Start this Windows form with powershell.exe -STA -File Import-TestFlightCredentials.ps1.'
}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Rhea RF Spanner - Apple signing credentials'
$form.ClientSize = New-Object System.Drawing.Size(780, 620)
$form.StartPosition = 'CenterScreen'
$form.AutoScaleMode = 'Dpi'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$script:importBusy = $false

$notice = New-Object System.Windows.Forms.Label
$notice.SetBounds(20, 15, 740, 85)
$notice.Text = "Destination: $repository / GitHub environment: $environmentName`r`nFiles are read locally and sent to encrypted GitHub Actions secrets through gh.`r`nNo credential copies are saved. No build or TestFlight upload is started. Existing secrets with these names will be replaced."
$form.Controls.Add($notice)

function Add-Field {
    param([string]$Label, [int]$Y, [switch]$Password, [string]$Filter = '')
    $caption = New-Object System.Windows.Forms.Label
    $caption.Text = $Label
    $caption.SetBounds(20, $Y + 4, 230, 25)
    $form.Controls.Add($caption)
    $box = New-Object System.Windows.Forms.TextBox
    $box.SetBounds(255, $Y, 415, 28)
    $box.UseSystemPasswordChar = $Password.IsPresent
    $form.Controls.Add($box)
    if ($Filter) {
        $box.ReadOnly = $true
        $button = New-Object System.Windows.Forms.Button
        $button.Text = 'Browse...'
        $button.SetBounds(680, $Y - 1, 80, 30)
        $button.Tag = @{ Box = $box; Filter = $Filter }
        $button.Add_Click({
            $picker = New-Object System.Windows.Forms.OpenFileDialog
            $picker.Filter = $this.Tag.Filter
            $picker.CheckFileExists = $true
            $picker.Multiselect = $false
            try {
                if ($picker.ShowDialog($form) -eq 'OK') { $this.Tag.Box.Text = $picker.FileName }
            } finally { $picker.Dispose() }
        })
        $form.Controls.Add($button)
    }
    return $box
}

$p12 = Add-Field 'Apple Distribution (.p12)' 110 -Filter 'PKCS#12 certificate and key (*.p12)|*.p12'
$password = Add-Field 'P12 password' 150 -Password
$profile = Add-Field 'App Store profile' 190 -Filter 'Provisioning profile (*.mobileprovision)|*.mobileprovision'
$team = Add-Field 'Apple Team ID' 230
$bundle = Add-Field 'Registered bundle ID' 270
$p8 = Add-Field 'ASC team API key (optional)' 310 -Filter 'Apple API private key (*.p8)|*.p8'
$keyID = Add-Field 'ASC Key ID (if key selected)' 350
$issuer = Add-Field 'ASC Issuer ID (if key selected)' 390
$status = New-Object System.Windows.Forms.Label
$status.SetBounds(20, 435, 740, 110)
$status.Text = 'Select the P12 and App Store profile for archive/export. Add the ASC team API key for a later explicit upload. The runner will validate certificate, profile, team, expiry and app identity.'
$form.Controls.Add($status)

$profile.Add_TextChanged({
    try {
        $identifiers = Get-ProfileIdentifiers $profile.Text
        $team.Text = $identifiers.Team
        $bundle.Text = $identifiers.Bundle
        $status.Text = 'Team and bundle ID read from the profile. This is metadata decoding; full signing validation runs on the Mac.'
    } catch {
        $team.Clear()
        $bundle.Clear()
        $status.Text = 'Could not decode this profile locally. Enter its exact Team ID and registered bundle ID; the Mac will validate them.'
    }
})
$p8.Add_TextChanged({
    if ([System.IO.Path]::GetFileName($p8.Text) -match '^AuthKey_([A-Z0-9]{10})\.p8$') { $keyID.Text = $Matches[1] }
})

$save = New-Object System.Windows.Forms.Button
$save.Text = 'Store in GitHub testflight'
$save.SetBounds(440, 560, 235, 38)
$cancel = New-Object System.Windows.Forms.Button
$cancel.Text = 'Close'
$cancel.SetBounds(685, 560, 75, 38)
$cancel.Add_Click({ $form.Close() })
$form.Controls.AddRange(@($save, $cancel))
$form.CancelButton = $cancel
$form.Add_FormClosing({ if ($script:importBusy) { $_.Cancel = $true } })

$save.Add_Click({
    $secretValues = @{}
    $completed = 0
    try {
        if ($team.Text -cnotmatch '^[A-Z0-9]{10}$') { throw 'Apple Team ID must be 10 uppercase letters/digits.' }
        if ($bundle.Text -notmatch '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$') { throw 'Enter the registered explicit bundle ID (no wildcard).' }
        if ([string]::IsNullOrEmpty($password.Text)) { throw 'Enter the password protecting the P12.' }
        $secretValues['APPLE_DISTRIBUTION_P12_BASE64'] = Get-FileSecret $p12.Text '.p12'
        $secretValues['APPLE_DISTRIBUTION_P12_PASSWORD'] = $password.Text
        $secretValues['APP_STORE_PROFILE_BASE64'] = Get-FileSecret $profile.Text '.mobileprovision'
        $variables = @{ APPLE_TEAM_ID = $team.Text; APP_BUNDLE_ID = $bundle.Text }
        if ($p8.Text) {
            if ($keyID.Text -cnotmatch '^[A-Z0-9]{10}$') { throw 'ASC Key ID must be 10 uppercase letters/digits.' }
            if ($issuer.Text -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') { throw 'Enter the UUID issuer ID of an ASC team API key.' }
            $secretValues['ASC_PRIVATE_KEY_P8_BASE64'] = Get-FileSecret $p8.Text '.p8'
            $variables['ASC_KEY_ID'] = $keyID.Text
            $variables['ASC_ISSUER_ID'] = $issuer.Text
        } elseif ($keyID.Text -or $issuer.Text) {
            throw 'Select the matching P8 file, or clear both ASC identifiers for archive-only setup.'
        }
        $save.Enabled = $false
        $cancel.Enabled = $false
        $script:importBusy = $true
        $status.Text = 'Checking GitHub authentication and the testflight environment...'
        [System.Windows.Forms.Application]::DoEvents()
        [void](Invoke-GhPrivate @('api', "repos/$repository/environments/$environmentName"))
        foreach ($name in ($secretValues.Keys | Sort-Object)) {
            $status.Text = 'Storing ' + $name + ' (value is never displayed)...'
            [System.Windows.Forms.Application]::DoEvents()
            [void](Invoke-GhPrivate @('secret', 'set', $name, '--repo', $repository, '--env', $environmentName) $secretValues[$name])
            $completed++
        }
        foreach ($name in ($variables.Keys | Sort-Object)) {
            [void](Invoke-GhPrivate @('variable', 'set', $name, '--repo', $repository, '--env', $environmentName, '--body', $variables[$name]))
        }
        $status.Text = "Saved $completed encrypted secrets and their nonsecret identifiers to GitHub testflight. No build or upload was started. You may close this window."
    } catch {
        $status.Text = "Setup incomplete. $completed secret updates completed. " + $_.Exception.Message + ' No build or app upload was started.'
    } finally {
        $secretValues.Clear()
        $password.Clear()
        $script:importBusy = $false
        $save.Enabled = $true
        $cancel.Enabled = $true
    }
})
[void]$form.ShowDialog()
$form.Dispose()
