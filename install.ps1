param(
    [string]$Path = "C:\Games\World of Warcraft\_classic_beta_",
    [switch]$Copy
)

# Installs this repo as a second addon, MooseModeDev, next to the release
# copy the CurseForge app keeps in AddOns\MooseMode:
#
#   AddOns\MooseMode      CurseForge's copy. Installed and updated by the app;
#                         this script never touches it (except to remove an
#                         old dev link from before this layout, see below).
#   AddOns\MooseModeDev   a junction to this repo's MooseMode folder (or a
#                         copy with -Copy). The client loads it through
#                         MooseModeDev.toc, which this script generates from
#                         MooseMode.toc.
#
# Only one copy runs at a time: while MooseModeDev is enabled in the AddOns
# list, the release copy switches itself off for the session (Core.lua).
# Untick MooseModeDev to play the CurseForge release.
#
# Also writes MooseMode\Dev.lua, the marker behind the "dev build" line at
# login and the DEV tag in the dialog. Dev.lua and MooseModeDev.toc are
# gitignored and package.ps1 leaves both out of the release zip.
#
# Re-run this script after changing MooseMode.toc (new module files, a
# version bump) so MooseModeDev.toc picks the change up.
#
# Why the separate folder: the CurseForge app updates an addon by deleting
# its folder file by file, which follows a junction straight into this repo
# (it happened on 2026-09-20). The app does not know MooseModeDev, so it
# never touches it.

$ErrorActionPreference = "Stop"

$devName = "MooseModeDev"
$source  = Join-Path $PSScriptRoot "MooseMode"
$addons  = Join-Path $Path "Interface\AddOns"
$target  = Join-Path $addons $devName
$release = Join-Path $addons "MooseMode"

if (-not (Test-Path $source)) { throw "Addon source not found: $source" }
if (-not (Test-Path $Path))   { throw "WoW install not found: $Path" }
if (-not (Test-Path $addons)) { New-Item -ItemType Directory -Force $addons | Out-Null }

function Test-Link([string]$p) {
    if (-not (Test-Path $p)) { return $false }
    return [bool]((Get-Item $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)
}

# 1. The old layout linked AddOns\MooseMode to this repo. Remove that link
#    (the link only, never the files behind it) so CurseForge can install
#    its own copy there.
if (Test-Link $release) {
    cmd /c rmdir "$release" | Out-Null
    Write-Host "Removed the old dev link at $release."
    Write-Host "  Install MooseMode from the CurseForge app to put the release copy back there."
}

# 2. MooseModeDev.toc: MooseMode.toc with a dev title, the icon under
#    MooseModeDev, no CurseForge project id (so the app never mistakes it
#    for the project), and Dev.lua loaded last.
$utf8 = New-Object System.Text.UTF8Encoding($false)
$tocLines = [IO.File]::ReadAllLines((Join-Path $source "MooseMode.toc"))
$devToc = New-Object System.Collections.Generic.List[string]
foreach ($line in $tocLines) {
    if ($line -match '^## Title:') {
        $devToc.Add('## Title: |cffb04cffMooseMode|r |cffffd100Dev|r')
    } elseif ($line -match '^## IconTexture:') {
        $devToc.Add(($line -replace 'AddOns\\MooseMode\\', "AddOns\$devName\"))
    } elseif ($line -match '^## X-Curse-Project-ID:') {
        # left out on purpose
    } else {
        $devToc.Add($line)
    }
}
$devToc.Add("# Written by install.ps1 from MooseMode.toc. Not shipped; re-run install.ps1 after editing MooseMode.toc.")
$devToc.Add("Dev.lua")
[IO.File]::WriteAllLines((Join-Path $source "$devName.toc"), $devToc, $utf8)

# 3. Dev marker.
$escaped = $source -replace '\\', '\\'
$devLua = @"
-- Written by install.ps1. Marks a development install; not shipped.
local ADDON, ns = ...
ns.dev = true
ns.devPath = "$escaped"
"@
[IO.File]::WriteAllText((Join-Path $source "Dev.lua"), $devLua + "`r`n", $utf8)

# 4. Link (or copy) into AddOns\MooseModeDev.
if (Test-Path $target) {
    if (Test-Link $target) {
        cmd /c rmdir "$target" | Out-Null      # the link only, never the linked files
    } else {
        $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $aside = "$target.replaced-$stamp.bak"
        Move-Item $target $aside
        Write-Warning "A real $devName folder was in the way. Moved it to:`n  $aside"
    }
}
if ($Copy) {
    Copy-Item -Recurse $source $target
    Write-Host "Copied MooseMode to $target"
} else {
    cmd /c mklink /J "$target" "$source" | Out-Null
    Write-Host "Linked $target -> $source"
}

if (-not (Test-Path (Join-Path $release "MooseMode.toc"))) {
    Write-Host "No release copy in $release yet. Install MooseMode from the CurseForge app when you want it."
}
Write-Host "In game: tick 'MooseMode Dev' in the AddOns list at character select. While it is on, the CurseForge copy stays off."
Write-Host "Then /reload and look for the 'dev build' line in chat and DEV next to the version in /mm."
