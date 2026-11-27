# Effective Renovate settings for one update, from the shared package rules.
#
# Input: the packageRules of the .renovate presets, concatenated in the order
# .renovate/default.json5 extends them. Arguments:
#   $dep   the update: {manager, datasource, updateType, packageName,
#          currentValue, depType, depName (defaults to packageName)}
#   $base  starting settings (e.g. minimumReleaseAge from base.json5)
#
# Only the matchers the shared rules use for these decisions are modelled. A
# rule with any other matcher (matchCurrentAge, matchDepNames, ...) is treated
# as not matching, so tests must not rely on those rules.

def pattern_match($value):
    . as $p
    | if startswith("/") then ($value | test($p | ltrimstr("/") | rtrimstr("/")))
      elif endswith("/**") then ($value | ascii_downcase | startswith($p | rtrimstr("**") | ascii_downcase))
      else ($value | ascii_downcase) == ($p | ascii_downcase) end;

def in_list($key; $value):
    (.[$key] // null) as $list | $list == null or ($list | index($value) != null);

def names_match($value):
    (.matchPackageNames // null) as $patterns
    | $patterns == null
      or (([$patterns[] | select(startswith("!") | not)] as $pos
           | ($pos | length) == 0 or any($pos[]; pattern_match($value)))
          and ([$patterns[] | select(startswith("!")) | ltrimstr("!")] | all(.[]; pattern_match($value) | not)));

def known: ["matchManagers", "matchUpdateTypes", "matchDatasources", "matchCurrentValue", "matchPackageNames", "matchDepTypes", "matchDepNames"];

def matches:
    ([keys[] | select(startswith("match"))] - known | length) == 0
    and in_list("matchManagers"; $dep.manager)
    and in_list("matchUpdateTypes"; $dep.updateType)
    and in_list("matchDatasources"; $dep.datasource)
    and in_list("matchDepTypes"; $dep.depType)
    and ((.matchCurrentValue // null) as $v | $v == null or ($v | pattern_match($dep.currentValue)))
    and names_match($dep.packageName)
    and ((.matchDepNames // null) as $names | $names == null
        or any($names[]; pattern_match($dep.depName // $dep.packageName)));

reduce (.[] | select(matches)) as $r ({enabled: true, labels: []} + $base;
    . + ($r | with_entries(select(.key | IN("enabled", "automerge", "groupName", "minimumGroupSize", "minimumReleaseAge",
        "minimumReleaseAgeBehaviour", "additionalBranchPrefix", "pinDigests", "allowedVersions"))))
    | .labels += ($r.addLabels // []))
