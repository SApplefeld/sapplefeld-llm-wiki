# Backlog

The living handoff and next-steps doc. It carries active items only. When an item is done, it moves out to a dated snapshot in `archive/` (`backlog-YYYY-QN.md`) rather than being struck through in place.

Per-plan history does not live here. A plan's Chapters travel with the plan into `archive/` when it closes. This file is for cross-effort next-steps that do not belong to any single open plan.

## Active

- ASR KB rollout: execute `docs/runbook_rollout.md` under the ASR account once the pilot (spec v1, Section 8) closes. Includes the two rollout-time decisions parked in the spec's Open Questions (inbox cross-account write policy, subscription coexistence verification).
- NEO KB rollout: same runbook under the NEO identity, plus the host-account-versus-sandbox-VM decision.
- Out-of-repo read channel, structural close: `Read` and `Glob` are allowed unscoped (the `Grep` tool is now denied outright, since its path-scoped deny rules were confirmed not to bind). Credential-shaped paths are denied by an explicit deny list, but an ordinary file elsewhere on the machine stays readable by a KB's agent. The boundary for non-credential data is therefore behavioral, resting entirely on the one-account-per-entity invariant the runbooks enforce; that residual rises to Critical if two legally separated KBs ever share one Windows account. Revisit if Claude Code gains a supported way to scope `Read`/`Glob` to the repo root, which would close the channel structurally rather than by account discipline. Not owned by any single KB rollout: it is an engine property that spans them all. See `docs/architecture.md` (permission and security model) and the hard invariant in `docs/runbook_automation.md`.
- Concurrent-run reconcile race: the ingest and lint tasks both edit `wiki/`, `index.md`, and `log.md`, and each commits pre-existing dirty state at run start (the reconcile step). If one fires while the other is mid-edit, it can commit and push the other's half-finished work under a `Reconcile:` subject. State converges and nothing is lost, but a half-written page can reach the remote briefly and the commit is misattributed. Today's mitigation is scheduling discipline (documented in `docs/runbook_automation.md`), which cannot fully close it because a frequent ingest will eventually overlap a long lint. The proper fix is a reconcile guard that leaves a dirty file alone until it has been untouched for some minutes (an mtime gate), so a live run's in-progress edits are never adopted by another run. Engine-wide, revisit before a KB runs ingest and lint on tight overlapping cadences.

## Snapshots

Completed items are archived to `archive/backlog-YYYY-QN.md`.
