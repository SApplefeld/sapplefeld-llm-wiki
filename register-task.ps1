#Requires -Version 5.1
<#
.SYNOPSIS
Registers a per-user Windows scheduled task that runs a knowledge base's
ingest or lint skill headlessly on a cadence.

.DESCRIPTION
Builds and registers a Windows scheduled task that runs headless Claude Code
(claude -p) in a knowledge base folder as a named Windows account, invoking
either the wiki-ingest skill on a frequent cadence or the wiki-lint skill on a
weekly cadence. It refuses to register a task that would silently do nothing:
it verifies the KB is a git repo with the requested skill and an origin remote,
and that the workspace is trusted for the owning account, because Claude Code
ignores permissions.allow in an untrusted workspace and a scheduled run there
writes nothing while no one is watching.

The prompt names the skill in prose ("Use the wiki-ingest skill.") because the
slash-command form is read as ordinary prose in headless mode and the skill
never runs. The model is pinned to sonnet because an unpinned headless spawn
inherits the harness default and a too-small model does nothing while emitting
success-shaped text.

With -WhatIf the task is described and nothing is registered. Otherwise the
task is registered and read back so the operator sees what actually landed,
followed by the verification checklist from the automation runbook.

.PARAMETER Operation
Ingest or Lint. Ingest runs the wiki-ingest skill; Lint runs the wiki-lint
skill. This selects the skill named in the prompt, the required skill file, and
the default cadence.

.PARAMETER KbPath
The knowledge base repo root. It must be a directory, a git repo, hold the
requested skill under .claude/skills/, and have a git remote named origin.

.PARAMETER User
The Windows account the task runs as, in DOMAIN\user or .\user form. The task
runs under this account's Claude login, git credentials, and workspace trust.

.PARAMETER Cadence
The schedule. One of Hourly, Every4Hours, Every12Hours, Daily, or Weekly. When
omitted it defaults to Every4Hours for Ingest and Weekly for Lint.

.PARAMETER TaskName
The scheduled task name. When omitted it is derived from the operation and the
KB folder name, for example wiki-ingest-eleos-kb.

.PARAMETER SkipTrustCheck
Skips the workspace trust check. Use this only when registering for an account
other than the current one, whose ~/.claude.json this script cannot read. It
does not make the workspace trusted; it only stops this script from verifying
it. Trust must still be established under the running account or the task
writes nothing.

.EXAMPLE
pwsh -NoProfile -File ./register-task.ps1 -Operation Ingest -KbPath ../eleos-kb -User '.\eleos'

.EXAMPLE
pwsh -NoProfile -File ./register-task.ps1 -Operation Lint -KbPath ../eleos-kb -User '.\eleos' -Cadence Weekly
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Ingest', 'Lint')]
    [string]$Operation,

    [Parameter(Mandatory)]
    [string]$KbPath,

    [Parameter(Mandatory)]
    [string]$User,

    [ValidateSet('Hourly', 'Every4Hours', 'Every12Hours', 'Daily', 'Weekly')]
    [string]$Cadence,

    [string]$TaskName,

    [switch]$SkipTrustCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Git failures are surfaced by checking $LASTEXITCODE explicitly, so native
# command failures must not auto-throw and produce a stack trace.
$PSNativeCommandUseErrorActionPreference = $false

# Writes a single-line reason to stderr and stops with a non-zero exit code, so
# a refusal is legible to an operator without a PowerShell stack trace.
function Stop-WithReason {
    param([string]$Reason)
    [Console]::Error.WriteLine("register-task: $Reason")
    exit 1
}

# Writes a highly visible multi-line warning to stderr. Used for the trust
# state this script cannot verify, which is the failure that otherwise stays
# silent until a scheduled run has written nothing.
function Write-LoudWarning {
    param([string[]]$Lines)
    [Console]::Error.WriteLine('')
    [Console]::Error.WriteLine('  ****************************************************************')
    foreach ($line in $Lines) {
        [Console]::Error.WriteLine("  * $line")
    }
    [Console]::Error.WriteLine('  ****************************************************************')
    [Console]::Error.WriteLine('')
}

# Folds path separators to forward slashes and lowercases, so a path recorded
# with backslashes and one recorded with forward slashes compare equal. Both
# forms occur as project keys in ~/.claude.json.
function ConvertTo-ComparablePath {
    param([string]$PathValue)
    return ($PathValue -replace '\\', '/').TrimEnd('/').ToLowerInvariant()
}

# Parses a JSON file into nested dictionaries. ~/.claude.json can carry a
# property whose name is an empty string, which the default ConvertFrom-Json
# rejects on both PowerShell editions. On 6+ the -AsHashtable switch tolerates
# it; on 5.1 that switch does not exist, so JavaScriptSerializer, which reads a
# JSON object into a Dictionary, is used instead. Both yield a value that
# supports ContainsKey and key indexing.
function Read-JsonAsDictionary {
    param([string]$FilePath)
    $raw = Get-Content -LiteralPath $FilePath -Raw
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        return $raw | ConvertFrom-Json -AsHashtable
    }
    Add-Type -AssemblyName System.Web.Extensions
    $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $serializer.MaxJsonLength = [int]::MaxValue
    return $serializer.DeserializeObject($raw)
}

