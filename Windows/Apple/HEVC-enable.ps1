<#
  .SYNOPSIS
  Enables HEIC/HEIF/HEVC support for the current user. No admin required.

  .DESCRIPTION
  Installs Microsoft Photos, HEIF Image Extensions, and HEVC Video Extensions from Device
  Manufacturer for the current user profile. This is per-user: run it in each profile where
  .HEIC files won't open, as that user (not as SYSTEM or from a separate admin account).

  Install order for each app:
    1. winget, official msstore source (skipped with -SkipWinget or if winget is missing).
    2. Direct download via the store.rg-adguard.net API. Every file must come from a
       *.microsoft.com host and carry a valid Microsoft Authenticode signature, or it is
       deleted and not installed. Dependencies are passed to Add-AppxPackage with the app.

  .PARAMETER Help
  Shows this help and exits.

  .PARAMETER SkipWinget
  Skips winget and uses the direct-download method only.

  .EXAMPLE
  PS> .\HEVC-enable.ps1

  .EXAMPLE
  PS> .\HEVC-enable.ps1 -SkipWinget

  .NOTES
  Exit code 0 = enabled (or already enabled), 1 = failed.
  Based on Enable-HEIC-Extension-Feature.ps1 v2.2.3 by Andrew Larson.

  .LINK
  https://github.com/Andrew-J-Larson/OS-Scripts/blob/main/Windows/Apple/Enable-HEIC-Extension-Feature.ps1
#>

<# Copyright (C) 2024  Andrew Larson (github@drewj.la)
   Modified September 2026 (U.S. Ski & Snowboard IT): winget-first install, download host and
   signature verification, dependency handling, native architecture detection, unattended-safe.

   This program is free software: you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation, either version 3 of the License, or
   (at your option) any later version.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program.  If not, see <https://www.gnu.org/licenses/>. #>

param(
  [Alias("h")]
  [switch]$Help,
  [switch]$SkipWinget
)

if ($Help) {
  Get-Help $PSCommandPath -Full
  exit 0
}

# Appx cmdlets need the Windows PowerShell compatibility layer under PowerShell 7
if ($PSVersionTable.PSEdition -eq 'Core') {
  Import-Module Appx -UseWindowsPowerShell -WarningAction SilentlyContinue
}

# Older Windows PowerShell builds may not offer TLS 1.2 by default
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# Constants (apps install in this order)
Set-Variable -Name APPS -Option Constant -Value @(
  @{
    DisplayName       = 'Microsoft Photos'
    ProductId         = '9WZDNCRFJBH4'
    PackageFamilyName = 'Microsoft.Windows.Photos_8wekyb3d8bbwe'
    Name              = 'Microsoft.Windows.Photos'
  }
  @{
    DisplayName       = 'HEIF Image Extensions'
    ProductId         = '9PMMSR1CGPWG'
    PackageFamilyName = 'Microsoft.HEIFImageExtension_8wekyb3d8bbwe'
    Name              = 'Microsoft.HEIFImageExtension'
  }
  @{
    DisplayName       = 'HEVC Video Extensions from Device Manufacturer'
    ProductId         = '9N4WGH0Z6VHQ'
    PackageFamilyName = 'Microsoft.HEVCVideoExtension_8wekyb3d8bbwe'
    Name              = 'Microsoft.HEVCVideoExtension'
  }
)
Set-Variable -Name MS_PUBLISHER_ID -Option Constant -Value '8wekyb3d8bbwe'
Set-Variable -Name API_URL -Option Constant -Value 'https://store.rg-adguard.net/api/GetFiles'
Set-Variable -Name USER_AGENT -Option Constant -Value ([Microsoft.PowerShell.Commands.PSUserAgent]::Chrome)

# Functions

# Output = $true if reachable. Uses HTTPS instead of ICMP so blocked ping doesn't read as offline.
function Test-Online {
  try {
    [void](Invoke-WebRequest -Uri 'https://www.microsoft.com' -Method Head -UseBasicParsing -TimeoutSec 15)
    return $true
  } catch {
    # Any HTTP response, even an error status, means the internet is reachable
    return [bool]$_.Exception.Response
  }
}

# Output = native OS architecture, even when PowerShell itself runs emulated (e.g. x64 on ARM64)
function Get-NativeArchitecture {
  switch ((Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1).Architecture) {
    0       { 'x86' }
    5       { 'arm' }
    9       { 'x64' }
    12      { 'arm64' }
    default { 'neutral' }
  }
}

