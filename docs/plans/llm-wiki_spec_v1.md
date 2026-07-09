# LLM Wiki Engine

Status: In Progress
Commit Model: Commit-and-Push
Run Mode: chain (Section 8 is interactive by nature; the chain hands off to Scott there)
Fable Spend: S2 (schema template), S3 (wiki-ingest), S8 pilot judgment inline, finishing reviews
Created: 2026-07-09

## Goal

A standalone engine repository of generic, content-free machinery implementing Karpathy's LLM Wiki pattern (https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f), plus a repeatable recipe for instantiating per-entity knowledge-base repos with scheduled, unattended ingest and maintenance. When this is done, Scott can drop files of interest into a KB's `inbox/` folder and a scheduled headless Claude Code run ingests them into a curated, interlinked markdown wiki, maintains its health, and commits every change as a reviewable git history. The first real KB (Eleos) is live and a rollout runbook exists for ASR and NEO.

## Approach

The Karpathy pattern has three layers: immutable raw sources, an LLM-maintained wiki of interlinked markdown pages, and a schema file that turns the LLM into a disciplined wiki maintainer. Three operations: ingest (source arrives, summary written, 10 to 15 relevant pages revised in one pass), query (search, synthesize with citations, optionally file the answer back as a page), and lint (detect orphans, contradictions, stale claims, missing cross-links). The commentary on the gist is clear that the schema file is the single most important artifact and that drift is the primary failure mode.

Key decisions (all decided 2026-07-09 in the brainstorming session):

- **One repository per knowledge base, never branches.** ASR and NEO must stay pristine and separate as a legal requirement. Branches partition versions of the same content; these are permanently disjoint domains. Repo-per-KB gives independent history, independent identity, and makes cross-contamination structurally impossible.
- **The ingestion folder lives inside each KB repo (`inbox/`).** Dropping a file into a specific repo's inbox IS the folder-to-KB mapping. No registry, no routing logic that could misroute a document across a legal boundary.
- **The engine is vendored into each KB repo, not installed as a shared plugin.** Each KB is fully self-contained (clone it, open Claude Code in it, everything needed is inside). No shared runtime infrastructure crosses entity lines; engine updates are deliberate, auditable copies.
- **Tenancy is handled by Windows accounts.** One physical machine, separate Windows accounts for ASR, NEO, and personal. Each profile carries its own Claude login and subscription, its own git credentials, and its own scheduled tasks. No config-directory multi-tenancy tricks needed. The existing VMs (ASR demo VM, NEO sandboxed bot VM) are optional alternate homes for a KB's automation, chosen at rollout time per entity.
- **Automation is headless local Claude Code on Windows Task Scheduler**, running `claude -p` in the KB folder as the owning user. This beats a custom Anthropic SDK codebase (which would rebuild file tools, git handling, and skill loading that Claude Code already provides) and beats cloud routines (drops are local files; a cloud routine would need something local to push them first, and local runs keep entity data off infrastructure attached to the wrong account). Cloud routines remain a possible later addition for repo-only passes like lint.
- **Git is the review surface.** Karpathy's flow includes a "discuss takeaways with the user" step that automation removes. The replacement: one commit per ingested source, diffable and revertible, plus an append-only `log.md` digest per run. Git history also supersedes much of log.md's timeline role (git blame answers "when did this claim enter").
- **Pilot on Eleos under the personal account.** No legal constraints while engine bugs are being shaken out; ASR and NEO onboard onto a proven engine.
- **Default cadence: ingest a few times daily, lint weekly.** Cheap because an empty inbox no-ops. Tunable per KB.
- **Wiki links are standard relative markdown links** (not `[[wikilinks]]`), so every page renders correctly on GitHub and in any markdown viewer with no tooling.

### KB repo anatomy (produced by the template)

