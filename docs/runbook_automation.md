# Automating a knowledge base

This is the operator's runbook for putting a knowledge base (KB) on a
schedule so it ingests dropped files and maintains itself without anyone
present. It picks up where
[instantiation.md](instantiation.md) leaves off: that document creates and
trusts the KB, this one registers the scheduled tasks and proves they work.
Read it in order, and do not skip the verification checklist. Three failure
modes here produce a run that looks fine and does nothing; the checklist is
how you catch them before they cost you a silent week. For the design behind
the permission model, the trust gate, and the skill-by-name and model-pin
mechanics this runbook relies on, see [architecture.md](architecture.md).

## What automation does

A per-user Windows scheduled task runs headless Claude Code in the KB folder
on a cadence. The task runs one command:

```
claude -p "Use the wiki-ingest skill." --model sonnet
```

with the KB as its working directory. Drop a file into the KB's `inbox/`, and
the next run ingests it: it moves the original into `sources/`, writes a
summary page, revises the wiki pages the source bears on, updates `index.md`
and `log.md`, commits, and pushes. An empty inbox is a free no-op: the run
reads an empty queue, writes nothing, makes no commit, and exits. So a
frequent cadence costs almost nothing, because most runs find nothing to do.

A second task runs the wiki-lint skill weekly to keep the wiki healthy:
orphan pages, broken links, missing cross-references, contradictions, and
stale claims. Lint commits its fixes separately from any ingest commit.

Two tasks per KB, then: a frequent ingest task and a weekly lint task, both
owned by the KB's Windows account.

## Prerequisites, per Windows account

Every KB is owned by exactly one Windows account (see the hard invariant at
the end). Everything below must be true under that account, not merely under
yours:

- **Claude Code installed and logged in under that account.** Each account
  carries its own Claude login and subscription. A headless run uses that
  account's login; a task registered for an account with no Claude login does
  nothing.
- **`pwsh` (PowerShell 7) on PATH.** The KB's helper scripts invoke `pwsh`.
- **Git configured with that account's own identity and credentials**, and
  the KB cloned or created with a remote named `origin`. Every ingest and
  lint run pushes through `kb-commit.ps1`, which pushes only to `origin`.
- **The KB workspace trusted under that account.** Trust is per Windows
  account and per exact path, and it lives in that account's own
  `~/.claude.json`. Establish it by opening Claude Code interactively in the
  KB once as that account and accepting the trust dialog. This is the single
  most important prerequisite; the next section says why.

## The three things that fail silently

Each of these produces a run that exits cleanly, reports success-shaped text,
and changes nothing. None of them is caught by a green exit code. The
verification checklist exists to catch all three.

### 1. An untrusted workspace

Claude Code ignores `permissions.allow` entirely in a workspace that has not
been trusted. Headless, that means it prompts on every write, gets no answer
because nobody is watching, and exits having written nothing. The warning
goes only to stderr. No CLI flag overrides this while a skill is executing:
`--settings`, `--allowedTools`, and inline JSON each supply a working
allowlist for a direct prompt but are all ignored under skill execution. The
`deny` rules hold whether or not the workspace is trusted, so trust affects
only what the run is allowed to do, never what it is forbidden. Trust the KB
under the owning account before registering anything. `register-task.ps1`
checks trust for the current account and refuses to register an untrusted KB,
but it cannot read another account's `~/.claude.json`, so trust for the
running account is ultimately yours to establish and verify.

### 2. The slash-command form

`claude -p "/wiki-ingest"` is read as ordinary prose in headless mode and the
skill never runs. Name the skill in words: `claude -p "Use the wiki-ingest
skill."`. `register-task.ps1` builds the prose form for you; the point here
is that a hand-run verification command must use the same form, or you are
testing a different thing than the task runs.

### 3. An unpinned or too-small model

A `haiku` run of the ingest skill did nothing (no move, no commit) while
emitting success-shaped text; the same KB and prompt under `sonnet` ingested
correctly. An unpinned headless spawn inherits the harness default, whatever
that happens to be. Pin `--model sonnet`. `register-task.ps1` pins it; a
hand-run verification command must pin it too.

## Registering the tasks

Run these from an **elevated** PowerShell (Run as administrator). Registering a
scheduled task with an S4U principal, or for any account, requires elevation;
without it `Register-ScheduledTask` fails with an access-denied error.

Register both tasks under the owning account, from the engine checkout. Ingest
first:

```
pwsh -NoProfile -File ./register-task.ps1 -Operation Ingest -KbPath ..\eleos-kb -User '.\eleos'
```

Then lint:

```
pwsh -NoProfile -File ./register-task.ps1 -Operation Lint -KbPath ..\eleos-kb -User '.\eleos'
```

`-Operation` selects the skill and the default cadence: Ingest defaults to
every four hours, Lint to weekly on Sunday. Override with `-Cadence`, which
accepts `Hourly`, `Every4Hours`, `Every12Hours`, `Daily`, or `Weekly`:

```
pwsh -NoProfile -File ./register-task.ps1 -Operation Ingest -KbPath ..\eleos-kb -User '.\eleos' -Cadence Every12Hours
```