# Input  = app hashtable
# Output = $true if the app is installed afterwards
function Install-ViaWinget {
  param([hashtable]$App)
  if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
    Write-Host "  winget not available, skipping."
    return $false
  }
  Write-Host "  Trying winget (msstore)..."
  & winget install --id $App.ProductId --exact --source msstore --silent --accept-package-agreements --accept-source-agreements | Out-Host
  return [bool](Get-AppxPackage -Name $App.Name)
}

# Input  = lookup type and value for the rg-adguard API
# Output = package entries (app and its dependencies, all versions/arches the API lists)
function Get-StorePackages {
  param(
    [ValidateSet('ProductId', 'PackageFamilyName')][string]$Type,
    [string]$Value
  )
  try {
    # API sits behind Cloudflare; get a session cookie first (variable NAME, not $value)
    [void](Invoke-WebRequest -Uri 'https://store.rg-adguard.net' -UserAgent $USER_AGENT -SessionVariable session -UseBasicParsing)
    $body = @{ type = $Type; url = $Value; ring = 'Retail'; lang = 'en-US' }
    $raw = [string](Invoke-RestMethod -Method Post -Uri $API_URL -Body $body -ContentType 'application/x-www-form-urlencoded' -UserAgent $USER_AGENT -WebSession $session)
  } catch {
    Write-Warning "  rg-adguard lookup failed ($Type $Value): $($_.Exception.Message)"
    return @()
  }

  # File names look like: Name_Version_Arch_ResourceId_PublisherId.ext
  $pattern = '<a href="(?<url>[^"]+)"[^>]*>(?<file>[^<]+\.(?:appx|msix|appxbundle|msixbundle))</a>'
  foreach ($m in [regex]::Matches($raw, $pattern, 'IgnoreCase')) {
    $file = $m.Groups['file'].Value.Trim()
    $parts = $file.Split('_')
    $version = $null
    if ($parts.Count -lt 5 -or -not [version]::TryParse($parts[1], [ref]$version)) { continue }
    [pscustomobject]@{
      Url       = [Net.WebUtility]::HtmlDecode($m.Groups['url'].Value)
      FileName  = $file
      Name      = $parts[0]
      Version   = $version
      Arch      = $parts[2].ToLower()
      Publisher = $parts[4].Split('.')[0]
      Type      = [IO.Path]::GetExtension($file).TrimStart('.').ToLower()
    }
  }
}

# Picks the newest usable package per name: a bundle if one exists, otherwise one for this
# machine's architecture, otherwise a neutral one. Microsoft-published packages only.
function Select-Packages {
  param([object[]]$Packages, [string]$Arch)
  $Packages | Where-Object { $_.Publisher -eq $MS_PUBLISHER_ID } | Group-Object Name | ForEach-Object {
    $group = $_
    $byNewest = $group.Group | Sort-Object Version -Descending
    $pick = $byNewest | Where-Object { $_.Type -like '*bundle' } | Select-Object -First 1
    if (-not $pick) { $pick = $byNewest | Where-Object { $_.Arch -eq $Arch } | Select-Object -First 1 }
    if (-not $pick) { $pick = $byNewest | Where-Object { $_.Arch -eq 'neutral' } | Select-Object -First 1 }
    if ($pick) { $pick } else { Write-Warning "  No $Arch package listed for $($group.Name); skipping it." }
  }
}

# Output = $true if this version (or newer) is already installed, matching arch for frameworks
function Test-PackageSatisfied {
  param([object]$Package)
  $installed = @(Get-AppxPackage -Name $Package.Name -ErrorAction SilentlyContinue)
  if ($Package.Type -notlike '*bundle' -and $Package.Arch -ne 'neutral') {
    $installed = @($installed | Where-Object { $_.Architecture.ToString() -eq $Package.Arch })
  }
  return [bool]($installed | Where-Object { [version]$_.Version -ge $Package.Version })
}

# Downloads one package, then rejects it unless it came from Microsoft and is Microsoft-signed.
# Output = path to the verified file. Throws on any failure.
function Save-VerifiedPackage {
  param([object]$Package, [string]$Folder)
  $uri = [uri]$Package.Url
  if ($uri.Host -notmatch '(^|\.)microsoft\.com$') {
    throw "Refusing $($Package.FileName): unexpected download host '$($uri.Host)'."
  }

  $dest = Join-Path $Folder $Package.FileName
  Write-Host "  Downloading $($Package.FileName)..."
  $previous = $ProgressPreference
  $ProgressPreference = 'SilentlyContinue' # Invoke-WebRequest is very slow with the progress bar on
  try {
    Invoke-WebRequest -Uri $uri -OutFile $dest -UseBasicParsing
  } finally {
    $ProgressPreference = $previous
  }

  # Links are often plain HTTP, so the signature is the real integrity check
  $sig = Get-AuthenticodeSignature -FilePath $dest
  if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
    Remove-Item $dest -Force -ErrorAction SilentlyContinue
    throw "Signature check failed for $($Package.FileName) (status: $($sig.Status))."
  }
  return $dest
}

