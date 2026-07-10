# Architecture

The llm-wiki engine is content-free machinery plus a template. It holds no
knowledge-base content and never runs against one directly. Every real
knowledge base (KB) is a separate git repository, instantiated by copying the
engine's `template/` tree into a new folder. The engine's job is to produce
self-contained KB repos and to keep the machinery inside them consistent; the
KB repos are where content lives, where the LLM works, and where automation
runs.

For a reader-facing tour of the pattern and the three layers, see the engine
[README](../README.md). This document is the engineering reference: the
components, the data flow, the security model, and the invariants a change must
preserve.

## Two kinds of repository

The engine repo (this one) contains the `template/` tree, the two operator
scripts (`new-kb.ps1`, `register-task.ps1`), the structural check
(`tests/Test-KbStructure.ps1`), and this `docs/` library. It is machinery only.

A KB repo is what an operator instantiates from `template/`. It is fully
self-contained: cloning it and opening Claude Code in it brings everything the
KB needs, including the three skills and the permission allowlist. The engine is
vendored (copied) into each KB, not installed as a shared plugin, so no runtime
crosses between KBs and an engine update is a deliberate copy into one specific
KB rather than a change that alters every KB at once.

## The KB repo layout

An instantiated KB has the three-layer content model plus its vendored
machinery:

```
<kb-name>/
  inbox/          drop zone and ingest queue; empty in a healthy repo
  sources/        immutable originals, moved here on ingest; never edited
  wiki/           the LLM-maintained interlinked markdown pages
  index.md        catalog of every wiki page, by category; read first
  log.md          append-only run digest
  CLAUDE.md       the schema: page types, conventions, workflows
  .claude/
    settings.json the permission allowlist
    kb-move.ps1   the only sanctioned inbox-to-sources move
    kb-commit.ps1 the only sanctioned stage/commit/push
    skills/wiki-ingest, wiki-lint, wiki-query
  .gitignore
```

`CLAUDE.md` is the behavior-shaping heart. It defines the six page types, the
new-page-versus-edit heuristic, the linking and citation rules, the
contradiction rule, and the `index.md`/`log.md` formats. It carries three
`<!-- CUSTOMIZE -->` blocks (domain vocabulary, citation granularity, staleness
horizon) that instantiation specializes for a domain. The skills own only
sequence and invariants; the schema owns discipline.

## The four operations and their shared discipline

Three skills implement the operations, and a fourth commit subject
(`Reconcile:`) recovers interrupted work. Every operation that writes shares one
discipline.

**Ingest** (`wiki-ingest`) is the core operation, written for unattended
headless execution. It snapshots `inbox/` once at run start (files arriving
mid-run wait for the next run), and for each source in order it reads the file,
moves the original to `sources/`, writes a per-source summary page, revises the
handful of wiki pages the source genuinely touches, updates `index.md`, appends
a `log.md` entry, and makes exactly one commit. It pushes once at run end. An
empty inbox produces no commit and a clean exit.

**Lint** (`wiki-lint`) is the weekly health pass. It runs six checks in
cheap-first order: `index.md` drift, orphan pages, broken relative links,
missing reciprocal cross-references, contradictions, and unsourced claims. It
fixes what is mechanically unambiguous, flags what needs judgment, and appends a
lint report to `log.md`. It never writes under `sources/`. Its fixes land in one
commit, separate from any ingest commit.

**Query** (`wiki-query`) is the retrieval operation, primarily interactive. It
reads `index.md` first, opens only the relevant pages, and answers with
citations to wiki pages and through them to sources. Anything presented in the
wiki's voice must be grounded in a citable page; when the wiki is silent, the
answer says so rather than drawing on model memory. A valuable answer can be
filed back as a synthesis page, which then goes through index and
cross-reference maintenance like any page.

**The commit seam.** All three writing skills begin with a reconcile front step
driven by `git status --porcelain`, because `kb-commit.ps1` stages the paths it
is given from the working tree as they stand. An interrupted run leaves dirty
files that would otherwise ride into the next run's commit under the wrong
subject. The reconcile step commits recovered edits alone first: an ingest run
folds a crashed source's dirty edits into that orphan source's own commit only
when an untracked `sources/` file actually exists, and otherwise commits stray
edits under a `Reconcile:` subject before touching the inbox; lint and query
each commit stray edits under `Reconcile:` before doing their own work. Every
commit subject is prefixed (`Ingest:`, `Lint:`, `Query:`, `Reconcile:`) so each
operation is findable on its own in `git log`.

**Crash behavior.** Ingest is not crash-proof, it is crash-recoverable. Each
completed source is committed before the next begins, so a crash loses at most
the one in-flight source's uncommitted work. The window between a move and its
commit leaves an untracked file in `sources/` that is invisible to the next
inbox snapshot; the reconcile front step exists to find and finish exactly that
file on the next run.

## The permission and security model

The agent inside a KB has no raw shell verb that takes a destination path and no
raw git write verb. `template/.claude/settings.json` is the enforcement point,
and it is load-bearing: a headless run cannot answer a permission prompt, so a
missing allow rule stalls an unattended run and a missing deny rule lets it do
damage.

