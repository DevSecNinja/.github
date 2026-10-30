# Shared Copilot model policy

[`copilot-models.json`](../copilot-models.json) is the single source of reviewed
Copilot CLI model choices for opt-in consumers. It replaces scattered model pins,
not explicit model selection: every invocation must still pass `--model` with a
resolved model ID. Never use `auto`, omit the flag, or silently retry another
model when the selected one is unavailable.

A personal `.github` repository does **not** automatically inject these settings
into other repositories. Each consumer needs a one-time integration and its own
tests. This is a small data contract, not a package, service, Copilot app setting,
or reusable workflow that installs itself.

## Contract

Consumers fetch JSON data from this exact URL:

```text
https://raw.githubusercontent.com/DevSecNinja/.github/refs/heads/main/copilot-models.json
```

Schema version 1 has exactly these fields:

| Field            | Contract                                                                                                                               |
| ---------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `schemaVersion`  | Integer `1`; reject unsupported versions.                                                                                              |
| `revision`       | Positive integer, at most `9007199254740991` for exact JavaScript representation. Increase on every model change, including rollbacks. |
| `models.default` | Explicit model ID for general work.                                                                                                    |
| `models.writer`  | Explicit model ID for writing work.                                                                                                    |

`models` has exactly the two roles above. IDs are non-empty, lowercase ASCII
strings of at most 128 characters starting with a letter or digit and containing
only letters, digits, periods, underscores, and hyphens (full-match pattern
`[a-z0-9][a-z0-9._-]{0,127}`); `auto` is forbidden. Do not trim or normalize
invalid values into valid ones. Reject missing fields, wrong types, unknown
fields, malformed JSON, and multiple JSON documents. A valid ID's syntax does
**not** establish that the model exists or is available to an account.

Keep actual model choices only in the root policy, not duplicated as production
defaults in consumer code, repository variables, workflow YAML, or examples.
The `revision` is independent of this repository's release version.

## Onboard a consumer

1. Assign each invocation a role (`default` or `writer`). Implement resolution
   locally in the consumer's existing runtime, using a JSON parser rather than
   text matching. Download **data only**; never source, import, evaluate, or
   execute anything fetched from this URL.
2. Fetch once at the start of a run with a bounded timeout, bounded response size,
   and HTTP status checking. Validate the entire document before selecting a
   role. Reuse that in-memory snapshot for all invocations in the run so an
   intervening policy merge cannot change models halfway through.
3. Pass the selected ID as a single `--model` argument using an argument array
   or proper shell quoting, not command-string evaluation. A fetch, parse,
   validation, missing-role, or model-availability failure must stop the run with
   an actionable error. Do not silently use a stale cached policy, a bundled
   model, the CLI default, or another role's model.
4. Log the policy URL, schema version, revision, selected role, effective model
   ID, selection source (`policy` or `explicit override`), and CLI version
   before inference. Put the same information in the Actions step summary when
   applicable. Never log credentials, prompts, or tokens as part of resolution.
5. Add offline consumer tests for the happy path, both roles, invalid policy,
   network failure, overrides, and exact CLI arguments. Run an explicitly
   authorized availability check using the consumer's CLI version and workflow
   identity before production rollout; the producer's offline checks cannot do
   this for it.

Use the existing test/runtime dependencies in each consumer. There is no central
downloadable executable resolver or automatic model-discovery/upgrade job.

### Explicit overrides

A consumer may expose a deliberate, documented per-role override (for example
`COPILOT_MODEL` and `COPILOT_WRITER_MODEL`). Define its precedence as **a supplied,
validated override over the corresponding policy role**. An absent override
uses the policy; a supplied empty, whitespace-only, `auto`, or otherwise invalid
override is an error, not a request for fallback.

Log each override conspicuously, including the policy revision and the effective
ID. It is an exception to central governance and must be approved and removed
when no longer needed, not a second set of permanent defaults. Still fetch and
validate the policy even when overrides are supplied: an override must not
silently disable the central contract or hide an outage.

### Availability and fetch dependency

Model catalogs can differ by account, entitlement, organization policy, and CLI
version. A model listed for a developer's local credentials is not proof that
the identity behind an Actions secret can use it. The initial writer choice is
an intended replacement, not a claim of verified workflow-identity availability.
Preserve the CLI's explicit unavailable-model error and surface the selected
role, ID, and revision so an operator can request a reviewed change.

The public raw-file endpoint is a runtime dependency. Outages, rate limits,
timeouts, or invalid content block new runs rather than trigger fallback. An
already validated snapshot can finish its current run; do not silently reuse it
across runs. Fetching reviewed **data** from `main` is intentional so one approved
update reaches all consumers. It does not relax the rule that executable GitHub
Actions and reusable-workflow `uses:` references remain full-SHA-pinned.

## Review, change, and rollback

1. Propose a policy PR describing old and new IDs, affected roles and consumers,
   the reason, expected cost/behavior differences, availability evidence with
   the tested identity and CLI version, and a rollback plan. Notify affected
   owners **before merging** and wait for explicit human approval. A merged
   update affects subsequent consumer runs without a consumer release; logging
   a new revision after the fact is not advance notification.
2. Change only the root policy's model values and increase `revision` above the
   currently published revision. Do not add Renovate model upgrades, automerge,
   scheduled discovery, or silent fallback. Reviewers must check the revision
   increase against `main`; the offline schema test does not check Git history.
3. Run `mise exec -- bash ./tests/copilot-model-policy-contract.sh` and
   `mise run test`, plus the normal lint checks. The contract test uses the
   existing Bash/jq convention and makes no network or inference calls. It
   checks schema shape, safe positive-integer revision, explicit IDs, and
   negative cases, not account-specific model availability.
4. Merge through the normal reviewed PR path only after the required
   consumer-identity checks and advance notice. Keep the chosen IDs explicit
   even if the CLI changes its own defaults.
5. To roll back, submit another reviewed PR restoring previously approved model
   values with a **new, higher revision**, and confirm those models remain
   available. Do not reset the revision or blindly revert the whole JSON file.
   If no approved model is available, leave affected automation blocked.

For initial publication, merge the producer policy first and verify the raw URL
serves the approved document. Only then roll out consumer integrations. Never
deploy a consumer that depends on a policy URL that still returns 404.
