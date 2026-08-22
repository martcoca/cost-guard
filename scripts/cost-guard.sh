#!/usr/bin/env bash
# Reject resource creations that are outside the foundation's zero-cost palette.

set -euo pipefail

if [[ $# -ne 1 ]]; then
  printf 'Usage: %s <opentofu-plan.json>\n' "$0" >&2
  exit 2
fi

plan_file=$1
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
denylist_file="${script_dir}/../config/cost-guard-denylist.json"

if [[ "$plan_file" != "/dev/stdin" && "$plan_file" != "-" && ! -f "$plan_file" ]]; then
  printf 'Plan file not found: %s\n' "$plan_file" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  printf 'cost-guard requires jq to read OpenTofu plan JSON.\n' >&2
  exit 2
fi

# Fail closed on anything that is not a readable plan.
#
# Without this the guard is trivially bypassed: a failing `tofu plan` piped into it emits
# error events, no denied resource is found, and the guard exits 0 — so a pipeline without
# `pipefail` reports success for a plan that never ran. "No denied resources" and "no plan"
# must not produce the same verdict.
plan_input=$(cat -- "$plan_file")

if [[ -z "${plan_input//[[:space:]]/}" ]]; then
  printf 'cost-guard: empty input; refusing to report a plan as clean.\n' >&2
  exit 2
fi

if printf '%s' "$plan_input" | jq -e -s 'any(.[]; .["@level"] == "error")' >/dev/null 2>&1; then
  printf 'cost-guard: the plan reported errors; refusing to report it as clean.\n' >&2
  printf '%s' "$plan_input" | jq -r -s '.[] | select(.["@level"] == "error") | .["@message"]' 2>/dev/null | head -3 >&2
  exit 2
fi

if ! printf '%s' "$plan_input" | jq -e -s '
      any(.[]; has("resource_changes") or .type == "planned_change" or .type == "change_summary")
    ' >/dev/null 2>&1; then
  printf 'cost-guard: input is not recognizable OpenTofu plan output; refusing to pass it.\n' >&2
  exit 2
fi

# `tofu show -json` emits one document with a resource_changes array, while
# `tofu plan -json` emits a stream of planned_change event objects. Normalize both
# shapes. A replacement is still a creation and must be denied.
denied=$(printf '%s' "$plan_input" | jq -r --slurpfile denylist "$denylist_file" '
  def candidates:
    if .type == "planned_change" then
      .change as $change
      | {
          address: ($change.resource.addr // $change.resource.resource_type),
          resource_type: $change.resource.resource_type,
          creates: (
            ["create", "replace", "delete_then_create", "create_then_delete"]
            | index($change.action) != null
          )
        }
    else
      .resource_changes[]?
      | {
          address: (.address // .type),
          resource_type: .type,
          creates: ((.change.actions // []) | index("create") != null)
        }
    end;

  ($denylist[0] | INDEX(.resource_type)) as $denied_types
  | candidates
  | select(.creates)
  | select($denied_types[.resource_type] != null)
  | "Denied resource: \(.address) (\($denied_types[.resource_type].resource)): \($denied_types[.resource_type].monthly_cost)"
')

if [[ -n "$denied" ]]; then
  printf '%s\n' "$denied" >&2
  exit 1
fi