The task name defaults to the operation plus the KB folder name, for example
`wiki-ingest-eleos-kb` and `wiki-lint-eleos-kb`. Override with `-TaskName`.

Before registering, the script refuses any KB that would silently do nothing:
a path that is not a git repo, a repo missing the requested skill, a repo with
no `origin` remote, or an untrusted workspace. Each refusal exits with a
one-line reason naming the fix.

Add `-WhatIf` to any invocation to see exactly what would be registered
without registering it. Run that first if you want to inspect the task before
committing it to the scheduler.

**Registering for an account other than your own.** The script can verify
trust only for the current account, because it reads only the current
account's `~/.claude.json`. If `-User` names a different account, it refuses
and tells you to establish trust as that account and re-run with
`-SkipTrustCheck`. `-SkipTrustCheck` bypasses only the trust verification and
prints a loud warning; it does not make the workspace trusted. The safest path
is to log in as the owning account and register from there, so the trust check
is real.

### S4U versus a stored password

The task registers with an S4U (Service For User) principal: it runs whether
or not the user is logged on and needs no stored password. The trade-off is
that an S4U run gets **no network credentials**. A `git push` over HTTPS that
relies on Windows Credential Manager can therefore fail from inside the task
even though it succeeds when you run it by hand while logged on. The
verification checklist tests the push path end to end for exactly this reason.

If the scheduled push fails while a hand-run push succeeds, you have two
honest options:

- Re-register with a stored password (`-LogonType Password` on the principal),
  which prompts for the account password and stores it, and does carry network
  credentials.
- Or switch the remote to SSH with a passphrase-less deploy key scoped to that
  one repo, which needs no interactive credential and no stored password.

Test the push path first (the checklist does), and change the logon model only
if it actually fails.

## The verification checklist

This is the heart of the runbook. Run every step, in order, under the owning
account, in the KB folder. Each step names the command and the exact
observable that proves it. A registered task is not a working task until this
passes.

**1. The task exists and runs as the intended account.**

```
Get-ScheduledTask -TaskName wiki-ingest-eleos-kb | Select-Object -ExpandProperty Principal
```

Observable: `UserId` is the owning account (`.\eleos`, or the domain form you
registered), and `LogonType` is `S4U`.

**2. The exact command the task runs succeeds by hand, with an empty inbox.**
Confirm `inbox/` holds nothing but `.gitkeep`, then run the task's own command
interactively, capturing stderr to a file:

```
cd <kb>
claude -p "Use the wiki-ingest skill." --model sonnet 2> run-stderr.txt
```

Observable: the command exits, `git status --porcelain` is empty, and
`git log --oneline -3` shows no new `Ingest:` commit. This proves only that the
skill is invoked and that an empty inbox is a clean no-op. It does not prove the
allowlist works, because an empty inbox performs no allow-gated write: a fully
untrusted KB produces exactly this same clean result. The allowlist is proven by
the canary in step 4, where a real write must land. (Delete `run-stderr.txt`
when done; it is a scratch file, not part of the KB.)

**3. Trust is real: the allowlist is in force.** From the same run's stderr:

```
Select-String -Path run-stderr.txt -Pattern 'Ignoring .* permissions'
```

