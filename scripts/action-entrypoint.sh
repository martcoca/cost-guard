#!/usr/bin/env bash
# The body of the composite action, kept as a file rather than inline YAML.
#
# Two reasons it is not written directly into action.yml:
#
# 1. `bash -n` in CI parses every script under scripts/. A step body embedded in YAML is
#    never parsed until a consumer runs it, which is the worst possible moment.
# 2. A demonstration that re-implements the step body proves nothing about the step body.
#    scripts/demo-consumer.sh executes *this* file under the same environment contract the
#    Actions runner provides, so what is demonstrated is what consumers get.
#
# Environment contract, all supplied by the runner:
#   INPUT_PLAN           path to the plan file (the action's `plan` input)
#   GITHUB_ACTION_PATH   where the runner checked this repository out
#   GITHUB_OUTPUT        step outputs file            (optional)
#   GITHUB_STEP_SUMMARY  job summary file             (optional)

set -uo pipefail

action_path="${GITHUB_ACTION_PATH:?GITHUB_ACTION_PATH is not set}"
plan="${INPUT_PLAN:?the plan input is required}"

guard="${action_path}/scripts/cost-guard.sh"
if [[ ! -f "$guard" ]]; then
  printf 'cost-guard: the action checkout has no guard at %s\n' "$guard" >&2
  exit 2
fi

# Read the exit code from the guard itself, never from a pipeline. `guard | tee` reports
# tee's status, and a guard whose verdict is laundered through another process is not a
# guard. Output is captured to files and replayed instead.
out=$(mktemp); err=$(mktemp)
trap 'rm -f "$out" "$err"' EXIT

bash "$guard" "$plan"  >"$out" 2>"$err"
status=$?

cat "$out"
cat "$err" >&2

case "$status" in
  0) verdict=allow ;;
  1) verdict=deny ;;
  2) verdict=undecidable ;;
  *) verdict=undecidable ;;
esac

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'verdict=%s\n'   "$verdict" >> "$GITHUB_OUTPUT"
  printf 'exit-code=%s\n' "$status"  >> "$GITHUB_OUTPUT"
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    printf '### Cost guard: %s\n\n' "$verdict"
    case "$verdict" in
      allow)       printf 'The plan creates nothing on the denylist.\n' ;;
      deny)        printf 'The plan creates a denied resource type:\n\n```\n%s\n```\n' "$(cat "$err")" ;;
      undecidable) printf 'The guard could not reach a verdict, so it failed closed:\n\n```\n%s\n```\n' "$(cat "$err")" ;;
    esac
  } >> "$GITHUB_STEP_SUMMARY"
fi

# The step fails for both 1 and 2. An undecidable verdict must not be softer than a
# denial: that is the whole fail-closed contract, and a wrapper that swallowed exit 2
# would undo it while still looking like it ran the guard.
exit "$status"
