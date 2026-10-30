#!/usr/bin/env bash
# shellcheck disable=SC2310 # The validator has one command; callers explicitly check its exit status.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
policy="${repo_root}/copilot-models.json"

fail() {
    echo "error: $*" >&2
    exit 1
}

command -v jq >/dev/null 2>&1 ||
    fail "'jq' not found on PATH; install jq before running repository tests."

validate_policy() {
    jq -es '
        def explicit_model:
            if type == "string" then
                length <= 128
                and test("^[a-z0-9]")
                and (test("[^a-z0-9._-]") | not)
                and . != "auto"
            else false end;
        length == 1
        and (.[0]
            | type == "object"
            and keys == ["models", "revision", "schemaVersion"]
            and .schemaVersion == 1
            and (.revision
                | type == "number"
                and . >= 1
                and . <= 9007199254740991
                and . == floor)
            and (.models
                | type == "object"
                and keys == ["default", "writer"]
                and all(.[]; explicit_model)))
    ' "$@" >/dev/null
}

validate_policy "${policy}" || fail "${policy} violates the schema-v1 model policy contract."

for revision in 1 2 9007199254740991; do
    candidate="$(jq --argjson revision "${revision}" '.revision = $revision' "${policy}")"
    printf '%s\n' "${candidate}" | validate_policy ||
        fail "a safe positive integer policy revision must be accepted: ${revision}"
done

for mutation in \
    'del(.schemaVersion)' \
    '.schemaVersion = 2' \
    '.schemaVersion = 1.5' \
    '.schemaVersion = "1"' \
    '.schemaVersion = true' \
    'del(.revision)' \
    '.revision = 0' \
    '.revision = -1' \
    '.revision = 1.5' \
    '.revision = "1"' \
    '.revision = true' \
    '.revision = null' \
    '.revision = 9007199254740992' \
    'del(.models)' \
    '.models = null' \
    '.models = []' \
    '.models = {}' \
    'del(.models.default)' \
    'del(.models.writer)' \
    '.models.default = null' \
    '.models.writer = false' \
    '.models.default = 1' \
    '.models.writer = []' \
    '.models.writer = {}' \
    '.models.extra = .models.default' \
    '.extra = true'; do
    candidate="$(jq "${mutation}" "${policy}")"
    if printf '%s\n' "${candidate}" | validate_policy 2>/dev/null; then
        fail "invalid policy passed validation: ${mutation}"
    fi
done

for role in default writer; do
    candidate="$(jq --arg role "${role}" '.models[$role] = ("a" * 128)' "${policy}")"
    printf '%s\n' "${candidate}" | validate_policy ||
        fail "a 128-character ${role} model ID must be accepted."
    candidate="$(jq --arg role "${role}" '.models[$role] = ("a" * 129)' "${policy}")"
    if printf '%s\n' "${candidate}" | validate_policy 2>/dev/null; then
        fail "a 129-character ${role} model ID must be rejected."
    fi

    for model in \
        "" \
        " " \
        "auto" \
        "AUTO" \
        "Auto" \
        "--model" \
        " model" \
        "model " \
        "model name" \
        "model/name" \
        "model;command" \
        "\$(command)" \
        $'model\n' \
        $'model\r' \
        $'model\t'; do
        candidate="$(jq --arg role "${role}" --arg model "${model}" \
            '.models[$role] = $model' "${policy}")"
        if printf '%s\n' "${candidate}" | validate_policy 2>/dev/null; then
            fail "invalid ${role} model passed validation: ${model}"
        fi
    done
done

for invalid_json in "" "{" '{"schemaVersion":1,}' "[]" "null" "true" "1" '"policy"'; do
    if printf '%s\n' "${invalid_json}" | validate_policy 2>/dev/null; then
        fail "malformed or non-object policy passed validation: ${invalid_json}"
    fi
done

policy_json="$(jq -c . "${policy}")"
if printf '%s\n%s\n' "${policy_json}" "${policy_json}" | validate_policy 2>/dev/null; then
    fail "multiple JSON documents must be rejected."
fi

echo "Copilot model policy schema and explicit-model contract are enforced (offline only)."
