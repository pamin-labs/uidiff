$ErrorActionPreference = 'Stop'

$target = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
    X64 { 'x86_64-windows' }
    Arm64 { 'aarch64-windows' }
    default { throw 'Unsupported test architecture' }
}
$root = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
$savedLocalAppData = $env:LOCALAPPDATA
$savedVersion = $env:UIDIFF_VERSION
$fixtureRelease = Join-Path $root 'release'
$env:LOCALAPPDATA = Join-Path $root 'appdata'

# Keep the production URL selection and replace only the download transport.
function Invoke-WebRequest {
    param([switch]$UseBasicParsing, [string]$Uri, [string]$OutFile)
    $prefix = 'https://github.com/pamin-labs/uidiff/releases/'
    if (!$Uri.StartsWith($prefix)) { throw "Unexpected release URL: $Uri" }
    Copy-Item -LiteralPath (Join-Path $fixtureRelease $Uri.Substring($prefix.Length)) -Destination $OutFile
}

try {
    $metadata = python scripts/release/package.py installer-fixture $target zig-out/bin $fixtureRelease
    if ($LASTEXITCODE -ne 0) { throw "Cannot build the release fixture" }
    $version, $asset, $hash = $metadata -split "`t"
    $fixture = Join-Path $fixtureRelease "download/v$version/$asset"

    $installed = Join-Path $env:LOCALAPPDATA 'Programs/uidiff/uidiff.exe'
    $env:UIDIFF_VERSION = "v$version"
    if ((& ./install.ps1) -ne $installed) { throw 'Wrong pinned install path' }
    $env:UIDIFF_VERSION = $null
    if ((& ./install.ps1) -ne $installed) { throw 'Wrong latest install path' }
    & $installed --help | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Installed binary failed to run' }

    Set-Content -LiteralPath $fixture 'corrupt'
    try {
        & ./install.ps1
        throw 'install.ps1 accepted a corrupt asset'
    } catch {
        if ($_.Exception.Message -notlike '*SHA-256 mismatch*') { throw }
    }
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $installed).Hash -ine $hash) {
        throw 'Corrupt download replaced the installed binary'
    }
} finally {
    $env:LOCALAPPDATA = $savedLocalAppData
    $env:UIDIFF_VERSION = $savedVersion
    Remove-Item -LiteralPath $root -Recurse -Force
}
