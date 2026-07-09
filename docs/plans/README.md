# Active Plans

This folder holds active plans only: specs that are open or in progress. A plan is the single source of truth for one effort's intent and state, and a fresh or post-compaction session resumes from it.

## Rules

- A plan lives here while it is being worked. When it reaches `Status: Complete` or is abandoned, it moves to `../archive/` in the same close-out that finished it (via `git mv`, so history is preserved).
- Naming: `<project>_<content-type>_v<n>.md`. Increment the version rather than overwriting a prior one.
- The `Status` header drives the lifecycle. `In Progress` plans are surfaced for resume; `Complete` plans still sitting here are flagged as unarchived.
- When a plan relates to or supersedes another, cross-reference it in a `## Related` section.

## Current

- [llm-wiki_spec_v1.md](llm-wiki_spec_v1.md) - Build the LLM Wiki engine: KB template, schema template, ingest/lint/query skills, instantiation and automation runbooks, Eleos pilot.
