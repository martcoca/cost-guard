#!/usr/bin/env bash
# Demonstrate the composite action from a repository that is not this one.
#
# The packet requires the interface to be *demonstrated*, not reasoned about. GitHub
# Actions cannot run on a laptop, so this reproduces the only parts of the runner that the
# interface actually depends on:
#
#   - the consumer is a separate git repository, built here from nothing;
#   - the action's repository is materialized at a ref into GITHUB_ACTION_PATH, exactly as
#     `uses: <owner>/cost-guard@<ref>` does;
#   - the runner's environment contract (INPUT_PLAN, GITHUB_ACTION_PATH, GITHUB_OUTPUT,
#     GITHUB_STEP_SUMMARY) is supplied, and scripts/action-entrypoint.sh — the same file
#     action.yml invokes — is executed.
#
# What it therefore proves: a repository holding no copy of the guard or the denylist gets
# the correct verdict and the correct exit code for all three outcomes. What it cannot
# prove is GitHub's own resolution of `uses:` against a published tag; the workflow in CI
# covers the run-on-a-runner half.
#
# Usage: demo-consumer.sh [ref]     (default: HEAD)

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root_dir=$(cd -- "${script_dir}/.." && pwd)
ref="${1:-HEAD}"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

consumer="${work}/consumer-repo"
action_path="${work}/action-checkout"
mkdir -p "$consumer" "$action_path"

failed=0
note_fail() { printf 'FAIL: %s\n' "$1" >&2; failed=1; }

# ---------------------------------------------------------------------------
# 1. The action's repository, materialized at a ref the way a runner does.
# ---------------------------------------------------------------------------
git -C "$root_dir" archive "$ref" | tar -x -C "$action_path"
printf 'Action checkout: %s at %s\n' "$(git -C "$root_dir" rev-parse --short "$ref")" "$action_path"

for required in action.yml scripts/action-entrypoint.sh scripts/cost-guard.sh \
                config/cost-guard-denylist.json; do
  [ -e "${action_path}/${required}" ] \
    || note_fail "the action checkout is missing ${required}"
done

# ---------------------------------------------------------------------------
# 2. A consumer repository that has never seen the guard.
# ---------------------------------------------------------------------------
git -C "$consumer" init -q 2>/dev/null || git init -q "$consumer"
mkdir -p "${consumer}/.github/workflows" "${consumer}/plans"

# The consumer writes its own plans. Reusing this repository's fixtures would quietly test
# the fixtures rather than the interface.
cat > "${consumer}/plans/nat.json" <<'JSON'
{
  "format_version": "1.2",
  "terraform_version": "1.6.0",
  "resource_changes": [
    {
      "address": "azurerm_nat_gateway.egress",
      "mode": "managed",
      "type": "azurerm_nat_gateway",
      "name": "egress",
      "change": { "actions": ["create"], "before": null, "after": {} }
    }
  ]
}
JSON

cat > "${consumer}/plans/clean.json" <<'JSON'
{
  "format_version": "1.2",
  "terraform_version": "1.6.0",
  "resource_changes": [
    {
      "address": "azurerm_resource_group.main",
      "mode": "managed",
      "type": "azurerm_resource_group",
      "name": "main",
      "change": { "actions": ["create"], "before": null, "after": {} }
    }
  ]
}
JSON

: > "${consumer}/plans/empty.json"

cat > "${consumer}/.github/workflows/plan.yml" <<'YAML'
name: Guarded plan
on: [push]
permissions:
  contents: read
jobs:
  plan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: tofu plan -input=false -no-color -json > plan.json
      - uses: OWNER/cost-guard@v1
        with:
          plan: plan.json
YAML

git -C "$consumer" add -A
git -C "$consumer" -c user.email=demo@example.invalid -c user.name=demo \
  commit -q -m 'Consume the cost guard'

# ---------------------------------------------------------------------------
# 3. The consumer holds no copy of either file. This is the goal, stated as a test.
# ---------------------------------------------------------------------------
copies=$(cd "$consumer" && git ls-files \
  | grep -E '(cost-guard\.sh|cost-guard-denylist\.json)$' || true)
if [ -n "$copies" ]; then
  note_fail "the consumer repository contains copies of the guard: ${copies}"
else
  printf 'Consumer tracks %s files, none of them the guard or the denylist.\n' \
    "$(cd "$consumer" && git ls-files | wc -l | tr -d ' ')"
fi

# ---------------------------------------------------------------------------
# 4. Run the action's own entrypoint under the runner's environment contract.
# ---------------------------------------------------------------------------
run_action() {
  local plan=$1 expect_status=$2 expect_verdict=$3
  local outputs summary status verdict code

  outputs=$(mktemp); summary=$(mktemp)

  set +e
  ( cd "$consumer" \
    && INPUT_PLAN="$plan" \
       GITHUB_ACTION_PATH="$action_path" \
       GITHUB_OUTPUT="$outputs" \
       GITHUB_STEP_SUMMARY="$summary" \
       bash "${action_path}/scripts/action-entrypoint.sh" ) >/dev/null 2>&1
  status=$?
  set -e

  verdict=$(sed -n 's/^verdict=//p'   "$outputs")
  code=$(sed    -n 's/^exit-code=//p' "$outputs")

  if [ "$status" != "$expect_status" ]; then
    note_fail "${plan}: expected exit ${expect_status}, got ${status}"
  elif [ "$verdict" != "$expect_verdict" ]; then
    note_fail "${plan}: expected verdict ${expect_verdict}, got '${verdict}'"
  elif [ "$code" != "$expect_status" ]; then
    note_fail "${plan}: verdict output said exit ${code}, guard exited ${status}"
  elif [ ! -s "$summary" ]; then
    note_fail "${plan}: the action wrote no step summary"
  else
    printf 'PASS  %-14s exit %s  verdict %s\n' "$plan" "$status" "$verdict"
  fi

  rm -f "$outputs" "$summary"
}

printf '\nConsumer runs `uses: OWNER/cost-guard@%s` against its own plans:\n' "$ref"
run_action plans/nat.json   1 deny
run_action plans/clean.json 0 allow
run_action plans/empty.json 2 undecidable

# A plan file the consumer never produced, because a plan step that failed leaves nothing
# behind and the guard must not read that as clean.
run_action plans/missing.json 2 undecidable

if [ "$failed" -ne 0 ]; then
  printf '\nThe interface did not behave as documented.\n' >&2
  exit 1
fi

printf '\nThe interface works from a repository that holds neither file.\n'
