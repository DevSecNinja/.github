#!/usr/bin/env bash
#
# Syncs the repository's labels with the label config files (job label-sync of
# .github/workflows/label-sync.yml). CONFIG_FILES lists the files, one per
# line, as resolve-config-files.sh found them; a later file wins over an
# earlier one for the same label. Each label in the files is:
#   - edited when a label of that name exists (names match case-insensitively),
#   - otherwise renamed from the first existing label named in its `aliases`,
#     so issues and pull requests keep it,
#   - otherwise created.
# A label without a description keeps the one it has. With
# DELETE_OTHER_LABELS=true every other label is deleted, except a leftover
# alias of a label that already exists: deleting it would unlabel its issues,
# so it gets a warning to move them by hand.
#
# Needs yq, jq and gh, with GH_TOKEN and GH_REPO set.

set -euo pipefail

: "${CONFIG_FILES:?CONFIG_FILES must list the label config files}"
delete_other="${DELETE_OTHER_LABELS:-false}"

desired_parts=()
while IFS= read -r file; do
    [ -z "${file}" ] && continue
    desired_parts+=("$(yq -o=json '.' "${file}")")
done <<<"${CONFIG_FILES}"

# Merge the files (the last file wins per name) and normalise colours.
desired="$(printf '%s\n' "${desired_parts[@]}" | jq -s '
    map(. // []) | add // []
    | map(.color |= (tostring | ltrimstr("#") | ascii_downcase))
    | reverse | unique_by(.name | ascii_downcase)')"

invalid="$(jq -r '.[] | select((.name | type) != "string" or .name == ""
    or (.color | test("^[0-9a-f]{6}$") | not)
    or ((.description | type) | IN("string", "null") | not)) | tojson' <<<"${desired}")"
if [ -n "${invalid}" ]; then
    echo "::error::Labels need a name, a six-digit hex colour (quote it in YAML) and a text description, if any:"
    echo "${invalid}"
    exit 1
fi

existing="$(gh label list --limit 1000 --json name,color,description)"

plan="$(jq -c --argjson delete "${delete_other}" '
    def lc: ascii_downcase;
    . as [$desired, $existing]
    | [$desired[] | .name as $name | .aliases[]? | {alias: lc, name: $name}] as $aliases
    | reduce $desired[] as $label ({used: [], actions: []};
        .used as $used
        | [$existing[] | select((.name | lc) as $n | any($used[]; . == $n) | not)] as $free
        | ([$free[] | select((.name | lc) == ($label.name | lc))] | first) as $same
        | ([$label.aliases[]? | lc] as $own
            | [$free[] | select((.name | lc) as $n | any($own[]; . == $n))] | first) as $alias
        | ($same // $alias) as $current
        | if $current == null then
            .actions += [$label + {action: "create"}]
          else
            .used += [$current.name | lc]
            | if $current.name == $label.name and ($current.color | lc) == $label.color
                and ($label.description == null or ($current.description // "") == $label.description)
              then .
              else .actions += [$label + {action: "edit", from: $current.name}] end
          end)
    | .used as $used
    | .actions + if $delete then
        [$existing[] | (.name | lc) as $n | select(any($used[]; . == $n) | not)
            | ([$aliases[] | select(.alias == $n) | .name] | first) as $of
            | if $of == null then {action: "delete", name} else {action: "keep", name, of: $of} end]
      else [] end
    | .[]' <<<"[${desired}, ${existing}]")"

if [ -z "${plan}" ]; then
    echo "✓ Labels are in sync."
    exit 0
fi

while IFS= read -r action; do
    kind="$(jq -r '.action' <<<"${action}")"
    name="$(jq -r '.name' <<<"${action}")"
    args=(--color "$(jq -r '.color' <<<"${action}")")
    if [ "$(jq -r '.description | type' <<<"${action}")" = "string" ]; then
        args+=(--description "$(jq -r '.description' <<<"${action}")")
    fi
    case "${kind}" in
    create)
        echo "+ create '${name}'"
        gh label create "${name}" "${args[@]}"
        ;;
    edit)
        from="$(jq -r '.from' <<<"${action}")"
        if [ "${from}" = "${name}" ]; then
            echo "~ edit '${name}'"
        else
            echo "~ rename '${from}' to '${name}'"
        fi
        gh label edit "${from}" --name "${name}" "${args[@]}"
        ;;
    delete)
        echo "- delete '${name}'"
        gh label delete "${name}" --yes
        ;;
    keep)
        echo "::warning::Label '${name}' is an alias of '$(jq -r '.of' <<<"${action}")', which already exists; move its issues and pull requests to that label and delete it by hand."
        ;;
    *)
        echo "::error::Unknown label action '${kind}'"
        exit 1
        ;;
    esac
done <<<"${plan}"