```
<kb-name>/
  inbox/          <- drop zone; the ingestion queue; empty in a healthy repo
  sources/        <- immutable originals, moved here on ingest; never edited
  wiki/           <- the LLM-maintained pages (entities, concepts, comparisons, syntheses, per-source summaries)
  index.md        <- catalog of every wiki page with one-line summaries, by category; read first on query
  log.md          <- append-only run digest (ingests, lint passes, queries filed back)
  CLAUDE.md       <- the schema: page types, conventions, workflows; per-KB, specialized over time
  .claude/        <- vendored engine skills (wiki-ingest, wiki-lint, wiki-query) + settings.json permission
                     allowlist scoped so headless runs need no prompts
  .gitignore
```

## Sections of Work

### 1. Engine repo scaffold and KB template
Model: sonnet
The engine repo's own README.md (what this is, the three-layer architecture, how to instantiate a KB, how automation works), .gitignore, and the `template/` directory containing the full KB repo scaffold per the anatomy above except CLAUDE.md (Section 2): `inbox/`, `sources/`, `wiki/` (with .gitkeep files), starter `index.md` and `log.md` with their structural skeletons, `.claude/settings.json` with a permission allowlist sufficient for a headless ingest run (file edits within the repo, git add/commit/push), and the template's .gitignore.
Acceptance: copying `template/` to a fresh folder and running `git init` yields a repo whose structure matches the anatomy; README explains instantiation end to end; settings.json parses as valid JSON.

