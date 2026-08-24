#!/usr/bin/env bash
# Prove the guard's verdict does not depend on the network.
#
# This is the property the freshness signal was built as a separate action to protect. It
# is also the property most likely to be lost by accident later — a convenience lookup
# added "just for a warning" inside the guard would not change a single test's expected
# value, and every existing test would still pass.
#
# Two independent checks, because either alone is weak:
#
#   1. Static: the guard and the action entrypoint contain no network primitive. Catches a
#      dependency added anywhere on any code path, including ones no fixture reaches.
#   2. Dynamic: the exit contract holds with the network actually removed. Catches a
#      dependency reached through something the static check does not name.
#
# The dynamic half needs real isolation. If this host offers none, that is reported and
# the script fails rather than passing on the static check alone — a proof that did not
# run is not a proof, and this file exists to stop exactly that kind of quiet pass.

set -uo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root_dir=$(cd -- "${script_dir}/.." && pwd)
guard="${root_dir}/scripts/cost-guard.sh"
fixtures="${root_dir}/tests/fixtures"

failed=0

# --- 1. static -----------------------------------------------------------------------
# Comments are stripped first: this file's own prose names these tools, and so does the
# guard's. Matching on the comment would make the check fail for explaining itself.
printf 'Static: no network primitive on any path through the guard\n'
for f in "${root_dir}/scripts/cost-guard.sh" "${root_dir}/scripts/action-entrypoint.sh"; do
  stripped=$(sed 's/#.*//' "$f")
  hits=$(printf '%s\n' "$stripped" \
    | grep -nE '\b(curl|wget|nc|ncat|telnet|ssh|scp|gh|aws|az|gcloud)\b|git[[:space:]]+(fetch|clone|ls-remote|pull|push)|/dev/tcp/' \
    || true)
  if [ -n "$hits" ]; then
    printf 'FAIL  %s reaches for the network:\n%s\n' "${f#"${root_dir}/"}" "$hits" >&2
    failed=1
  else
    printf 'PASS  %s\n' "${f#"${root_dir}/"}"
  fi
done

# --- 2. dynamic ----------------------------------------------------------------------
# Three mechanisms, because no single one covers both platforms. Ubuntu 24.04 restricts
# unprivileged user namespaces, so `unshare -rn` can fail on a runner where `sudo unshare`
# works; each candidate is probed rather than assumed from the platform name.
isolate=''
if [ "$(uname -s)" = "Darwin" ] && command -v sandbox-exec >/dev/null 2>&1; then
  isolate='sandbox'
elif command -v unshare >/dev/null 2>&1 && unshare -rn true >/dev/null 2>&1; then
  isolate='unshare'
elif command -v unshare >/dev/null 2>&1 && sudo -n unshare -n true >/dev/null 2>&1; then
  isolate='sudo-unshare'
fi

run_isolated() {
  case "$isolate" in
    sandbox)      sandbox-exec -p '(version 1)(allow default)(deny network*)' "$@" ;;
    unshare)      unshare -rn "$@" ;;
    sudo-unshare) sudo -n unshare -n "$@" ;;
  esac
}

if [ -z "$isolate" ]; then
  printf '\nFAIL  no network isolation available on this host (tried sandbox-exec, unshare, sudo unshare).\n' >&2
  printf '      Refusing to report the guard as network-independent without testing it.\n' >&2
  exit 1
fi

printf '\nDynamic: the exit contract with the network removed (%s)\n' "$isolate"

# Prove the isolation is real before trusting a result that depends on it. A sandbox that
# silently allows the network would make every assertion below meaningless — and green.
if run_isolated curl -sS --max-time 5 -o /dev/null https://api.github.com/ 2>/dev/null; then
  printf 'FAIL  the isolation does not actually block the network; results would be meaningless.\n' >&2
  exit 1
fi
printf 'PASS  isolation confirmed: a control request fails inside it\n'

assert_isolated_exit() {
  local want=$1 fixture=$2 label=$3
  run_isolated bash "$guard" "$fixture" >/dev/null 2>&1
  local got=$?
  if [ "$got" -ne "$want" ]; then
    printf 'FAIL  %s: expected exit %s with no network, got %s\n' "$label" "$want" "$got" >&2
    failed=1
  else
    printf 'PASS  %-34s exit %s\n' "$label" "$got"
  fi
}

empty=$(mktemp); trap 'rm -f "$empty"' EXIT

assert_isolated_exit 1 "${fixtures}/plan-with-nat.json"        'denied create'
assert_isolated_exit 1 "${fixtures}/plan-with-gcp-nat.json"    'denied create (the new type)'
assert_isolated_exit 1 "${fixtures}/plan-events-with-nat.jsonl" 'denied create (events)'
assert_isolated_exit 0 "${fixtures}/plan-clean.json"           'clean plan'
assert_isolated_exit 2 "${fixtures}/plan-errored.jsonl"        'errored plan'
assert_isolated_exit 2 "${fixtures}/plan-unrecognizable.txt"   'unrecognizable input'
assert_isolated_exit 2 "$empty"                                'empty input'

if [ "$failed" -ne 0 ]; then
  printf '\nThe guard verdict is not network-independent.\n' >&2
  exit 1
fi

printf '\nThe verdict is the same with the network gone. Freshness is a separate signal.\n'
