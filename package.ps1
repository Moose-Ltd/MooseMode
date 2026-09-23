param(
    [string]$OutDir = (Join-Path $PSScriptRoot "dist")
)

# Builds the CurseForge release zip: MooseMode-<version>.zip containing only
# the MooseMode folder (no tools, installer, README or git metadata).

$ErrorActionPreference = "Stop"

$addon = Join-Path $PSScriptRoot "MooseMode"
$toc   = Join-Path $addon "MooseMode.toc"
if (-not (Test-Path $toc)) { throw "TOC not found: $toc" }

$versionLine = Get-Content $toc | Where-Object { $_ -match '^## Version:\s*(.+)$' } | Select-Object -First 1
if (-not $versionLine) { throw "No ## Version line in $toc" }
$version = ($versionLine -replace '^## Version:\s*', '').Trim()

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force $OutDir | Out-Null }
$zip = Join-Path $OutDir "MooseMode-$version.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }

# Stage a clean copy so the archive's top level is MooseMode/.
$stage = Join-Path $env:TEMP ("MooseMode-package-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force $stage | Out-Null
try {
    Copy-Item -Recurse $addon (Join-Path $stage "MooseMode")
    Get-ChildItem -Recurse -Force (Join-Path $stage "MooseMode") -Include "*.bak", "Thumbs.db", ".DS_Store" | Remove-Item -Force
    # Dev.lua marks a linked development install (written by install.ps1); never ship it.
    $dev = Join-Path $stage "MooseMode\Dev.lua"
    if (Test-Path $dev) { Remove-Item -Force $dev }
    # MooseModeDev.toc belongs to the dev link (install.ps1); never ship it either.
    $devToc = Join-Path $stage "MooseMode\MooseModeDev.toc"
    if (Test-Path $devToc) { Remove-Item -Force $devToc }
    Compress-Archive -Path (Join-Path $stage "MooseMode") -DestinationPath $zip -CompressionLevel Optimal
} finally {
    Remove-Item -Recurse -Force $stage
}

$size = [math]::Round((Get-Item $zip).Length / 1KB)
Write-Host "Built $zip ($size KB)"
