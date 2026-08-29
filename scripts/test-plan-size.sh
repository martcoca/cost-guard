#!/usr/bin/env bash
# Assert the guard still works when the plan is the size a real plan is.
#
# Every other negative case in this suite is about *content* — a denied type, an errored
# plan, unparsable input, no input. None was about *size*, and that gap let a released
# guard hang for minutes on a 47 KB plan while passing every test it had. The inputs of a
# guard grow with the infrastructure it guards; its suite has to grow with them too.
#
# Two halves, because either alone is weak:
#
#   1. Dynamic: a real plan of realistic size gets the right verdict inside a time budget.
#      Catches slowness whatever its cause, including causes nobody has thought of.
#   2. Static: the specific shape that caused it — rewriting the whole plan string in bash
#      — cannot come back. Deterministic, so it cannot flake, and it names the defect.
#
# The fixtures are real `tofu show -json` output from a stack of distinct resources, not a
# string repeated to length. A pathological input built by repetition would not resemble
# what actually found this.

set -uo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root_dir=$(cd -- "${script_dir}/.." && pwd)
guard="${root_dir}/scripts/cost-guard.sh"
fixtures="${root_dir}/tests/fixtures"

# Generous on purpose. The fixed implementation takes hundredths of a second, so anything
# approaching this ceiling is a regression rather than a slow runner. The packet's
# requirement is five seconds.
BUDGET_SECONDS=5
MIN_BYTES=50000

failed=0

# --- 1. dynamic ----------------------------------------------------------------------
printf 'Dynamic: a realistically-sized plan, verdict and time\n'

timed_verdict() {
  # timed_verdict <fixture> <expected-exit> <label>
  local fixture=$1 want=$2 label=$3
  local path="${fixtures}/${fixture}"

  if [ ! -f "$path" ]; then
    printf 'FAIL  %s: missing fixture %s\n' "$label" "$fixture" >&2
    failed=1; return
  fi

  # A size assertion, not decoration. Without it this whole file can be defanged by
  # swapping in a small fixture: every assertion below would still pass and the suite
  # would go back to proving nothing about size.
  local bytes; bytes=$(wc -c < "$path" | tr -d ' ')
  if [ "$bytes" -lt "$MIN_BYTES" ]; then
    printf 'FAIL  %s: fixture is %s bytes, below the %s-byte floor this test exists for.\n' \
      "$label" "$bytes" "$MIN_BYTES" >&2
    failed=1; return
  fi

  local start end elapsed got
  start=$(date +%s)
  timeout "$BUDGET_SECONDS" bash "$guard" "$path" >/dev/null 2>&1
  got=$?
  end=$(date +%s)
  elapsed=$((end - start))

  if [ "$got" -eq 124 ]; then
    printf 'FAIL  %s: no verdict within %ss on a %s-byte plan.\n' "$label" "$BUDGET_SECONDS" "$bytes" >&2
    printf '      A guard that cannot finish is a guarded pipeline that hangs.\n' >&2
    failed=1
  elif [ "$got" -ne "$want" ]; then
    printf 'FAIL  %s: expected exit %s on a %s-byte plan, got %s\n' "$label" "$want" "$bytes" "$got" >&2
    failed=1
  else
    printf 'PASS  %-34s %s bytes  exit %s  under %ss\n' "$label" "$bytes" "$got" "$BUDGET_SECONDS"
  fi
}

# Correct verdicts at size, not merely a fast one. The denied entry sits in the middle of
# the denied fixture, so finding it means reading the whole plan rather than the first
# resource.
timed_verdict plan-large-clean.json  0 'a large clean plan'
timed_verdict plan-large-denied.json 1 'a large denied plan'

# --- 2. static -----------------------------------------------------------------------
printf '\nStatic: the whole-input string rewrite cannot return\n'

# Comments are stripped first. The guard now carries an explanation of this defect that
# quotes the offending expression verbatim, and a check that matched its own documentation
# would fail for the wrong reason — and would push whoever hit it into deleting the
# explanation rather than the defect.
stripped=$(sed 's/#.*//' "$guard")
hits=$(printf '%s\n' "$stripped" | grep -nE '\$\{plan_input//' || true)
if [ -n "$hits" ]; then
  printf 'FAIL  the guard rewrites the whole plan string in bash:\n%s\n' "$hits" >&2
  printf '      This is the shape that hung a released guard for minutes. Test for the\n' >&2
  printf '      presence of a character instead of deleting every other one.\n' >&2
  failed=1
else
  printf 'PASS  no ${plan_input//...} rewrite in the guard\n'
fi

if [ "$failed" -ne 0 ]; then
  printf '\nThe guard does not survive a realistically-sized plan.\n' >&2
  exit 1
fi

printf '\nThe guard reaches a correct verdict on a real plan, at size, well inside budget.\n'
