#!/usr/bin/env bash
# Assert the cost guard's public exit-code contract.

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root_dir=$(cd -- "${script_dir}/.." && pwd)

assert_exit() {
  local expected=$1
  local fixture=$2
  local actual

  set +e
  bash "${root_dir}/scripts/cost-guard.sh" "$fixture" >/dev/null 2>&1
  actual=$?
  set -e

  if [[ "$actual" -ne "$expected" ]]; then
    printf 'Expected exit %s, got %s for %s.\n' "$expected" "$actual" "$fixture" >&2
    exit 1
  fi
}

assert_exit 1 "${root_dir}/tests/fixtures/plan-with-nat.json"
assert_exit 1 "${root_dir}/tests/fixtures/plan-events-with-nat.jsonl"
assert_exit 0 "${root_dir}/tests/fixtures/plan-clean.json"
assert_exit 2 "${root_dir}/tests/fixtures/plan-errored.jsonl"
assert_exit 2 "${root_dir}/tests/fixtures/plan-unrecognizable.txt"

empty_file=$(mktemp)
trap 'rm -f "$empty_file"' EXIT
assert_exit 2 "$empty_file"
