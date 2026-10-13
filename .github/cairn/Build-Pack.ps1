# Copyright (C) 2026 the Cairn contributors. SPDX-License-Identifier: MIT (as the project it is part of)
<#
.SYNOPSIS
    Builds the Cairn mod pack for Voices of the Void (Multivoid): release\Cairn-Pack-votv-<version>.zip and release\pack-index.json
    (what the Cairn launcher reads to see a newer pack exists).

.DESCRIPTION
    An *external* pack that goes into the game's own folder (docs in the launcher repository: docs/PACKS.md, installDir ".").
    The game's folder is the one that holds VotV.exe (WindowsNoEditor); the pack carries what docs/install.md puts in it by hand:

      mod\VotV\Binaries\Win64\          UE4SS (the contents of the UE4SS folder of the Thunderstore package unreal_shimloader, the build
                                        this project pins) and, in Mods\Multivoid\, the mod as this project's own package script lays it out
      mod\VotV\Content\Paks\LogicMods\multivoid\   the player-model paks, when the package has them
      pack.json      the contract with the launcher
      manifest.txt   MOD|<path>|<size>|<sha256>, one line per file

    The pack's version is the VERSION file (strict X.Y.Z, this project's own); the mod's own version (the package manifest) is the pack's
    "upstream". This build is not signed with the project's release key, so the game reports it as unofficial.
    A file of the game's with the same name and other bytes is never overwritten by the launcher, so a UE4SS the player already has is
    reported, not replaced.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $PackageZip,   # the zip .github/ci/package.ps1 made (Pelmentor-Multivoid-<version>.zip)
    [Parameter(Mandatory)][string] $LoaderZip     # Thunderstore-unreal_shimloader-<version>.zip
)

$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$version = (Get-Content (Join-Path $root 'VERSION') -TotalCount 1).Trim()
if ($version -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') { throw "VERSION must be strict X.Y.Z, got '$version'" }

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$release = Join-Path $root 'release'
$stage = Join-Path $release 'pack-stage'
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
$mod = Join-Path $stage 'mod'
$win64 = Join-Path $mod 'VotV\Binaries\Win64'
New-Item -ItemType Directory -Force -Path $win64 | Out-Null

function Expand-Safe([string] $zipPath, [string] $dest, [string] $prefix, [string] $skipPrefix) {
    $destFull = [IO.Path]::GetFullPath($dest).TrimEnd('\') + '\'
    $zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $zipPath))
    try {
        foreach ($e in $zip.Entries) {
            $name = $e.FullName.Replace('\', '/')
            if ($name.EndsWith('/') -or -not $name.StartsWith($prefix)) { continue }
            $rel = $name.Substring($prefix.Length)
            $target = [IO.Path]::GetFullPath((Join-Path $dest ($rel -replace '/', '\')))
            if (-not $target.StartsWith($destFull, [StringComparison]::OrdinalIgnoreCase)) { throw "the archive has a path outside its folder: $($e.FullName)" }
            New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent) | Out-Null
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
        }
    } finally { $zip.Dispose() }
}

# the loader: the UE4SS folder of the package, next to the game's executable (not the dwmapi.dll at the package's top, which is the mod manager's)
Expand-Safe $LoaderZip $win64 'UE4SS/'
# the mod: the package's mod\ folder, as a Mods\Multivoid folder
Expand-Safe $PackageZip (Join-Path $win64 'Mods\Multivoid') 'mod/'
# the player-model paks, when the package carries them
Expand-Safe $PackageZip (Join-Path $mod 'VotV\Content\Paks\LogicMods\multivoid') 'pak/'
# the notices the package carries travel with the mod
New-Item -ItemType Directory -Force -Path (Join-Path $win64 'Mods\Multivoid') | Out-Null
foreach ($n in 'LICENSE', 'THIRD-PARTY-NOTICES.md') {
    $zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $PackageZip))
    try {
        $e = $zip.GetEntry($n)
        if ($e) { [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $win64 "Mods\Multivoid\$n"), $true) }
    } finally { $zip.Dispose() }
}
# the mod's own version, from the package manifest
$zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $PackageZip))
try {
    $r = New-Object IO.StreamReader($zip.GetEntry('manifest.json').Open())
    $modVersion = ((($r.ReadToEnd()) | ConvertFrom-Json).version_number)
    $r.Dispose()
} finally { $zip.Dispose() }
if (-not $modVersion) { throw 'could not read the mod version from the package manifest' }

foreach ($n in @('UE4SS.dll', 'dwmapi.dll', 'Mods\Multivoid\dlls\main.dll', 'Mods\Multivoid\enabled.txt')) {
    if (-not (Test-Path (Join-Path $win64 $n))) { throw "the pack is missing VotV\Binaries\Win64\$n" }
}

function Get-Sha256([string] $Path) { (Get-FileHash $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

$launcherMin = '0.3.22'
$packJson = [ordered]@{
    schema      = 2
    id          = 'votv'
    game        = 'votv'
    version     = $version
    upstream    = $modVersion
    kind        = 'external'
    installDir  = '.'
    launcherMin = $launcherMin
}
[IO.File]::WriteAllText((Join-Path $stage 'pack.json'), (($packJson | ConvertTo-Json) + "`n"), (New-Object System.Text.UTF8Encoding($false)))

$lines = New-Object System.Collections.Generic.List[string]
foreach ($f in Get-ChildItem $mod -Recurse -File | Sort-Object FullName) {
    $rel = $f.FullName.Substring($mod.Length + 1)
    $lines.Add(('MOD|{0}|{1}|{2}' -f $rel, $f.Length, (Get-Sha256 $f.FullName)))
}
[IO.File]::WriteAllText((Join-Path $stage 'manifest.txt'), (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))

$zipName = "Cairn-Pack-votv-$version.zip"
$zipPath = Join-Path $release $zipName
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
$fs = [IO.File]::Open($zipPath, 'Create')
try {
    $z = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($f in Get-ChildItem $stage -Recurse -File) {
            $rel = $f.FullName.Substring($stage.Length + 1) -replace '\\', '/'
            [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z, $f.FullName, $rel, [System.IO.Compression.CompressionLevel]::Optimal)
        }
    } finally { $z.Dispose() }
} finally { $fs.Dispose() }

$index = [ordered]@{
    schema      = 2
    id          = 'votv'
    game        = 'votv'
    version     = $version
    upstream    = $modVersion
    kind        = 'external'
    file        = $zipName
    sha256      = Get-Sha256 $zipPath
    size        = (Get-Item $zipPath).Length
    launcherMin = $launcherMin
}
[IO.File]::WriteAllText((Join-Path $release 'pack-index.json'), (($index | ConvertTo-Json) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
Write-Host "pack: $zipPath ($([math]::Round((Get-Item $zipPath).Length / 1MB, 1)) MB), version $version, Multivoid $modVersion, $($lines.Count) files"
