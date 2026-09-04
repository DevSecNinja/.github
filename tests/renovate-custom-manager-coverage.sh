#!/usr/bin/env bash
#
# Ensure every Renovate custom manager is governed by the same package-rule
# conventions as the rest of the repository.
#
# Custom-managed dependencies are wired to package rules via their datasource.
# For each datasource a custom manager emits, this test checks that the preset
# files cover every governance dimension the repo applies to first-class
# managers:
#
#   - automerge          : a non-major automerge decision, satisfied by the
#                          global rule or a per-datasource one
#                          (.renovate/autoMerge.json5)
#   - minimumReleaseAge  : a soak time, satisfied by a per-datasource rule or the
#                          global default in .renovate/base.json5
#   - label              : a renovate/<source> label (.renovate/labels.json5)
#   - semanticCommitScope: a commit scope (.renovate/semanticCommits.json5)
#
# A gap here is exactly what left DevSecNinja/docker#107 unmerged: a dependency
# type with no matching rule silently falls back to repo/Renovate defaults.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
renovate_dir="${repo_root}/.renovate"
custom_managers="${renovate_dir}/customManagers.json5"
base_config="${renovate_dir}/base.json5"

if ! command -v pyjson5 >/dev/null 2>&1; then
    echo "error: 'pyjson5' not found on PATH. Run via 'mise run test'." >&2
    exit 1
fi

to_json() {
    pyjson5 --as-json "$1"
}

# Every package rule across all preset files, merged into one array.
rules_json="$(
    for f in "${renovate_dir}"/*.json5; do
        to_json "${f}"
    done | jq -s '[.[] | (.packageRules // [])[]]'
)"

# Custom managers as [{description, datasource}].
managers_json="$(
    to_json "${custom_managers}" |
        jq '[.customManagers[]
            | {description: (.description // "(no description)"), datasource: .datasourceTemplate}]'
)"

# Global minimumReleaseAge default (applies to every datasource when set).
global_min_age="$(to_json "${base_config}" | jq '.minimumReleaseAge // null')"

problems_json="$(
    jq -n \
        --argjson managers "${managers_json}" \
        --argjson rules "${rules_json}" \
        --argjson globalMinAge "${global_min_age}" '
        def coversDs($d): (.matchDatasources // []) | index($d);
        def nonMajor: (.matchUpdateTypes == null)
            or (any(.matchUpdateTypes[]; . == "minor" or . == "patch"));
        def covered($d; pred): [$rules[] | select(coversDs($d)) | select(pred)] | length > 0;

        # A global automerge rule (no manager/datasource/package scoping) applies
        # to every datasource, so it satisfies the automerge dimension for all.
        def globalAutomerge: [$rules[]
            | select(has("automerge")
                and (.matchManagers == null)
                and (.matchDatasources == null)
                and (.matchPackageNames == null)
                and nonMajor)] | length > 0;

        # Custom managers missing a datasourceTemplate entirely.
        ($managers
            | map(select(.datasource == null))
            | map({kind: "missing-datasource", description})) as $no_ds

        # Datasource-level governance gaps. Dynamic datasourceTemplates (Renovate
        # templates like "{{{datasource}}}") resolve per-dependency, so they
        # cannot be governed by a fixed datasource and are skipped here.
        | ([$managers[] | .datasource]
            | map(select(. != null and (contains("{{") | not)))
            | unique) as $datasources
        | ($datasources
            | map(. as $d
                | {
                    automerge: (globalAutomerge
                        or covered($d; has("automerge") and nonMajor)),
                    minimumReleaseAge: (($globalMinAge != null)
                        or covered($d; has("minimumReleaseAge"))),
                    label: covered($d; ((.addLabels // []) + (.labels // []))
                        | any(startswith("renovate/"))),
                    semanticCommitScope: covered($d; has("semanticCommitScope")),
                } as $cov
                | {
                    kind: "datasource-gap",
                    datasource: $d,
                    missing: (["automerge", "minimumReleaseAge", "label", "semanticCommitScope"]
                        | map(select($cov[.] == false))),
                    managers: [$managers[] | select(.datasource == $d) | .description],
                })
            | map(select(.missing | length > 0))) as $gaps

        | $no_ds + $gaps
    '
)"

problem_count="$(echo "${problems_json}" | jq 'length')"

if [ "${problem_count}" -ne 0 ]; then
    echo "✖ ${problem_count} custom-manager governance problem(s) found:" >&2
    echo "${problems_json}" | jq -r '
        .[]
        | if .kind == "missing-datasource" then
            "  - manager \"\(.description)\" has no datasourceTemplate"
          else
            "  - datasource \"\(.datasource)\" is missing rules: \(.missing | join(", "))\n      used by: \(.managers | join("; "))"
          end
    ' >&2
    echo "" >&2
    echo "Add the missing rules under .renovate/ (autoMerge, packageRules, labels," >&2
    echo "semanticCommits) so the datasource matches the rest of the repo's conventions." >&2
    exit 1
fi

manager_count="$(echo "${managers_json}" | jq 'length')"
echo "✓ All ${manager_count} custom manager(s) are governed in line with repo conventions."