# 1. Resolve the KB path and confirm it is a git repo holding the requested skill.
if (-not (Test-Path -LiteralPath $KbPath -PathType Container)) {
    Stop-WithReason "KbPath is not an existing directory: $KbPath"
}
$kbRoot = (Resolve-Path -LiteralPath $KbPath).ProviderPath

if (-not (Test-Path -LiteralPath (Join-Path $kbRoot '.git'))) {
    Stop-WithReason "KbPath is not a git repository (no .git): $kbRoot"
}

# The skill the operation invokes, and the file that must exist for it.
if ($Operation -eq 'Ingest') {
    $skillName = 'wiki-ingest'
} else {
    $skillName = 'wiki-lint'
}
$skillRelative = ".claude/skills/$skillName/SKILL.md"
$skillFile = Join-Path $kbRoot $skillRelative
if (-not (Test-Path -LiteralPath $skillFile -PathType Leaf)) {
    Stop-WithReason "KB is missing the $Operation skill file: $skillRelative"
}

# 2. A task without an origin remote would commit locally and never push,
# because kb-commit.ps1 pushes only to a remote named origin.
$remotes = @(& git -C $kbRoot remote)
if ($LASTEXITCODE -ne 0) {
    Stop-WithReason "unable to list git remotes for: $kbRoot"
}
if ($remotes -notcontains 'origin') {
    Stop-WithReason "KB has no git remote named 'origin'; a scheduled run would commit locally and never push. Add one with: git -C `"$kbRoot`" remote add origin <url>"
}

# 3. Verify workspace trust for the owning account, or refuse to register. An
# untrusted workspace makes Claude Code ignore permissions.allow, so the
# scheduled run would prompt on every write, get no answer, and write nothing.
$currentUser = "$env:USERDOMAIN\$env:USERNAME"
$requestedLeaf = ($User -split '\\')[-1]
$isCurrentUser = ($requestedLeaf -ieq $env:USERNAME)

if ($SkipTrustCheck) {
    Write-LoudWarning @(
        'WORKSPACE TRUST NOT VERIFIED (-SkipTrustCheck).',
        "The task will run as: $User",
        'Trust is per Windows account and lives in that account''s own',
        '~/.claude.json, which this script cannot read from here.',
        'If the KB is not trusted under that account, the scheduled run',
        'writes NOTHING and no one is notified. Establish trust by opening',
        'Claude Code interactively in the KB once as that account and',
        'accepting the trust dialog.'
    )
} elseif (-not $isCurrentUser) {
    Stop-WithReason "cannot verify workspace trust for '$User' from this account ($currentUser); trust lives in that account's own ~/.claude.json. Open Claude Code interactively in the KB once as '$User' and accept the trust dialog, then re-run with -SkipTrustCheck to acknowledge trust was established there."
} else {
    $claudeConfig = Join-Path $env:USERPROFILE '.claude.json'
    if (-not (Test-Path -LiteralPath $claudeConfig -PathType Leaf)) {
        Stop-WithReason "trust cannot be verified: $claudeConfig does not exist. Open Claude Code interactively in the KB once and accept the trust dialog."
    }

    $config = Read-JsonAsDictionary $claudeConfig
    $projectsNode = $null
    if ($config -and $config.ContainsKey('projects')) {
        $projectsNode = $config['projects']
    }

    $trusted = $false
    if ($null -ne $projectsNode) {
        $wanted = ConvertTo-ComparablePath $kbRoot
        foreach ($key in @($projectsNode.Keys)) {
            if ((ConvertTo-ComparablePath $key) -eq $wanted) {
                $entry = $projectsNode[$key]
                if ($entry -and $entry.ContainsKey('hasTrustDialogAccepted') -and $entry['hasTrustDialogAccepted']) {
                    $trusted = $true
                }
                break
            }
        }
    }

    if (-not $trusted) {
        Stop-WithReason "KB workspace is not trusted for this account. Open Claude Code interactively in the KB once and accept the trust dialog. An untrusted workspace makes Claude Code ignore permissions.allow, so the scheduled run would write nothing and no one would notice. Path checked in ${claudeConfig}: $kbRoot"
    }
}

# 4. Claude Code must be on PATH for the running account. Get-Command reads the
# current account's PATH; the task runs as $User, whose install may differ.
$claudeCmd = Get-Command -Name 'claude' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $claudeCmd) {
    Stop-WithReason "claude was not found on PATH. Claude Code must be installed and logged in under the account the task runs as ($User)."
}
$claudeExe = $claudeCmd.Source
if (-not $isCurrentUser) {
    Write-LoudWarning @(
        "claude was resolved on THIS account's PATH: $claudeExe",
        "The task runs as $User, whose install may live elsewhere.",
        'Confirm Claude Code is installed and logged in under that account.'
    )
}

# 5. Build the action. The prompt names the skill in prose because the
# slash-command form is read as prose in headless mode. --model sonnet is
# pinned because an unpinned headless spawn inherits the harness default and a
# too-small model does nothing while reporting success.
$prompt = "Use the $skillName skill."
$arguments = "-p `"$prompt`" --model sonnet"
$action = New-ScheduledTaskAction -Execute $claudeExe -Argument $arguments -WorkingDirectory $kbRoot

# 6. Build the trigger from the cadence. An omitted cadence defaults by
# operation: Ingest runs often, Lint runs weekly.
if ([string]::IsNullOrWhiteSpace($Cadence)) {
    if ($Operation -eq 'Ingest') {
        $Cadence = 'Every4Hours'
    } else {
        $Cadence = 'Weekly'
    }
}

$startAt = (Get-Date).Date.AddMinutes(5)
$indefinite = New-TimeSpan -Days 3650
switch ($Cadence) {
    'Hourly' {
        $trigger = New-ScheduledTaskTrigger -Once -At $startAt -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration $indefinite
    }
    'Every4Hours' {
        $trigger = New-ScheduledTaskTrigger -Once -At $startAt -RepetitionInterval (New-TimeSpan -Hours 4) -RepetitionDuration $indefinite
    }
    'Every12Hours' {
        $trigger = New-ScheduledTaskTrigger -Once -At $startAt -RepetitionInterval (New-TimeSpan -Hours 12) -RepetitionDuration $indefinite
    }
    'Daily' {
        $trigger = New-ScheduledTaskTrigger -Daily -At '03:00'
    }
    'Weekly' {
        $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At '03:00'
    }
}

# The principal runs the task as $User. S4U (Service For User) runs the task
# whether or not the user is logged on and needs no stored password, but it
# grants the run no network credentials, so a git push over HTTPS backed by
# Windows Credential Manager may fail. The alternative is -LogonType Password,
# which prompts for and stores the account password; the runbook covers the
# trade-off and a passwordless SSH deploy key as a third option.
$principal = New-ScheduledTaskPrincipal -UserId $User -LogonType S4U -RunLevel Limited

# -StartWhenAvailable runs a missed occurrence as soon as the machine is next
# available; the execution time limit bounds a run that hangs so it cannot pin
# a slot forever.
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 2)

