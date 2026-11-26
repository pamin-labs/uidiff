$ErrorActionPreference = 'Stop'

# Release metadata is checked against the packager.
$program = 'uidiff'
$downloads = 'https://uidiff.paminlabs.com'
$checksums = 'SHA256SUMS'
$releaseOs = 'windows'
$extension = '.exe'
$versionPattern = '[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?'

$arch = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
    X64 { 'x64' }
    Arm64 { 'arm64' }
    default { throw "${program}: unsupported architecture" }
}

$manifestUrl = "$downloads/latest/download"
$selectedVersion = $versionPattern
if ($env:UIDIFF_VERSION) {
    $version = $env:UIDIFF_VERSION -creplace '^v', ''
    if ($version -cnotmatch "\A$versionPattern\z") {
        throw "${program}: invalid UIDIFF_VERSION"
    }
    $manifestUrl = "$downloads/download/v$version"
    $selectedVersion = [regex]::Escape($version)
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $tmp | Out-Null
$staged = $null
try {
    $manifest = Join-Path $tmp $checksums
    Invoke-WebRequest -UseBasicParsing -Uri "$manifestUrl/$checksums" -OutFile $manifest
    $suffix = [regex]::Escape("-$releaseOs-$arch$extension")
    $prefix = [regex]::Escape("$program-")
    $pattern = "\A(?<hash>[0-9a-f]{64})[ \t]+(?<asset>$prefix(?<version>$selectedVersion)$suffix)\z"
    $entries = @(Get-Content -LiteralPath $manifest | ForEach-Object {
        $entry = [regex]::Match($_, $pattern)
        if ($entry.Success) { $entry }
    })
    if ($entries.Count -ne 1) {
        throw "${program}: ${checksums}: expected one binary entry for $releaseOs-$arch"
    }
    $asset = $entries[0].Groups['asset'].Value
    $version = $entries[0].Groups['version'].Value
    $expected = $entries[0].Groups['hash'].Value
    $download = Join-Path $tmp $asset
    Invoke-WebRequest -UseBasicParsing -Uri "$downloads/download/v$version/$asset" -OutFile $download
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $download).Hash -ine $expected) {
        throw "${program}: ${asset}: SHA-256 mismatch"
    }

    $destination = Join-Path $env:LOCALAPPDATA "Programs/$program"
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    $installed = Join-Path $destination "$program$extension"
    if (Test-Path -LiteralPath $installed -PathType Container) {
        throw "${program}: ${installed}: is a directory"
    }
    $staged = Join-Path $destination ([guid]::NewGuid().ToString())
    Copy-Item -LiteralPath $download -Destination $staged
    Move-Item -LiteralPath $staged -Destination $installed -Force
    Write-Output $installed
    if (($env:PATH -split ';') -notcontains $destination) {
        Write-Warning "${program}: add $destination to PATH to run $program"
    }
} finally {
    if ($staged -and (Test-Path -LiteralPath $staged)) {
        Remove-Item -LiteralPath $staged -Force
    }
    Remove-Item -LiteralPath $tmp -Recurse -Force
}
