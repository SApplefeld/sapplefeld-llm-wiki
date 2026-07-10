# Log

Append-only run digest. Newest entries at the bottom, one `##` heading per run.
Git history is the authoritative timeline (`git blame` answers "when did this
claim enter"); this file is the human-readable digest of what each run did.

Entry format:

```markdown
## 2026-07-09 - ingest
- `sources/some-report.pdf` -> [Some Report](wiki/some-report-summary.md)
  - Revised: [Acme Corp](wiki/acme-corp.md), [Pricing Model](wiki/pricing-model.md)
  - Commit: `<short sha>`
```

Lint runs use `## YYYY-MM-DD - lint`, queries filed back use `## YYYY-MM-DD - query`.
