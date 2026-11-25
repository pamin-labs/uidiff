$ErrorActionPreference = 'Stop'

$arch = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
    X64 { 'x64' }
    Arm64 { 'arm64' }
    default { throw 'uidiff: unsupported architecture' }
}

$releases = 'https://github.com/pamin-labs/uidiff/releases'
$versionPattern = '[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?'
$manifestUrl = "$releases/latest/download"
$selectedVersion = $versionPattern
if ($env:UIDIFF_VERSION) {
    $version = $env:UIDIFF_VERSION -creplace '^v', ''
    if ($version -cnotmatch "\A$versionPattern\z") {
        throw 'uidiff: invalid UIDIFF_VERSION'
    }
    $manifestUrl = "$releases/download/v$version"
    $selectedVersion = [regex]::Escape($version)
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $tmp | Out-Null
$staged = $null
try {
    $manifest = Join-Path $tmp 'SHA256SUMS'
    Invoke-WebRequest -UseBasicParsing -Uri "$manifestUrl/SHA256SUMS" -OutFile $manifest
    $pattern = "\A(?<hash>[0-9a-f]{64})[ \t]+(?<asset>uidiff-(?<version>$selectedVersion)-windows-$arch\.exe)\z"
    $entries = @(Get-Content -LiteralPath $manifest | ForEach-Object {
        $entry = [regex]::Match($_, $pattern)
        if ($entry.Success) { $entry }
    })
    if ($entries.Count -ne 1) {
        throw "uidiff: SHA256SUMS: expected one binary entry for windows-$arch"
    }
    $asset = $entries[0].Groups['asset'].Value
    $version = $entries[0].Groups['version'].Value
    $expected = $entries[0].Groups['hash'].Value
    $download = Join-Path $tmp $asset
    Invoke-WebRequest -UseBasicParsing -Uri "$releases/download/v$version/$asset" -OutFile $download
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $download).Hash -ine $expected) {
        throw "uidiff: ${asset}: SHA-256 mismatch"
    }

    $destination = Join-Path $env:LOCALAPPDATA 'Programs/uidiff'
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    $installed = Join-Path $destination 'uidiff.exe'
    if (Test-Path -LiteralPath $installed -PathType Container) {
        throw "uidiff: ${installed}: is a directory"
    }
    $staged = Join-Path $destination ([guid]::NewGuid().ToString())
    Copy-Item -LiteralPath $download -Destination $staged
    Move-Item -LiteralPath $staged -Destination $installed -Force
    Write-Output $installed
} finally {
    if ($staged -and (Test-Path -LiteralPath $staged)) {
        Remove-Item -LiteralPath $staged -Force
    }
    Remove-Item -LiteralPath $tmp -Recurse -Force
}
