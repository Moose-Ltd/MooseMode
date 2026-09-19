param(
    [string]$Path = "C:\Games\World of Warcraft\_classic_beta_",
    [switch]$Copy
)

$ErrorActionPreference = "Stop"

$source = Join-Path $PSScriptRoot "MooseMode"
$addons = Join-Path $Path "Interface\AddOns"
$target = Join-Path $addons "MooseMode"

if (-not (Test-Path $source)) { throw "Addon source not found: $source" }
if (-not (Test-Path $Path))   { throw "WoW install not found: $Path" }
if (-not (Test-Path $addons)) { New-Item -ItemType Directory -Force $addons | Out-Null }

if (Test-Path $target) {
    $item = Get-Item $target -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        # existing junction: remove the link only, never the linked contents
        cmd /c rmdir "$target" | Out-Null
    } else {
        Remove-Item -Recurse -Force $target
    }
}

if ($Copy) {
    Copy-Item -Recurse $source $target
    Write-Host "Copied MooseMode to $target"
} else {
    cmd /c mklink /J "$target" "$source" | Out-Null
    Write-Host "Linked $target -> $source"
}
