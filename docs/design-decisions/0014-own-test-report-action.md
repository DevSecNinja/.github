# ADR 0014: Report test results with our own JUnit summary action

## Status

Accepted.

## Context

Test outcomes in our repositories are only visible in raw job logs. Azure
DevOps shows a test tab on every run; GitHub Actions has no built-in
equivalent. Almost every test runner can write JUnit XML (pytest, bats, Pester,
vitest, jest, gotestsum), so a reporter only has to read that format.

The established reporters (`mikepenz/action-junit-report`,
`dorny/test-reporter`, `EnricoMi/publish-unit-test-result-action`) are
third-party code that runs inside the test job, need allowlisting, and publish
a check run, which needs `checks: write` and attaches to an arbitrary workflow
in the checks UI. The docker repository already used one of them for that
reason.

## Decision

Ship our own composite action, [`actions/test-report/`](../../actions/test-report/README.md):

- A standard-library Python script reads the JUnit files matching the caller's
  globs and writes a job summary (totals per suite and a table of failed
  tests), `::error` annotations at the failing file and line, and count
  outputs. The only nested action is the first-party
  `actions/upload-artifact`, used when the caller opts in.
- It reports and never decides: failing tests do not fail the step. The test
  step already fails the job, and callers run the report with `if: always()`.
- It needs no permissions and no tool-version input, so
  [ADR 0001](0001-reusable-workflow-version-inputs.md) does not apply.
- Artifact upload is off by default, because artifact storage on private
  repositories is limited.

## Consequences

- No third-party code in test jobs and no `checks: write`; results show on the
  run's summary page and as annotations on the PR diff.
- There is no separate "Tests" check run or history across runs. Callers that
  need trends keep the uploaded XML or add a reporter later.
- GitHub shows at most 10 error annotations per step, so the summary table is
  the complete list.
- Each repository must produce JUnit XML. Stdlib `unittest` cannot, so those
  repositories need a JUnit-capable runner first.
- Format quirks (failure locations in bats notes, Python tracebacks, Pester
  stack lines) are handled in our script and covered by
  `tests/test-report.py`.
