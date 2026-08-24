#!/usr/bin/env bash
# Prove that scripts/test-cost-guard.sh can fail.
#
# A green suite means nothing until you have watched it go red. platform-azure made this
# point with its denylist-agreement check, whose CI punched a hole in the denylist and
# asserted the check noticed. The same technique is what protects this repository: a suite
# that passed because it silently stopped asserting anything is the exact failure mode a
# shared guard cannot afford, because three repositories will trust it.
#
# Each mutation is applied to a throwaway copy of the tree. The working copy is never
# touched, so this is safe to run locally and cannot leave a holed denylist behind.

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root_dir=$(cd -- "${script_dir}/.." && pwd)

command -v jq >/dev/null 2>&1 || { printf 'This check requires jq.\n' >&2; exit 2; }

failed=0

# The suite must pass unmutated, or "it failed" proves nothing about the mutation.
if ! bash "${root_dir}/scripts/test-cost-guard.sh" >/dev/null 2>&1; then
  printf 'FAIL: the suite does not pass before any mutation is applied.\n' >&2
  exit 1
fi
printf 'PASS  the suite passes unmutated\n'

expect_suite_fails() {
  local description=$1
  local mutate=$2
  local sandbox

  sandbox=$(mktemp -d)

  # A copy, not the real tree: a mutation that escaped would be a holed denylist committed
  # by accident, which is worse than having no check at all.
  git -C "$root_dir" archive HEAD | tar -x -C "$sandbox"

  "$mutate" "$sandbox"

  if bash "${sandbox}/scripts/test-cost-guard.sh" >/dev/null 2>&1; then
    printf 'FAIL: %s, and the suite still passed.\n' "$description" >&2
    failed=1
  else
    printf 'PASS  %s, and the suite failed\n' "$description"
  fi

  rm -rf "$sandbox"
}

# Mutation 1 — data. Remove the type the deny fixture relies on. The suite's exit-1
# assertion must stop holding.
hole_the_denylist() {
  local sandbox=$1
  jq 'map(select(.resource_type != "aws_nat_gateway"))' \
    "${sandbox}/config/cost-guard-denylist.json" > "${sandbox}/denylist.holed"
  mv "${sandbox}/denylist.holed" "${sandbox}/config/cost-guard-denylist.json"
}

# Mutation 2 — code, and the one the README warns about by name. Someone "simplifies" the
# empty-input path into a pass. Nothing about the plan fixtures changes; only the
# fail-closed contract is removed. If the suite cannot see this, it is not protecting the
# property this repository exists for.
soften_the_empty_input_path() {
  local sandbox=$1
  local guard="${sandbox}/scripts/cost-guard.sh"
  perl -0pi -e "s/(cost-guard: empty input; refusing to report a plan as clean.*?\n)  exit 2/\$1  exit 0/s" "$guard"
  grep -q "refusing to report a plan as clean" "$guard" \
    || { printf 'mutation did not apply cleanly\n' >&2; exit 1; }
}

expect_suite_fails "aws_nat_gateway is removed from the denylist" hole_the_denylist
expect_suite_fails "the empty-input path is softened to exit 0"  soften_the_empty_input_path

# --- the same treatment for the rules this repository added later ---------------------
#
# A generalised version of the helper above: run any suite in the sandbox and require the
# mutation to turn it red. The two rules below are the ones with no natural failing
# fixture, so without these they would be asserted only by tests nobody has watched fail.
expect_named_suite_fails() {
  local suite=$1 description=$2 mutate=$3
  local sandbox
  sandbox=$(mktemp -d)
  git -C "$root_dir" archive HEAD | tar -x -C "$sandbox"
  "$mutate" "$sandbox"
  if bash "${sandbox}/scripts/${suite}" >/dev/null 2>&1; then
    printf 'FAIL: %s, and %s still passed.\n' "$description" "$suite" >&2
    failed=1
  else
    printf 'PASS  %s, and %s failed\n' "$description" "$suite"
  fi
  rm -rf "$sandbox"
}

# The guard quietly acquires a network call. No fixture's expected exit code changes, and
# every other suite in this repository stays green — which is exactly why this mutation is
# worth having a test for.
give_the_guard_a_network_call() {
  local sandbox=$1
  perl -0pi -e 's/^(plan_input=\$\(cat -- "\$plan_file"\))$/curl -s https:\/\/example.invalid\/denylist >\/dev\/null 2>&1 || true\n$1/m' \
    "${sandbox}/scripts/cost-guard.sh"
  grep -q 'curl -s' "${sandbox}/scripts/cost-guard.sh" \
    || { printf 'mutation did not apply cleanly\n' >&2; exit 1; }
}

# The freshness signal reports a lookup it could not perform as `current`. This is the
# precise defect the epic exists to remove, so it must not be possible to reintroduce it
# without a test going red.
report_unknown_as_current() {
  local sandbox=$1
  perl -0pi -e 's/  status=unknown\n  detail=.the current release could not be determined./  status=current\n  detail="the current release could not be determined"/' \
    "${sandbox}/scripts/freshness.sh"
  grep -q 'status=current$' "${sandbox}/scripts/freshness.sh" \
    || { printf 'mutation did not apply cleanly\n' >&2; exit 1; }
}

expect_named_suite_fails test-no-network.sh \
  "the guard is given a network call" give_the_guard_a_network_call
expect_named_suite_fails test-freshness.sh \
  "an unknown lookup is reported as current" report_unknown_as_current

if [ "$failed" -ne 0 ]; then
  printf '\nThe suite cannot detect a broken guard. It is not evidence of anything.\n' >&2
  exit 1
fi

printf '\nThe suite reacts to a broken denylist and to a broken fail-closed path.\n'
