#!/usr/bin/env bash
# Answer, for a given pin, the only question that matters when a denial ships:
# does a consumer pinned there actually enforce it?
#
#   probe-propagation.sh <plan-file> <ref> [<ref>...]
#
# Each ref is materialized the way `uses: owner/repo@<ref>` materializes it, and the
# action's own entrypoint is run against the plan. What comes back is that pin's verdict.
#
# This exists because "three repositories consume the same action" is a statement about
# *wiring*, not about propagation. A consumer pinned to an immutable tag keeps running the
# denylist that tag froze, and it keeps passing — which looks identical, from the outside,
# to a consumer that is up to date and has nothing to deny. Those two must be told apart
# before someone needs an emergency denial, not after.

set -uo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root_dir=$(cd -- "${script_dir}/.." && pwd)

if [ "$#" -lt 2 ]; then
  printf 'Usage: %s <plan-file> <ref> [<ref>...]\n' "$0" >&2
  exit 2
fi

plan=$1; shift
[ -f "$plan" ] || { printf 'Plan file not found: %s\n' "$plan" >&2; exit 2; }
plan=$(cd -- "$(dirname -- "$plan")" && pwd)/$(basename -- "$plan")

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

printf 'Plan under test: %s\n' "${plan#"${root_dir}/"}"
printf 'Creates:         %s\n\n' \
  "$(jq -r '[.resource_changes[]?.type] | unique | join(", ")' "$plan" 2>/dev/null || echo '?')"

printf '%-14s %-10s %-12s %s\n' REF COMMIT VERDICT 'DENYLIST HAS IT'
printf '%-14s %-10s %-12s %s\n' -------------- ---------- ------------ ---------------

for ref in "$@"; do
  commit=$(git -C "$root_dir" rev-parse --short "${ref}^{commit}" 2>/dev/null) || {
    printf '%-14s %s\n' "$ref" 'cannot resolve this ref'
    continue
  }

  dest="${work}/${commit}-$(echo "$ref" | tr -c 'A-Za-z0-9._-' '_')"
  mkdir -p "$dest"
  git -C "$root_dir" archive "$ref" | tar -x -C "$dest"

  # Does that version's denylist even contain the types this plan creates?
  has=$(jq -r --slurpfile plan <(jq '[.resource_changes[]?.type]' "$plan") '
      [ .[].resource_type ] as $denied
      | [ $plan[0][] | select(. as $t | $denied | index($t)) ]
      | if length > 0 then "yes" else "no" end
    ' "${dest}/config/cost-guard-denylist.json" 2>/dev/null || echo '?')

  out=$(mktemp)
  INPUT_PLAN="$plan" \
  GITHUB_ACTION_PATH="$dest" \
  GITHUB_OUTPUT="$out" \
    bash "${dest}/scripts/action-entrypoint.sh" >/dev/null 2>&1
  status=$?
  verdict=$(sed -n 's/^verdict=//p' "$out")
  rm -f "$out"

  printf '%-14s %-10s %-12s %s\n' "$ref" "$commit" "${verdict:-?} ($status)" "$has"
done

printf '\nA pin whose verdict is `allow` is not protected against this plan. It is not\n'
printf 'failing — it is enforcing an older denylist, which looks the same from outside.\n'
