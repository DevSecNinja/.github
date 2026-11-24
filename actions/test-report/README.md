# `test-report` composite action

Show test results on the run page, like the test tab in Azure DevOps. The
action reads JUnit XML and writes:

- a **job summary** with pass/fail/skip counts and time per suite, plus a table
  of failed tests with their location and a shortened message;
- an **`::error` annotation** per failed test (at most 10, GitHub's per-step
  limit), placed on the failing file and line when the XML or failure text
  contains one, so it shows on the PR diff;
- **step outputs** `total`, `passed`, `failed` and `skipped`;
- optionally, the **line coverage** from Cobertura XML or lcov reports, in the
  summary and as the `line-coverage` output.

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
| `coverage-paths`  | empty          | Cobertura XML or lcov reports to show line coverage from. Empty: no line.   |
| `upload-artifact` | `"false"`      | Set `"true"` to upload the matched files with `actions/upload-artifact`.    |
| `artifact-name`   | `test-results` | Artifact name. Names must be unique per run, so include matrix values.      |
| `retention-days`  | empty          | Artifact retention; empty uses the repository setting.                      |

Artifacts are off by default because private repositories have limited
artifact storage. A file matched by several patterns is read once. Files that
are not valid XML are reported as a warning and skipped; the other files still
count. A `<failure>` or `<error>` counts as failed, `<skipped>` as skipped.
Test cases directly under `<testsuites>` (Node's `junit` reporter puts top-level
tests there) count as a suite named after the file. The
summary is also echoed to the log with workflow commands stopped, so test names
cannot inject annotations.

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

## Line coverage

Set `coverage-paths` to show one line in the summary, such as
`Line coverage: 85.3% (1234 of 1446 lines).`, and set the `line-coverage`
output. The lines of all matched reports are added up. It only reports: low
coverage does not fail the step. An unreadable report or a pattern that
matches nothing gives a warning.

| Format        | Produced by                                                                             |
| ------------- | --------------------------------------------------------------------------------------- |
| Cobertura XML | pytest-cov `--cov-report=xml` (`coverage.xml`), jest/vitest `cobertura`, `go-cobertura` |
| lcov          | jest/vitest `lcov` (`lcov.info`), c8, `cargo llvm-cov --lcov`                           |

Cobertura's `lines-valid`/`lines-covered` totals are used when present;
otherwise the class-level `<line hits>` elements are counted (method `<lines>` repeat them). A UTF-8 byte order mark is fine. lcov uses the `LF`/`LH`
lines.

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
      # Set up Python and install the pinned test requirements here,
      # pytest-cov included for the coverage report.
      - run: python -m pytest --junitxml=test-results.xml --cov --cov-report=xml
      - uses: DevSecNinja/.github/actions/test-report@<release-commit-sha> # vX.Y.Z
        if: ${{ !cancelled() }}
        with:
          paths: test-results.xml
          title: pytest (Python ${{ matrix.python }})
          # Optional: show line coverage from pytest-cov's --cov-report=xml.
          coverage-paths: coverage.xml
```

Replace `<release-commit-sha>` with the full 40-character commit SHA of a
release and keep the version comment, so Renovate tracks it.

## How failure locations are found

1. The last location in the failure text that is a file of the repository
   (inside `GITHUB_WORKSPACE`): bats `(in test file X, line N)` notes, Python
   `File "x.py", line N` frames and `path:line` references (pytest, Pester,
   go). Frames outside the workspace (the standard library) and in
   `site-packages`, `dist-packages`, `node_modules` or `vendor` directories are
   skipped, so the annotation lands on the deepest frame in your own code.
   Paths may contain spaces.
2. Otherwise the `file` and `line` attributes of the `<testcase>` (jest-junit,
   pytest's `xunit1` family). These usually point at the test's definition;
   a line of `0` (pytest counts from zero) annotates the file only.

Absolute paths and `file://` URLs inside the workspace are made relative to it.
A relative path that isn't a file from the workspace root is also tried from
the report's directory, for runners started in a subdirectory (for example
`cd backend && pytest --junitxml=junit.xml`).

## Local checks

```sh
python3 tests/test-report.py
python3 actions/test-report/test_report.py --paths 'tests/fixtures/test-report/*.xml'
```

The tests run the composite action's actual Bash step against pytest, bats and
Pester fixtures.