Observable: no match. A match (the current warning reads "Ignoring N
permissions.allow entries ... this workspace has not been trusted") means the
workspace is untrusted for this account and every write was silently refused;
stop and trust the workspace (open Claude Code interactively in the KB once and
accept the dialog) before going further. Match on `Ignoring .* permissions`
rather than a specific sentence, so a reworded warning still trips it. Because
this check reads stderr for a warning that may change, treat step 4's canary as
the decisive proof: a write that actually lands cannot happen in an untrusted
workspace, so a green step 4 confirms trust regardless of the warning text. The
trust warning appears only on stderr, which is why step 2
redirects it to a file.

**4. A canary file goes from inbox to pushed commit.** Drop a small readable
file into `inbox/`, then run the task itself (not the bare command), so you
exercise the scheduler path:

```
Copy-Item some-note.txt <kb>\inbox\canary.txt
Start-ScheduledTask -TaskName wiki-ingest-eleos-kb
```

Wait for the run to finish (step 6 shows how to read completion), then confirm
every one of these in the KB:

```
Test-Path .\sources\canary.txt                 # True: the original moved in
Get-ChildItem .\wiki\*canary*summary.md        # the summary page exists
Select-String -Path .\index.md -Pattern canary # index.md names it
Select-String -Path .\log.md   -Pattern canary # log.md has the entry
git log --oneline -1                            # subject begins "Ingest:"
git log origin/main..HEAD --oneline             # empty: the commit reached origin
```

Observable: `canary.txt` is in `sources/` and gone from `inbox/`; a summary
page exists in `wiki/`; `index.md` and `log.md` both name it; the newest
commit's subject begins `Ingest:`; and `git log origin/main..HEAD` is empty,
which is what proves the commit reached the remote rather than stranding
locally. If that last command lists a commit, the push failed (see the S4U
note above).

**5. The run completed without a permission prompt.** There is no prompt dialog
to see in a headless run; the tell is the artifact. A prompted run leaves the
file unwritten, so the summary page and the commit from step 4 would not exist.
Their presence is the proof: a run that produced the summary page, the index
entry, and the `Ingest:` commit was never blocked on a prompt. Absence of the
artifact, with the file still sitting in `inbox/`, is the failure.

**6. The task fires on its own schedule, not just when started by hand.** After
a scheduled window has passed without you starting it manually:

```
Get-ScheduledTaskInfo -TaskName wiki-ingest-eleos-kb | Select-Object LastRunTime, LastTaskResult, NextRunTime
```

Observable: `LastRunTime` advances to a time you did not trigger, and
`NextRunTime` is set. `LastTaskResult` of 0 means the process exited cleanly,
but 0 alone does not prove the ingest worked: an untrusted or too-small run
also exits 0. The commit is the proof, not the exit code. To confirm a
scheduled run did real work, drop a canary before a scheduled window and check
after it that the `Ingest:` commit appeared on its own.

## Reading an unattended run

A headless task has no console you watch. Two durable signals tell you what
happened:

- **`log.md`** in the KB. Every run that did work appends one
  `## YYYY-MM-DD - ingest` (or `- lint`) heading with a bullet per source
  handled. A healthy history is a steady sequence of dated headings.
- **`git log`.** Every ingested source is one commit whose subject begins
  `Ingest:`; every lint pass is one `Lint:` commit. `git log --oneline`
  reads like a maintenance journal. `git log origin/main..HEAD` should be
  empty; anything there is an unpushed commit.

Telling a healthy no-op from a broken run is the subtle case, because **both
produce zero commits**. A no-op run found an empty inbox and correctly did
nothing. A broken run (untrusted workspace, slash-command prompt, wrong model)
also wrote nothing. `git log` alone cannot distinguish them. The tell is
`sources/` versus `inbox/`: a healthy idle KB has an empty `inbox/` and its
files in `sources/`; a broken KB has files piling up in `inbox/` that never
move. If dropped files sit in `inbox/` across several scheduled windows and
never reach `sources/`, the task is broken, not idle, and the troubleshooting
table below says where to look.

**One run at a time per KB.** The ingest and lint tasks both edit `wiki/`,
`index.md`, and `log.md`, and each begins by committing whatever it finds
already changed on disk (the reconcile step, which recovers a crashed run). If
an ingest fires while a lint is mid-edit, the ingest can commit the lint's
half-finished work under a `Reconcile:` subject and push it. The state
converges once the interrupting run's own commit lands, so nothing is lost, but
a half-written page can reach the remote briefly and the commit is
misattributed. Schedule the two tasks so their windows do not overlap: the
default ingest cadence (every four hours) and the default lint time (Sunday
03:00) can coincide, so give a KB with a long-running lint either a wider ingest
cadence or a lint time no ingest window covers. The same caution applies to
running an interactive session in a KB while its scheduled task may fire.

## The hard invariant, restated

**One Windows account per knowledge base. Never two.** This is not a
preference; it is the boundary between entities.

`Read`, `Glob`, and `Grep` are allowed unscoped, and a headless run will read
an absolute path outside its own repo. Credential files are denied, but an
ordinary file is not. So co-locating two entities' KBs under one account puts
one entity's sources within reach of the other entity's agent: a
prompt-injected document dropped into one KB's inbox could instruct the run to
read the other KB's sources and write them into a wiki page that is then
pushed. The repo boundary separates content; the Windows account boundary
separates entities. For ASR and NEO, whose separation is a legal requirement,
that boundary must never be crossed. Each entity gets its own Windows account,
its own Claude login, its own git credentials, and its own scheduled tasks.

## Troubleshooting

| Symptom | Likely cause | Check |
| --- | --- | --- |
| Task runs but nothing changes | Untrusted workspace | `Select-String -Path run-stderr.txt -Pattern 'Ignoring .* permissions'`; if it matches, trust the KB under the owning account. |
| Task runs but nothing changes | Slash-command prompt instead of prose | Confirm the action's arguments read `-p "Use the wiki-ingest skill."`, not `/wiki-ingest`: `(Get-ScheduledTask -TaskName wiki-ingest-eleos-kb).Actions[0].Arguments`. |
| Task runs but nothing changes | Model too small or unpinned | Confirm the same arguments contain `--model sonnet`. |
| Commits appear but never reach the remote | S4U has no network credentials for an HTTPS push | `git log origin/main..HEAD` lists commits; try `git push` by hand as that account. If the hand push works, switch to `-LogonType Password` or an SSH deploy key. |
| Commits appear but never reach the remote | No `origin` remote | `git remote` lists no `origin`; add it with `git remote add origin <url>`. |
| A file sits in `inbox/` forever | A name `kb-move.ps1` refuses (a leading dash, a colon, a slash) | The run's report names the file. A human must rename it to a plain leaf name, then it ingests on the next run. |
| A source is in `sources/` but has no wiki page | A run crashed after moving the file, before committing | `git status --porcelain` shows the untracked `sources/` file. The next ingest run's reconcile step finishes it; no action needed unless it persists. |