# Input  = app hashtable, native arch, download folder
# Output = $true if the app is installed afterwards
function Install-ViaDirectDownload {
  param([hashtable]$App, [string]$Arch, [string]$Folder)
  # ProductId first; the API sometimes fails on one lookup type but not the other
  $lookups = @(
    @{ Type = 'ProductId'; Value = $App.ProductId },
    @{ Type = 'PackageFamilyName'; Value = $App.PackageFamilyName }
  )
  foreach ($lookup in $lookups) {
    Write-Host "  Trying direct download ($($lookup.Type))..."
    $packages = @(Select-Packages -Packages @(Get-StorePackages -Type $lookup.Type -Value $lookup.Value) -Arch $Arch)
    $main = $packages | Where-Object { $_.Name -eq $App.Name } | Select-Object -First 1
    if (-not $main) {
      Write-Warning "  $($App.Name) not found in API results."
      continue
    }
    $deps = @($packages | Where-Object { $_.Name -ne $App.Name -and -not (Test-PackageSatisfied $_) })

    try {
      $depPaths = @(foreach ($dep in $deps) { Save-VerifiedPackage -Package $dep -Folder $Folder })
      $mainPath = Save-VerifiedPackage -Package $main -Folder $Folder
      if ($depPaths.Count -gt 0) {
        Add-AppxPackage -Path $mainPath -DependencyPath $depPaths -ErrorAction Stop
      } else {
        Add-AppxPackage -Path $mainPath -ErrorAction Stop
      }
    } catch {
      Write-Warning "  Install failed: $($_.Exception.Message)"
      continue
    }

    if (Get-AppxPackage -Name $App.Name) { return $true }
  }
  return $false
}

# MAIN

# Appx installs are per-user, so this must run as the person who needs HEIC support
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$consoleUser = (Get-CimInstance -ClassName Win32_ComputerSystem).UserName # null over RDP; check skipped then
if ($currentUser.IsSystem -or ($consoleUser -and ($consoleUser -ne $currentUser.Name))) {
  Write-Host "Run this as the signed-in user, not as SYSTEM or a separate admin account."
  exit 1
}

if (-not (Test-Online)) {
  Write-Host "Can't reach the internet. Connect and try again."
  exit 1
}

$arch = Get-NativeArchitecture
$downloadFolder = Join-Path $env:TEMP ("HEVC-enable_" + [guid]::NewGuid().ToString('N'))
$installedCount = 0
$exitCode = 1

try {
  foreach ($app in $APPS) {
    if (Get-AppxPackage -Name $app.Name) {
      Write-Host "`"$($app.DisplayName)`" already installed."
      continue
    }

    Write-Host "Installing `"$($app.DisplayName)`"..."
    $ok = $false
    if (-not $SkipWinget) { $ok = Install-ViaWinget -App $app }
    if (-not $ok) {
      if (-not (Test-Path $downloadFolder)) { [void](New-Item $downloadFolder -ItemType Directory -Force) }
      $ok = Install-ViaDirectDownload -App $app -Arch $arch -Folder $downloadFolder
    }

    if ($ok) {
      $installedCount++
      Write-Host "  Installed."
    } else {
      Write-Warning "  Couldn't install `"$($app.DisplayName)`"."
    }
  }

  # Confirm all three, not just HEVC
  $missing = @($APPS | Where-Object { -not (Get-AppxPackage -Name $_.Name) })
  if ($missing.Count -gt 0) {
    Write-Host "HEIC support NOT fully enabled. Missing: $(($missing | ForEach-Object { $_.DisplayName }) -join ', ')"
  } elseif ($installedCount -gt 0) {
    Write-Host "HEIC support enabled."
    $exitCode = 0
  } else {
    Write-Host "HEIC support was already enabled. No changes made."
    $exitCode = 0
  }
} catch {
  Write-Host "Unexpected error: $($_.Exception.Message)"
} finally {
  if (Test-Path $downloadFolder) { Remove-Item $downloadFolder -Recurse -Force -ErrorAction SilentlyContinue }
}

exit $exitCode
