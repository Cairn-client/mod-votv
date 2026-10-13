# Copyright (C) 2026 the Cairn contributors. SPDX-License-Identifier: MIT OR Apache-2.0 (as the project it is part of)
<#
.SYNOPSIS
    Writes release notes that contain only the changelog: one bullet per user-facing change since the previous Cairn release.

.DESCRIPTION
    Takes commit subjects between the previous release tag (a bare X.Y.Z tag) and HEAD, or, for the first release, between the upstream
    commit this fork is based on (UPSTREAM.md, "base-commit:") and HEAD. Keeps feat/fix/perf/refactor/revert commits, drops the type
    and scope prefix, and writes plain bullets. A "* " line in a commit body is one more bullet. Nothing else is written.
#>
param([Parameter(Mandatory)][string] $OutFile, [string] $Tag)

$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$strict = '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
$prev = @(& git -C $root tag --list | Where-Object { $_ -cmatch $strict -and $_ -ne $Tag } |
    Sort-Object { [version]$_ }) | Select-Object -Last 1
$base = ((Get-Content (Join-Path $root 'UPSTREAM.md')) | Where-Object { $_ -match '^base-commit:\s*([0-9a-f]{7,40})' } | ForEach-Object { $Matches[1] } | Select-Object -First 1)
$range = if ($prev) { "$prev..HEAD" } elseif ($base) { "$base..HEAD" } else { "HEAD" }

$raw = (& git -C $root log $range --no-merges --pretty=format:"%x1e%s%x1f%b") -join "`n"
$records = $raw -split [char]0x1e | Where-Object { $_.Trim() }
$lines = foreach ($r in $records) {
    $subject, $body = $r -split [char]0x1f, 2
    $t = $subject.Trim()
    $qualifies = $true
    if ($t -match '^(?<type>[a-z]+)(\((?<scope>[^)]*)\))?!?:\s*(?<msg>.+)$') {
        if ($Matches.type -notin 'feat', 'fix', 'perf', 'refactor', 'revert') { $qualifies = $false } else { $t = $Matches.msg }
    } elseif ($t -match '^\[(?<scope>[a-z-]+)\]\s*(?<msg>.+)$') {
        # this project's own subject shape, [scope] summary: the player-facing scopes are changes, [docs] and the rest are not
        if ($Matches.scope -notin 'cairn', 'coop', 'fix') { $qualifies = $false } else { $t = $Matches.msg }
    } else { $qualifies = $false }   # a commit that is not a conventional one is not a user-facing change here
    if ($qualifies) {
        $bullets = @(foreach ($b in ($body -split "`r?`n")) {
            if ($b -match '^\*\s+(?<e>.+)$') { "- " + $Matches.e.Substring(0, 1).ToUpper() + $Matches.e.Substring(1) }
        })
        if ($bullets.Count) { $bullets } elseif ($t) { "- " + $t.Substring(0, 1).ToUpper() + $t.Substring(1) }
    }
}
$lines = @($lines | Select-Object -Unique)
if (-not $lines.Count) { $lines = @("- Maintenance and stability improvements") }
Set-Content -Path $OutFile -Value $lines -Encoding utf8
Get-Content $OutFile