**Two vetted helpers are the only privileged operations.** `kb-move.ps1` is the
only path into `sources/`: it takes a bare inbox file name, refuses a name
containing a separator or leading dash, refuses to overwrite an existing source
(so a re-dropped file is a refusal, not a silent loss), confirms the resolved
paths stay inside the repo and clear of `.git/` and `.claude/`, then moves the
file. `kb-commit.ps1` is the only path that commits: it accepts only
bar-delimited repo-relative paths under `sources/` or `wiki/` or exactly
`index.md`/`log.md`, stages them explicitly (never a wildcard), commits with an
empty `core.hooksPath` so a repo-planted git hook cannot execute, and pushes
only to a remote named `origin`, only with `-Push`. The allowlist grants exactly
those two `pwsh -NoProfile -File` invocations and denies raw `mv`, `rm`, `cp`,
`curl`, `wget`, and every raw git write verb (`add`, `commit`, `push`, `mv`,
`remote`, `config`, `reset`, `clean`, `checkout`).

**The agent cannot edit its own guard rails.** Writes are denied under
`sources/`, `inbox/`, `.git/`, and `.claude/`. `CLAUDE.md` is in neither the
allow nor the deny list, so a headless run cannot alter the schema while an
interactive session still can after a prompt.

**Untrusted input is treated as data.** Ingested documents arrive from third
parties and may contain text shaped like a command or an assertion that the wiki
is wrong. The schema's untrusted-input section and its contradiction rule are
the defense: an apparent instruction is recorded as a fact about the document
and otherwise ignored, and a source that merely asserts the wiki is wrong is
recorded as an attributed claim (both values, both citations) rather than
overwriting a sourced claim. A new source overwrites in place only when it
clearly postdates or explicitly corrects the claim it replaces.

**Credential reads are denied; other out-of-repo reads are not.** `Read`,
`Glob`, and `Grep` are allowed unscoped, so an ingest run can read files. The
allowlist denies reads of `**/.credentials.json`, `**/.claude.json`,
`**/.git-credentials`, `**/.ssh/**`, and `**/.aws/**`, and those denies hold
whether or not the workspace is trusted. An ordinary file elsewhere on the
machine remains readable, so the boundary for non-credential data is behavioral,
not enforced by the allowlist. This is why the one-account-per-entity invariant
below is a hard requirement and not a preference.

**Any invalid settings file is ignored wholesale.** Claude Code silently ignores
a `settings.json` that fails validation in headless mode, which would void the
entire allow and deny set with no error. A change to the allowlist is only safe
once a real denial and a real allow have both been observed, not merely once the
file parses.

## The trust gate

Claude Code ignores `permissions.allow` entirely in a workspace that has not
been trusted, and prints that warning only to stderr. A headless run in an
untrusted KB therefore prompts on every write, gets no answer, and exits having
written nothing. No CLI flag (`--settings`, `--allowedTools`, inline JSON)
overrides this while a skill is executing. Workspace trust is therefore a hard
prerequisite of automation, and it is established interactively (opening Claude
Code in the KB once and accepting the dialog). Trust is per Windows account and
per exact path, recorded in that account's own `~/.claude.json`. The `deny`
rules, by contrast, hold trusted or not.

## The automation model

A per-user Windows scheduled task runs headless Claude Code with the KB folder
as its working directory, on a cadence: a frequent ingest task and a weekly lint
task, both owned by the KB's Windows account. Two mechanics are load-bearing and
both fail silently when wrong. The prompt must name the skill in prose
(`claude -p "Use the wiki-ingest skill."`); the slash-command form is read as
ordinary prose in headless mode and the skill never runs. The model must be
pinned (`--model sonnet`); a too-small or unpinned model does nothing while
emitting success-shaped text.

`register-task.ps1` builds both mechanics correctly and refuses to register any
task that would silently do nothing: a path that is not a git repo, a repo
missing the requested skill, a repo with no `origin` remote, or an untrusted
workspace for the current account. The task registers with an S4U principal (no
stored password, runs whether or not the user is logged on) at the cost of no
network credentials, so an HTTPS push backed by Windows Credential Manager may
need a stored password or an SSH deploy key instead. See
[runbook_automation.md](runbook_automation.md) for registration and the
verification checklist.

## The separation model

Two boundaries keep KBs apart. The **repo boundary** separates content: each KB
is its own repository with its own history and its own `origin`, and the
permission model gives the agent no way to write outside the repo or push
anywhere but that KB's own remote. The **Windows account boundary** separates
entities: because out-of-repo reads are not structurally blocked, two KBs under
one account put one entity's files within reach of the other entity's agent.
One Windows account per KB, each with its own Claude login, git credentials, and
scheduled tasks. For entities under a legal separation requirement, this
boundary is not optional.

## Data flow, end to end

A file is dropped into a KB's `inbox/`. The next scheduled ingest run snapshots
the inbox, moves the file into `sources/` through `kb-move.ps1`, writes its
summary page and revises the wiki pages it bears on, updates `index.md` and
`log.md`, and commits that source's work through `kb-commit.ps1`, pushing once
at run end to `origin`. The wiki, `index.md`, and `git log` are the durable
record a human reads; `sources/` is the immutable evidence behind every cited
claim. A weekly lint run keeps the wiki internally consistent, and an
interactive query reads it back with citations. Dropping the file is the entire
hand-off; everything after it is automated and reviewable as a git history.

## Operating and extending

To stand up a KB, see [instantiation.md](instantiation.md). To schedule and
verify it, see [runbook_automation.md](runbook_automation.md). To verify a KB's
structure and its permission allowlist at any time:

```
pwsh -NoProfile -File tests/Test-KbStructure.ps1 -Path <kb> -RequireSchema -RequireSkills
```

When extending the engine, the invariants above are the ones a change must
preserve: the two helpers stay the only privileged operations, the deny wall
stays intact, every writing operation keeps its reconcile front step, and no
change may make a headless run depend on answering a prompt.
