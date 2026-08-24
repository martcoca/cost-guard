#!/usr/bin/env bash
# Assert the freshness signal's rules, including the ones that only matter when things go
# wrong. Hermetic: a stub `gh` on PATH stands in for the API, so these tests make no
# network call and cannot pass or fail because of one.

set -uo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
freshness="${script_dir}/freshness.sh"

failed=0
stub_dir=$(mktemp -d)
trap 'rm -rf "$stub_dir"' EXIT

# A stub `gh` driven by a table: "<api-path-suffix> <value>" lines. A path with no entry
# exits 1, which is how the real CLI reports a ref or release it cannot find.
make_gh() {
  cat > "${stub_dir}/gh" <<'STUB'
#!/usr/bin/env bash
# stub gh: resolves from $GH_TABLE, exits 1 for anything absent
[ "${1:-}" = "api" ] || exit 1
path=$2
while IFS= read -r line; do
  [ -n "$line" ] || continue
  key=${line%% *}; val=${line#* }
  if [ "$path" = "$key" ]; then
    [ "$val" = "__FAIL__" ] && exit 1
    printf '%s\n' "$val"
    exit 0
  fi
done <<< "$GH_TABLE"
exit 1
STUB
  chmod +x "${stub_dir}/gh"
}
make_gh

run() {
  # run <table> <pin> [fail_on_stale] -> sets $STATUS $EXIT $OUT_DETAIL
  local table=$1 pin=$2 fos=${3:-false}
  local outputs; outputs=$(mktemp)
  GH_TABLE="$table" \
  PATH="${stub_dir}:$PATH" \
  INPUT_PIN="$pin" \
  INPUT_REPOSITORY='martcoca/cost-guard' \
  INPUT_FAIL_ON_STALE="$fos" \
  GITHUB_OUTPUT="$outputs" \
    bash "$freshness" >/dev/null 2>&1
  EXIT=$?
  STATUS=$(sed -n 's/^status=//p' "$outputs")
  OUT_DETAIL=$(sed -n 's/^detail=//p' "$outputs")
  rm -f "$outputs"
}

check() {
  local label=$1 want_status=$2 want_exit=$3
  if [ "$STATUS" != "$want_status" ]; then
    printf 'FAIL  %s: expected status %s, got "%s"\n' "$label" "$want_status" "$STATUS" >&2
    failed=1
  elif [ "$EXIT" != "$want_exit" ]; then
    printf 'FAIL  %s: expected exit %s, got %s\n' "$label" "$want_exit" "$EXIT" >&2
    failed=1
  else
    printf 'PASS  %-46s %s (exit %s)\n' "$label" "$STATUS" "$EXIT"
  fi
}

AHEAD='repos/martcoca/cost-guard/releases/latest v1.0.1
repos/martcoca/cost-guard/commits/v1.0.1 93fada3e1d3760860e72d1ee5887494bb975f73a
repos/martcoca/cost-guard/commits/v1.0.0 83999e6e226acae0132ca480e0c41c66cbf077e0
repos/martcoca/cost-guard/commits/v1 93fada3e1d3760860e72d1ee5887494bb975f73a'

# --- the two ordinary answers --------------------------------------------------------
run "$AHEAD" 'martcoca/cost-guard@v1.0.0'; check 'an older immutable pin is behind' behind 0
run "$AHEAD" 'martcoca/cost-guard@v1.0.1'; check 'the current release is current'   current 0

# --- the moving tag, which a string comparison gets wrong ------------------------------
# @v1 and @v1.0.1 are different strings and the same commit. T05 traced a consumer being
# called behind for exactly this. If this ever reports `behind`, the comparison has
# regressed from versions to strings.
run "$AHEAD" 'martcoca/cost-guard@v1'; check 'a moved major tag is current, not behind' current 0

# --- unknown is never laundered into current ------------------------------------------
NO_RELEASE='repos/martcoca/cost-guard/commits/v1.0.0 83999e6e226acae0132ca480e0c41c66cbf077e0'
run "$NO_RELEASE" 'martcoca/cost-guard@v1.0.0'; check 'no release lookup is unknown' unknown 0

NO_REF='repos/martcoca/cost-guard/releases/latest v1.0.1
repos/martcoca/cost-guard/commits/v1.0.1 93fada3e1d3760860e72d1ee5887494bb975f73a'
run "$NO_REF" 'martcoca/cost-guard@v0.9.9'; check 'an unresolvable pin is unknown' unknown 0

run '' 'martcoca/cost-guard@v1.0.0'; check 'a total lookup failure is unknown' unknown 0

# --- a failed lookup must never fail the step, even under fail-on-stale ----------------
# This is the rule that keeps a consumer's CI independent of the API. If it ever exits
# non-zero, every consumer's pipeline has quietly acquired a network dependency.
run '' 'martcoca/cost-guard@v1.0.0' true
check 'unknown does not fail even with fail-on-stale' unknown 0

# --- fail-on-stale does what it says on a real staleness ------------------------------
run "$AHEAD" 'martcoca/cost-guard@v1.0.0' true; check 'fail-on-stale fails when behind' behind 1
run "$AHEAD" 'martcoca/cost-guard@v1.0.1' true; check 'fail-on-stale passes when current' current 0

# --- a bare ref alongside `repository` ------------------------------------------------
run "$AHEAD" 'v1.0.0'; check 'a bare ref resolves against `repository`' behind 0

# --- configuration errors are loud, not `unknown` -------------------------------------
# A missing pin is deterministic and fixable. Reporting it as unknown freshness would hide
# a broken workflow behind a word that means "the network was unhelpful".
run "$AHEAD" ''; check 'an empty pin is a configuration error' '' 2

if [ "$failed" -ne 0 ]; then
  printf '\nThe freshness signal does not obey its own rules.\n' >&2
  exit 1
fi
printf '\nAll freshness rules hold, including that unknown is never reported as current.\n'