### 2. Schema template (the per-KB CLAUDE.md)
Model: fable
The behavior-shaping heart of the system. The template CLAUDE.md must define: the page types (per-source summary, entity, concept, comparison, overview, synthesis) with a one-paragraph contract each; the new-page-versus-edit heuristic (new page for a distinct entity or concept you would link to from elsewhere; attribute changes and updates edit existing pages in place); linking rules (relative markdown links, every page reachable from index.md, cross-reference on both ends); citation conventions (every factual claim traceable to a file in `sources/`); index.md update rules; log.md entry format; and the explicit instruction that `sources/` is immutable and `inbox/` is a queue, not a home. Written generically with clearly marked customization points for domain specialization at instantiation (domain vocabulary and page-type specializations, citation granularity, and the staleness horizon Section 4's lint pass reads).
Acceptance: a fresh Claude session opened in an instantiated KB, given only the repo contents, correctly answers spot-check questions about where a new document's content should be filed and when a new page is warranted.

### 3. wiki-ingest skill
Model: fable
The core operation, written for unattended headless execution. Behavior: snapshot the inbox listing at run start (files arriving mid-run wait for the next run); if empty, exit without committing anything. Per source, in order: read it (PDFs and images via native reading; a file type that cannot be read gets moved to `sources/` with a stub summary page flagging it for manual attention, never silently dropped), move the original to `sources/`, write its summary page, revise the relevant existing wiki pages (the 10-to-15-pages-in-one-pass discipline, guided by the schema), update index.md, append the log.md entry, and make exactly one commit for that source. Push once at run end. Crash-safe by construction: each source is fully processed and committed before the next begins, so an interrupted run leaves no half-ingested state and the next run resumes cleanly.
Acceptance: run against an empty inbox produces no commits and a clean exit; run against an inbox with two test files produces exactly two commits, both originals in `sources/`, summary pages present, index.md updated, all links resolving; re-running immediately after produces no commits (idempotent).

### 4. wiki-lint skill
Model: opus
The health pass. Detects and fixes: orphan pages (unreachable from index.md), broken relative links, missing reciprocal cross-references, contradictions between pages (flagged in a `## Contradictions` section of the lint report with both citations; auto-resolved only when one side is clearly superseded by a newer source), stale claims (older than a staleness horizon declared in the KB's CLAUDE.md, with no source backing; Section 2 adds that setting to the schema template's customization points), and index.md drift against the actual page set. Fixes land as commits separate from any ingest commits, with the lint report appended to log.md. Never touches `sources/`.
Acceptance: against a test KB seeded with one orphan page, one broken link, and one contradiction, the lint run detects all three, fixes the orphan and the link, flags the contradiction with both citations, and commits the fixes.

### 5. wiki-query skill
Model: sonnet
The retrieval operation, primarily for interactive sessions. Behavior: read index.md first, open the relevant pages, synthesize an answer with citations to wiki pages and through them to sources, and offer to file a valuable answer back into the wiki as a synthesis page (which then goes through index and cross-reference maintenance like any page).
Acceptance: in a test KB with known ingested content, a query returns an answer whose citations point at the correct pages; filing the answer back produces a linked, indexed synthesis page.

### 6. KB instantiation path
Model: opus
`new-kb.ps1` in the engine repo: parameters for KB name and destination path; copies `template/`, runs `git init -b main`, makes the initial commit, and prints the follow-up steps. Plus a short `docs/instantiation.md` describing the schema-specialization session: an interactive Claude pass in the new KB that walks the CLAUDE.md customization points for the domain (page-type vocabulary, domain entities, citation granularity). Remote creation stays manual and documented (each entity's GitHub identity differs; the script must not assume an account).
Acceptance: running the script on a clean path yields a KB repo passing Section 1's structural check with the initial commit in place; instantiation.md covers remote setup and schema specialization end to end.

### 7. Automation runbook
Model: opus
`register-task.ps1` plus `docs/runbook_automation.md`. The script registers a per-user Windows scheduled task (parameters: run-as user, KB repo path, cadence) that runs headless Claude Code (`claude -p`) in the KB folder invoking the ingest skill, "run whether user is logged on or not"; a second registration mode for the weekly lint task. The runbook covers: prerequisites per account (Claude login, git credentials, repo cloned), registration, and a verification checklist: prove the task fires as the intended user, drop a canary file, confirm it lands in `sources/` with its commit pushed to the intended remote, and confirm the headless run completed without permission prompts (the settings.json allowlist is load-bearing here and gets verified, not assumed).
Acceptance: on the pilot KB, a registered task fires on schedule as the right user and processes a canary file end to end, from inbox to pushed commit, unattended.

### 8. Pilot: Eleos KB
Model: fable (inline)
Interactive with Scott. Instantiate `eleos-kb` under the personal account using Sections 6 and 7, specialize the schema for the Eleos domain, then run real drops for a stretch: genuine documents, real ingest runs on schedule, at least one lint pass. Tune the schema template and skills against observed behavior and backport generic fixes to the engine repo. Close by writing `docs/runbook_rollout.md`: the per-entity steps for ASR and NEO (account prerequisites, host-versus-VM decision guidance, verification), executed later under their own accounts and identities.
Acceptance: eleos-kb has ingested real sources via the scheduled task with Scott judging the wiki output pristine and usefully interlinked; a lint pass has run clean or its findings were adjudicated; runbook_rollout.md is complete enough that a fresh session under the ASR account could execute it without this conversation.

## Out of Scope

- Instantiating the ASR and NEO KBs (runbook only; execution happens later under their own accounts and environments).
- Hybrid search (SQLite FTS5, embeddings). The flat index.md is sufficient to a few hundred pages per the gist commentary; revisit when a KB approaches that scale.
- Cloud routines / scheduled cloud agents. Possible later addition for repo-only lint passes.
- Git LFS or submodule strategies for a heavy `sources/` layer; revisit if a KB's sources outgrow plain git.
- Any cross-KB linking, querying, or shared content. Structurally excluded by design.
- Changes to the Claude Kit; the kit stays out of this system entirely.

## Open Questions

- Whether two Claude subscriptions coexist cleanly on one Windows host across separate Windows accounts. Expected yes (per-profile `~/.claude`), verified during Section 7 or at ASR rollout. Owner: verified empirically at rollout.
- NEO automation home: host NEO account versus the sandboxed bot VM. Owner: Scott, at rollout.
- Whether cross-account NTFS write access to an entity's `inbox/` (dropping from the personal account) is acceptable under the ASR legal constraint, or drops must happen logged into the entity account. Owner: Scott, at rollout.

## Chapters

(Appended by executing-work as sections complete.)
