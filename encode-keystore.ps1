# encode-keystore.ps1
#
# Encodes tamiva-upload.jks as base64 for storage as a GitHub Actions
# secret. Run once after generating the keystore (Phase 3 of the
# AAB_BUILD_GUIDE.md).
#
# Usage (PowerShell):
#   PS> .\scripts\encode-keystore.ps1 -JksPath "C:\build-tamiva\tamiva-upload.jks"
#
# The script prints the base64 blob to stdout. Copy that blob into
# the ANDROID_KEYSTORE_BASE64 secret in GitHub:
#   Settings -> Secrets and variables -> Actions -> New repository secret
#
# NEVER commit the keystore or the encoded blob to git. The script
# writes no files; the encoded output lives only in your clipboard
# or terminal scrollback.

param(
    [Parameter(Mandatory = $true)]
    [string]$JksPath
)

if (-not (Test-Path $JksPath)) {
    Write-Error "Keystore not found at $JksPath"
    exit 1
}

$bytes = [System.IO.File]::ReadAllBytes($JksPath)
$base64 = [Convert]::ToBase64String($bytes)

Write-Host "Keystore size: $(($bytes.Length)) bytes"
Write-Host ""
Write-Host "Paste the line below into GitHub Secret ANDROID_KEYSTORE_BASE64:"
Write-Host "(single line, no line breaks)"
Write-Host ""
Write-Host $base64
Write-Host ""
Write-Host "Set the following GitHub secrets too:"
Write-Host "  ANDROID_KEYSTORE_PASSWORD  = your storepass"
Write-Host "  ANDROID_KEY_ALIAS         = tamiva-upload"
Write-Host "  ANDROID_KEY_PASSWORD      = your keypass"