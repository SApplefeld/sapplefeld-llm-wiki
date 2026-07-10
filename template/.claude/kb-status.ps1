#Requires -Version 5.1
<#
.SYNOPSIS
Reports read-only status about a knowledge base repo: working-tree state,
unpushed commits, a page's last-change date, or the inbox listing.

.DESCRIPTION
The only read-only git access a knowledge base session has. Raw git is denied
by the permission allowlist, so this helper exposes exactly the three git reads
the skills need, plus an inbox listing, and nothing else. Each mode validates
its own arguments and writes plain text to stdout. It only reads: it moves
nothing, writes nothing, and commits nothing.

.PARAMETER What
The read to perform. One of:
- Porcelain: the working tree's status in `git status --porcelain` form.
- Unpushed: the commits on the current branch not yet on its upstream. A branch
  with no configured upstream reports nothing.
- PageDate: the last-change date (YYYY-MM-DD) of one repo page.
- Inbox: the files waiting in inbox/, one per line as `<bytes><tab><name>`,
  skipping .gitkeep.

.PARAMETER Path
Required for PageDate and rejected by every other mode: the repo-relative path
of the page whose last-change date to report. It must be under wiki/ or
sources/, or be exactly index.md or log.md, and must exist on disk.

.EXAMPLE
pwsh -NoProfile -File ./.claude/kb-status.ps1 -What Porcelain

.EXAMPLE
pwsh -NoProfile -File ./.claude/kb-status.ps1 -What Unpushed

.EXAMPLE
pwsh -NoProfile -File ./.claude/kb-status.ps1 -What PageDate -Path "wiki/acme-corp.md"

.EXAMPLE
pwsh -NoProfile -File ./.claude/kb-status.ps1 -What Inbox
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Porcelain', 'Unpushed', 'PageDate', 'Inbox')]
    [string]$What,

    [string]$Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Git failures are surfaced by checking $LASTEXITCODE explicitly, so native
# command failures must not auto-throw and produce a stack trace.
$PSNativeCommandUseErrorActionPreference = $false

# Writes a single-line reason to stderr and stops with a non-zero exit code, so
# a refusal is legible to an unattended caller without a PowerShell stack trace.
function Stop-WithReason {
    param([string]$Reason)
    [Console]::Error.WriteLine("kb-status: $Reason")
    exit 1
}

# The repo root is the parent of the .claude/ directory this script lives in.
$repoRoot = (Resolve-Path -LiteralPath (Split-Path -Parent $PSScriptRoot)).ProviderPath

$pathSupplied = -not [string]::IsNullOrEmpty($Path)

switch ($What) {
    'Porcelain' {
        if ($pathSupplied) {
            Stop-WithReason 'Porcelain takes no -Path.'
        }
        $status = & git -C $repoRoot status --porcelain
        if ($LASTEXITCODE -ne 0) {
            Stop-WithReason 'git status --porcelain failed.'
        }
        if ($null -ne $status) {
            Write-Output $status
        }
    }
    'Unpushed' {
        if ($pathSupplied) {
            Stop-WithReason 'Unpushed takes no -Path.'
        }
        # A branch with no configured upstream is not an error: there is simply
        # nothing to compare against, so report nothing and stop cleanly.
        & git -C $repoRoot rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            exit 0
        }
        $commits = & git -C $repoRoot log --oneline '@{u}..HEAD'
        if ($LASTEXITCODE -ne 0) {
            Stop-WithReason 'git log @{u}..HEAD failed.'
        }
        if ($null -ne $commits) {
            Write-Output $commits
        }
    }
    'PageDate' {
        if (-not $pathSupplied) {
            Stop-WithReason 'PageDate requires -Path.'
        }
        if ([System.IO.Path]::IsPathRooted($Path)) {
            Stop-WithReason "path must be repo-relative, not rooted: $Path"
        }
        if ($Path -like '*..*') {
            Stop-WithReason "path must not contain '..': $Path"
        }
        if ($Path.Contains(':')) {
            Stop-WithReason "path must not contain ':': $Path"
        }
        $normalized = $Path -replace '\\', '/'
        $inScope = ($normalized -eq 'index.md') -or
                   ($normalized -eq 'log.md') -or
                   ($normalized -like 'sources/*') -or
                   ($normalized -like 'wiki/*')
        if (-not $inScope) {
            Stop-WithReason "path is outside the readable set (sources/, wiki/, index.md, log.md): $Path"
        }
        $full = Join-Path $repoRoot $Path
        if (-not (Test-Path -LiteralPath $full)) {
            Stop-WithReason "path does not exist on disk: $Path"
        }

        # The path is passed as its own argument after --, never interpolated
        # into a string, so a name cannot be read as an option or a pathspec.
        $date = & git -C $repoRoot log -1 --format=%as -- $Path
        if ($LASTEXITCODE -ne 0) {
            Stop-WithReason "git log for $Path failed."
        }
        if ($null -ne $date) {
            Write-Output $date
        }
    }
    'Inbox' {
        if ($pathSupplied) {
            Stop-WithReason 'Inbox takes no -Path.'
        }
        $inboxDir = Join-Path $repoRoot 'inbox'
        if (-not (Test-Path -LiteralPath $inboxDir -PathType Container)) {
            Stop-WithReason 'inbox/ does not exist.'
        }
        $items = @(Get-ChildItem -LiteralPath $inboxDir -File | Where-Object { $_.Name -ne '.gitkeep' })
        foreach ($item in $items) {
            Write-Output ("{0}`t{1}" -f $item.Length, $item.Name)
        }
    }
}

exit 0
