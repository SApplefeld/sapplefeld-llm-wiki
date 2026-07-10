# llm-wiki Docs

This directory is the working library and project history for llm-wiki: the documents about the solution, the active plans, and the archived record of finished work.

## Folder map

- **Root (`docs/`)** holds the stable documents about the solution and this index. Architecture, design rationale, and the runbooks (instantiation, automation, rollout) live here as they are written.
- **`plans/`** holds active plans only: specs that are open or in progress. A plan moves to `archive/` the moment it is Complete or abandoned. See `plans/README.md`.
- **`archive/`** holds finished and abandoned plans (Chapters intact) and dated backlog snapshots. It is immutable history. See `archive/README.md`.

## About the solution

- [architecture.md](architecture.md) - the engineering reference: components, the four operations and their shared commit discipline, the permission and security model, the trust gate, the automation model, and the separation boundaries.
- [instantiation.md](instantiation.md) - the operator's walkthrough for standing up a new knowledge base from the engine template: create, trust, specialize the schema, create the remote, register automation.
- [runbook_automation.md](runbook_automation.md) - the operator's runbook for scheduling a knowledge base and proving the scheduled task works, including the verification checklist and the three failure modes that look fine and do nothing.

## Living documents

- **`backlog.md`** is the single living handoff and next-steps doc. It carries only active items; completed items are pruned to a dated snapshot in `archive/`.

## Active plans

- [llm-wiki_spec_v1.md](plans/llm-wiki_spec_v1.md) - Build the LLM Wiki engine: KB template, schema template, ingest/lint/query skills, instantiation and automation runbooks, Eleos pilot.

## Archive

See `archive/` for completed plans and backlog snapshots.
