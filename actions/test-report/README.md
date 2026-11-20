# `test-report` composite action

Show test results on the run page, like the test tab in Azure DevOps. The
action reads JUnit XML and writes:

- a **job summary** with pass/fail/skip counts and time per suite, plus a table
  of failed tests with their location and a shortened message;
- an **`::error` annotation** per failed test (at most 10, GitHub's per-step
  limit), placed on the failing file and line when the XML or failure text
  contains one, so it shows on the PR diff;
- **step outputs** `total`, `passed`, `failed` and `skipped`.

It runs a standard-library Python script (Python 3.8+, present on GitHub-hosted
runners), so there are no third-party actions or packages, and it needs no
permissions: no `checks: write`. The design is recorded in
[ADR 0014](../../docs/design-decisions/0014-own-test-report-action.md).

The action only reports. Failed tests do not fail this step; the test step
already fails the job. Run it with `if: always()` (or `!cancelled()`) so it also
reports when the tests fail.

## Inputs

| Input             | Default        | Meaning                                                                     |
| ----------------- | -------------- | --------------------------------------------------------------------------- |
| `paths`           | required       | JUnit XML files: glob patterns, one per line. `**` matches directories.     |
| `title`           | `Test results` | Summary heading. Add matrix values so jobs are told apart.                  |
| `max-failures`    | `50`           | Most failed tests listed in the summary table.                              |
| `if-no-files`     | `warn`         | No matching file: `warn`, `error` (fail the step) or `ignore` (no summary). |
| `upload-artifact` | `"false"`      | Set `"true"` to upload the matched files with `actions/upload-artifact`.    |
| `artifact-name`   | `test-results` | Artifact name. Names must be unique per run, so include matrix values.      |
| `retention-days`  | empty          | Artifact retention; empty uses the repository setting.                      |

Artifacts are off by default because private repositories have limited
artifact storage. Files that are not valid XML are reported as a warning and
skipped; the other files still count. A `<failure>` or `<error>` counts as
failed, `<skipped>` as skipped.

## Producing JUnit XML

| Runner | Option                                                                                                 |
| ------ | ------------------------------------------------------------------------------------------------------ |
| pytest | `pytest --junitxml=test-results.xml`                                                                   |
| bats   | `bats --report-formatter junit --output .` (writes `report.xml`)                                       |
| Pester | `$c = New-PesterConfiguration; $c.TestResult.Enabled = $true; $c.TestResult.OutputFormat = 'JUnitXml'` |
| vitest | `vitest run --reporter=default --reporter=junit --outputFile.junit=test-results.xml`                   |
| jest   | the `jest-junit` reporter                                                                              |
| go     | `gotestsum --junitfile test-results.xml`                                                               |

Stdlib `unittest` cannot write JUnit XML; run the tests with pytest (it runs
`unittest` test cases unchanged) or another JUnit-capable runner.

## Example

```yaml
jobs:
  test:
    runs-on: ubuntu-24.04
    strategy:
      matrix:
        python: ["3.13", "3.14"]
    steps:
      # renovate: datasource=github-tags depName=actions/checkout
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      # Set up Python and install the pinned test requirements here.
      - run: python -m pytest --junitxml=test-results.xml
      - uses: DevSecNinja/.github/actions/test-report@<release-commit-sha> # vX.Y.Z
        if: ${{ !cancelled() }}
        with:
          paths: test-results.xml
          title: pytest (Python ${{ matrix.python }})
```

Replace `<release-commit-sha>` with the full 40-character commit SHA of a
release and keep the version comment, so Renovate tracks it.

## How failure locations are found

1. `file` and `line` attributes on the `<testcase>` (jest-junit, pytest's
   `xunit1` family).
2. Otherwise the last location in the failure text that is a file inside
   `GITHUB_WORKSPACE`: bats `(in test file X, line N)` notes, Python
   `File "x.py", line N` frames and `path:line` references (pytest, Pester,
   go). Frames in the standard library or site-packages are skipped, so the
   annotation lands on the deepest frame in your repository.

Absolute paths inside the workspace are made relative to it.

## Local checks

```sh
python3 tests/test-report.py
python3 actions/test-report/test_report.py --paths 'tests/fixtures/test-report/*.xml'
```

The tests run the composite action's actual Bash step against pytest, bats and
Pester fixtures.