# The default task name pairs the operation with the KB folder so ingest and
# lint tasks for the same KB do not collide.
if ([string]::IsNullOrWhiteSpace($TaskName)) {
    $kbFolderName = Split-Path -Leaf $kbRoot
    $TaskName = "$skillName-$kbFolderName"
}

$task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings

# 7. With -WhatIf, describe the task and register nothing. Otherwise register it
# and read it back so the operator sees what actually landed.
Write-Output ''
Write-Output "Operation:  $Operation ($skillName)"
Write-Output "KB path:    $kbRoot"
Write-Output "Run as:     $User"
Write-Output "Cadence:    $Cadence"
Write-Output "Task name:  $TaskName"
Write-Output "Execute:    $claudeExe"
Write-Output "Arguments:  $arguments"
Write-Output ''

if (-not $PSCmdlet.ShouldProcess($TaskName, "Register scheduled task running as $User")) {
    Write-Output '-WhatIf: nothing was registered. Re-run without -WhatIf to register this task.'
    exit 0
}

Register-ScheduledTask -TaskName $TaskName -InputObject $task -ErrorAction Stop | Out-Null

$registered = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
Write-Output 'Registered. Read back from Task Scheduler:'
Write-Output "  Name:      $($registered.TaskName)"
Write-Output "  Principal: $($registered.Principal.UserId) (LogonType $($registered.Principal.LogonType))"
Write-Output "  Trigger:   $($registered.Triggers[0].CimClass.CimClassName)"
Write-Output "  Execute:   $($registered.Actions[0].Execute)"
Write-Output "  Arguments: $($registered.Actions[0].Arguments)"
Write-Output "  WorkingDir:$($registered.Actions[0].WorkingDirectory)"

# 8. The verification checklist is the last thing printed, so the operator's
# next action is to prove the task works end to end before trusting it.
Write-Output ''
Write-Output 'Registration is not proof the task works. Run the verification'
Write-Output 'checklist in docs/runbook_automation.md now, in order: confirm the'
Write-Output 'principal, run the exact command by hand as the owning account with an'
Write-Output 'empty inbox (no commits, clean exit, no trust warning on stderr), then'
Write-Output 'drop a canary file and confirm it reaches sources/ and pushes to origin.'

exit 0
