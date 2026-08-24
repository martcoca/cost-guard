#!/usr/bin/env bash
# Report whether a consumer's pin is behind the current cost-guard release.
#
# This is deliberately NOT part of the guard. The guard reads a plan file and exits 0, 1
# or 2 with no network, no credentials and no service, and that property is worth more
# than any convenience of putting both in one step. A denied resource is denied whether or
# not GitHub is reachable.
#
# So this script may fail, be rate-limited, or be run offline, and none of that is allowed
# to change a verdict — it does not compute one. Its own failure mode is `unknown`, which
# is reported as `unknown` and never as `current`. "We could not ask" and "you are up to
# date" are different facts, and collapsing them is the exact defect this exists to remove.
#
# Environment contract, runner-supplied:
#   INPUT_PIN            what the consumer pins: "owner/repo@ref" or just "ref"
#   INPUT_REPOSITORY     repository to check when INPUT_PIN carries no owner/repo
#   INPUT_FAIL_ON_STALE  "true" to fail the step when behind (default false)
#   GITHUB_OUTPUT        step outputs file             (optional)
#   GITHUB_STEP_SUMMARY  job summary file              (optional)
#   GH_TOKEN             token for `gh api`            (optional; public repos work without)

set -uo pipefail

pin="${INPUT_PIN:-}"
default_repo="${INPUT_REPOSITORY:-}"
fail_on_stale="${INPUT_FAIL_ON_STALE:-false}"

# A missing pin is a configuration error, not uncertain freshness. It is deterministic and
# fixable, so it fails loudly rather than being laundered into `unknown`.
if [[ -z "${pin//[[:space:]]/}" ]]; then
  printf 'cost-guard freshness: no pin given. Pass the ref this repository pins.\n' >&2
  exit 2
fi

if [[ "$pin" == *"@"* ]]; then
  repo="${pin%@*}"
  ref="${pin##*@}"
else
  repo="$default_repo"
  ref="$pin"
fi

if [[ -z "${repo//[[:space:]]/}" || -z "${ref//[[:space:]]/}" ]]; then
  printf 'cost-guard freshness: cannot read a repository and a ref out of pin "%s".\n' "$pin" >&2
  exit 2
fi

if ! command -v gh >/dev/null 2>&1; then
  # Not an error: an absent CLI is one more way of not being able to ask.
  status=unknown
  detail='the gh CLI is not available, so the current release could not be looked up'
  latest_tag=''; latest_commit=''; pinned_commit=''
else
  # Resolve a ref to a commit. One call covers annotated tags, moving tags, branches and
  # raw SHAs, which is what makes the comparison below a comparison of *versions* rather
  # than of strings.
  resolve() { gh api "repos/${repo}/commits/${1}" --jq '.sha' 2>/dev/null; }

  latest_tag=$(gh api "repos/${repo}/releases/latest" --jq '.tag_name' 2>/dev/null)
  latest_commit=''
  [[ -n "$latest_tag" ]] && latest_commit=$(resolve "$latest_tag")
  pinned_commit=$(resolve "$ref")

  if [[ -z "$latest_tag" || -z "$latest_commit" ]]; then
    status=unknown
    detail='the current release could not be determined'
  elif [[ -z "$pinned_commit" ]]; then
    status=unknown
    detail="the pinned ref ${ref} could not be resolved in ${repo}"
  elif [[ "$pinned_commit" == "$latest_commit" ]]; then
    status=current
    # A moving tag that has been moved lands here, which is the point: @v1 and @v1.0.1 can
    # be different strings and the same version. T05 traced a consumer being wrongly called
    # behind for exactly this reason.
    if [[ "$ref" != "$latest_tag" ]]; then
      detail="${ref} and ${latest_tag} are the same commit (${latest_commit:0:7})"
    else
      detail="pinned to the current release ${latest_tag}"
    fi
  else
    status=behind
    detail="pinned to ${ref} (${pinned_commit:0:7}); the current release is ${latest_tag} (${latest_commit:0:7})"
  fi
fi

printf 'cost-guard freshness: %s — %s\n' "$status" "$detail"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    printf 'status=%s\n'         "$status"
    printf 'pinned-ref=%s\n'     "$ref"
    printf 'pinned-commit=%s\n'  "$pinned_commit"
    printf 'latest-release=%s\n' "$latest_tag"
    printf 'latest-commit=%s\n'  "$latest_commit"
    printf 'detail=%s\n'         "$detail"
  } >> "$GITHUB_OUTPUT"
fi

case "$status" in
  behind)  printf '::warning title=cost-guard is out of date::%s\n' "$detail" ;;
  unknown) printf '::warning title=cost-guard freshness unknown::%s\n' "$detail" ;;
  current) printf '::notice title=cost-guard is current::%s\n' "$detail" ;;
esac

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    printf '### Cost guard pin: %s\n\n%s\n' "$status" "$detail"
    [[ "$status" == behind ]] && \
      printf '\nA denial added after `%s` is **not in force here**. Bump the pin.\n' "$ref"
    [[ "$status" == unknown ]] && \
      printf '\nThis is not a claim that the pin is current. It is a claim that nobody asked.\n'
  } >> "$GITHUB_STEP_SUMMARY"
fi

# `unknown` never fails the step, even under fail-on-stale. Failing on a lookup that did
# not happen is precisely the network dependency this design exists to avoid: it would
# make a consumer's CI depend on an API call its plan does not need.
if [[ "$fail_on_stale" == "true" && "$status" == "behind" ]]; then
  printf 'cost-guard freshness: failing the step because fail-on-stale is set.\n' >&2
  exit 1
fi

exit 0
