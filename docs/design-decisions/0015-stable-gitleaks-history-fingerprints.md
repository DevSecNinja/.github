# ADR 0015: Match gitleaks history alerts on gitleaks' own fingerprint

## Status

Accepted.

## Context

The full-history gitleaks scan (#520) uploads its findings to code scanning
under the `gitleaks/history` category. Code scanning matches results across
runs only on `partialFingerprints.primaryLocationLineHash`. gitleaks' SARIF
doesn't set it, so `github/codeql-action/upload-sarif` computes it from the
cited line in the current checkout.

A history finding belongs to an old commit, but that hash comes from whatever
the default branch has on the same line today. When that line is edited, the
next scan gives the same finding a new fingerprint, and code scanning opens it
as a new alert, even after the old one was dismissed (#624).

A pre-set `primaryLocationLineHash` alone doesn't help either. When it disagrees
with the hash the upload computes, codeql-action logs a warning with the file
path and line, and the job log of a public repository is public.

## Decision

In the history SARIF post-processing (`scripts/lint/gitleaks.sh`):

- Each result's `partialFingerprints` holds only `primaryLocationLineHash`,
  set to a hash of gitleaks' own fingerprint (`commit:file:rule:line`, the
  `.gitleaksignore` format) in the upload's `<16 hex>:1` shape. That
  fingerprint never changes for a history finding. gitleaks' other fields
  (commit SHA, author, e-mail, date and commit message) are dropped.
- Each result's `region` is dropped. Without a start line the upload skips the
  result before computing or comparing any line hash, so it keeps the pre-set
  value and no path reaches the log.
- The line is appended to the alert message (`Line N.`).

## Consequences

- Dismissals of history findings stick: editing or deleting the cited line, or
  the file, doesn't open a new alert.
- Alerts are file-level. The code scanning view no longer jumps to the line,
  but the private alert message names it, and the fingerprint is ready to paste
  into `.gitleaksignore`.
- Rolling out re-keys every existing `gitleaks/history` alert once: the first
  scan after a repository adopts the release closes the old alerts and opens
  each finding again under the new fingerprint. Dismissed findings must be
  dismissed once more.
- A finding that gitleaks reports on another line (for example after a rule
  change) is a new alert, as it would be for gitleaks itself.
