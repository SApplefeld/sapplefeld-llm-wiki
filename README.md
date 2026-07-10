# llm-wiki engine

A standalone, content-free engine implementing Karpathy's LLM Wiki pattern
(https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f). This repo
holds machinery and a template only. It holds no knowledge-base content, ever:
every real knowledge base lives in its own repo, instantiated from the
`template/` directory here.

## The three-layer architecture

Every knowledge base built from this engine has three layers:

- **`sources/`**: immutable raw originals. A file lands here once, on ingest,
  and is never edited again. If a source needs correcting, a corrected file
  is ingested alongside it; the original stays.
- **`wiki/`**: an LLM-maintained set of interlinked markdown pages: entities,
  concepts, comparisons, overviews, syntheses, and per-source summaries. This
  is the knowledge base a human or a query actually reads.
- **`CLAUDE.md`**: the schema. It defines the page types, the new-page-versus-
  edit heuristic, linking and citation rules, and the maintenance workflows,
  turning the LLM into a disciplined wiki maintainer rather than a chat
  partner that free-associates. The schema is the single most important
  artifact in this whole system. Drift, an LLM quietly diverging from the
  schema's discipline over many runs, is the primary failure mode this engine
  is built to resist.

## The three operations

**Ingest.** A file arrives in `inbox/`. The ingest run reads it, moves the
original to `sources/` (never deleted, never edited again), writes a summary
page for it, and revises the ten to fifteen existing wiki pages that source
actually touches, in one pass. It updates `index.md` and appends a `log.md`
entry, then commits and pushes. Designed for unattended, headless execution:
crash-safe by construction, because each source is fully processed and
committed before the next one starts.

**Query.** Given a question, the query operation reads `index.md` first, opens
the relevant pages, and synthesizes an answer with citations back to wiki
pages and, through them, to sources. A valuable answer can optionally be filed
back into the wiki as a synthesis page, at which point it goes through the
same index and cross-reference maintenance as any other page.

**Lint.** The health pass. It detects orphan pages unreachable from
`index.md`, broken relative links, missing reciprocal cross-references,
contradictions between pages (flagged with both citations, auto-resolved only
when one side is clearly superseded by a newer source), stale claims past the
staleness horizon declared in the KB's `CLAUDE.md`, and drift between
`index.md` and the actual page set. Lint fixes land as their own commits,
separate from ingest commits, and never touch `sources/`.

## KB repo anatomy

An instantiated knowledge base has this shape:

```
<kb-name>/
  inbox/          <- drop zone; the ingestion queue; empty in a healthy repo
  sources/        <- immutable originals, moved here on ingest; never edited
  wiki/           <- the LLM-maintained pages (entities, concepts, comparisons, syntheses, per-source summaries)
  index.md        <- catalog of every wiki page with one-line summaries, by category; read first on query
  log.md          <- append-only run digest (ingests, lint passes, queries filed back)
  CLAUDE.md       <- the schema: page types, conventions, workflows; per-KB, specialized over time
  .claude/        <- vendored engine skills (wiki-ingest, wiki-lint, wiki-query) + settings.json permission
                     allowlist + kb-move.ps1 and kb-commit.ps1, the two vetted helpers
  .gitignore
```

Every privileged file move and every commit goes through `kb-move.ps1` and
`kb-commit.ps1`, which validate their own arguments, which is why raw `mv` and
`git push` are denied to the agent.

## Why one repo per knowledge base, never branches

Each knowledge base is a permanently disjoint domain: two entities' knowledge
bases are never meant to merge, diverge from a common ancestor, or share
history. Branches exist to partition versions of the same content; that model
does not fit content that must never cross-contaminate. A repo per knowledge
base gives each domain independent history and independent identity: the repo
boundary provides the separation, and the permission model enforces it. The
agent running in a KB has no shell verb that can write outside the repo, and
no way to push to any remote other than that KB's own `origin`.

For the same reason, the engine itself is vendored (copied) into every KB
repo rather than installed as a shared plugin. A vendored copy means each KB
is fully self-contained: clone it, open Claude Code in it, and everything the
KB needs, including the skills, is already inside. No shared runtime crosses
domain lines, and an engine update is a deliberate, auditable copy into a
specific KB rather than something that changes every KB's behavior at once.

## How to instantiate a KB

At a high level: copy `template/` into a new folder, run `git init -b main`
in it, make an initial commit, then open an interactive Claude Code session
in the new KB and specialize `CLAUDE.md` for the domain (page-type
vocabulary, domain entities, citation granularity). Create the remote by hand
on whichever git host and account the KB's owning entity uses, then push.

`new-kb.ps1` automates the copy-and-init steps; see `docs/instantiation.md`
for the full walkthrough including the schema-specialization session and
remote setup.

## How automation works

A per-user Windows scheduled task runs headless Claude Code
(`claude -p "Use the wiki-ingest skill."`) with the KB folder as its working
directory, on a cadence. Dropping a file into `inbox/` is the entire
hand-off: the next scheduled run ingests it and pushes a commit. An empty
inbox no-ops, so a frequent cadence costs nothing.

Two mechanics are easy to get wrong, and both fail silently:

- **Invoke the skill by name, not as a slash command.** `claude -p "/wiki-ingest"`
  is read as ordinary prose in headless mode and the skill never runs.
- **The KB's workspace must be trusted first.** Claude Code ignores
  `permissions.allow` entirely in an untrusted workspace, and no command-line
  flag overrides that while a skill is executing. An untrusted KB's scheduled
  run therefore writes nothing and exits, with the warning going only to
  stderr. Trust is established by opening Claude Code interactively in the KB
  once and accepting the dialog, which the schema-specialization session
  already does. The `deny` rules hold whether or not the workspace is trusted.

Tenancy is by Windows account: one account per entity, each with its own
Claude login and its own git credentials, so automation for one entity never
runs with another entity's identity or reads another entity's files. See
`docs/runbook_automation.md` for registration and verification detail.

## How to verify a KB's structure

```
pwsh -File tests/Test-KbStructure.ps1 -Path <kb-path>
```

Add `-RequireSchema` once a KB has a specialized `CLAUDE.md` in place, and
`-RequireSkills` to also require the three vendored skill files.

## Deliberately out of scope

- **Hybrid search or embeddings.** A flat `index.md` is sufficient to a few
  hundred pages; this is revisited only if a KB approaches that scale.
- **Cloud routines.** Ingest reads local drops in `inbox/`; a cloud routine
  would still need something local to push files first, so it adds a hop
  without removing one. A possible later addition for repo-only passes like
  lint.
- **Git LFS.** Not needed until a KB's `sources/` grows heavy enough that
  plain git storage becomes a problem.
- **Cross-KB linking or querying.** Structurally excluded: knowledge bases
  are separate repos precisely so nothing can reach across them.
