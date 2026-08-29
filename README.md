# cost-guard

One OpenTofu cost guard, shared by every cloud platform repository in this portfolio.

## What it does

It reads OpenTofu plan output and **fails when the plan would create a resource type on the
denylist** — the types that cost money whether or not anybody uses them. It understands both
`tofu show -json`, which emits a single document with a `resource_changes` array, and
`tofu plan -json`, which emits a stream of `planned_change` events.

## It fails closed, and that is the whole design

Empty input, an errored plan, and unrecognizable input all exit **2**. They do not pass.

"No denied resources" and "no plan" must never produce the same verdict. A guard that exits
`0` because it could not find anything to check is not a guard — it is a green light with
no one looking, and it will be trusted precisely when it should not be.

| Exit | Meaning |
|---|---|
| `0` | The plan creates nothing on the denylist |
| `1` | The plan creates a denied resource type |
| `2` | The guard could not reach a verdict — empty, errored, or unparsable input |

**Do not "simplify" the exit-2 paths.** They are the reason this is worth having.

## Why this repository exists

The guard and its denylist previously existed as byte-identical copies in three platform
repositories, and keeping them identical had already meant hand-merging the same change
twice. That is observed duplication rather than anticipated duplication, which is the only
thing that admits a shared component here.

It is a `core` component: consumed as a build-time contract, never as a runtime dependency.
Nothing calls this at deploy time.

## How another repository consumes it

As a **composite action**. The guard and the denylist travel with the action, so a
consuming repository holds neither file:

```yaml
- uses: actions/checkout@v4

- run: tofu plan -input=false -no-color -json > plan.json

- uses: martcoca/cost-guard@v1
  with:
    plan: plan.json
```

`plan` accepts either shape of plan output: `tofu show -json` or `tofu plan -json`.
The step fails on exit `1` and on exit `2`. It also exposes what it decided, for a
workflow that wants to report rather than only stop:

| Output | Values |
|---|---|
| `verdict` | `allow`, `deny`, `undecidable` |
| `exit-code` | `0`, `1`, `2` — the guard's exact exit code |

**Redirect the plan to a file; do not pipe it in.** `tofu plan -json | guard` reports the
exit status of the last process in the pipeline, and a pipeline without `pipefail` will
report success for a plan that never ran.

### Why a composite action, and not the other two

A **reusable workflow** (`workflow_call`) is the wrong shape, and the reason is structural
rather than stylistic. A reusable workflow arrives as its own job on its own runner, but
the guard has to run *inside* the consumer's plan job — the one that already holds the
cloud OIDC token, the initialized working directory, and the plan that only exists there.
Splitting it out means shipping plan JSON between jobs as an artifact, or moving `tofu
init` and the cloud login into this repository, which would make a cloud-neutral guard
carry three clouds' authentication. A composite action runs as a step in the job that
already has all of it.

A **digest-verified fetch of a tagged release** was the closest call, and it has one real
advantage: it works outside GitHub Actions, which a composite action does not. It was
rejected because it reintroduces the problem this repository exists to solve. The consumer
ends up with the guard and the denylist on disk, plus a pinned digest that must be updated
by hand in three repositories every time the denylist changes — which is the same hand-
merge that made this extraction necessary, moved from the file to the pin. If a consumer
ever needs to run the guard outside Actions, `scripts/cost-guard.sh` is a plain script with
no dependency beyond `jq`, and that path can be added without disturbing this one.

The cost of the composite action is that it is GitHub-specific, and that the interface's
behavior lives in `scripts/action-entrypoint.sh` rather than in the guard — so the wrapper
is a place the fail-closed contract could be lost without `cost-guard.sh` changing at all.
`.github/workflows/cost-guard.yml` asserts through the action, not only against the guard,
for exactly that reason.

## Knowing whether your pin is current

The guard tells you whether a plan is allowed. It cannot tell you whether it is *the
current guard* — a consumer pinned to an old release enforces the denylist that release
froze, exits `0`, and looks exactly like a consumer that is up to date with nothing to
deny. That is how a denial added here can be absent in a consumer with nobody noticing,
which is what happened in T05.

A **second action** reports it:

```yaml
- uses: martcoca/cost-guard@v1.0.1
  with:
    plan: plan.json

- uses: martcoca/cost-guard/freshness@v1.0.1
  if: always()
  with:
    pin: martcoca/cost-guard@v1.0.1
```

| Output | Values |
|---|---|
| `status` | `current`, `behind`, `unknown` |
| `pinned-ref` / `pinned-commit` | what this repository pins, and what it resolves to |
| `latest-release` / `latest-commit` | the current release, and what it resolves to |
| `detail` | one line explaining the status |

It writes a warning annotation and a job summary. It exits `0` by default; set
`fail-on-stale: 'true'` to fail the step when the pin is behind.

### Three rules, and each is load-bearing

**The guard's verdict never depends on the network.** That is why freshness is a separate
action rather than another output of the guard. A denied resource is denied whether or not
GitHub is reachable, and a consumer reading the guard step's outcome must never have to
wonder whether the failure was a denial or a failed lookup. `scripts/test-no-network.sh`
holds this down from both sides: it greps the guard for network primitives, *and* runs the
exit contract with the network genuinely removed — and fails rather than skipping if the
host offers no isolation to remove it with.

**Unknown is reported as unknown, never as current.** If the release cannot be looked up,
`status` is `unknown` and says so. "We could not ask" and "you are up to date" are
different facts, and collapsing them recreates the silence this exists to remove.

**`unknown` never fails the step, even with `fail-on-stale: 'true'`.** Failing because a
lookup did not happen is exactly the network dependency this design keeps out of consumers'
CI — it would make every pipeline depend on an API call its plan does not need.

### It compares versions, not strings

`@v1` and `@v1.0.1` are different strings and, once the moving tag has moved, the same
version. A string comparison reports a consumer on `@v1` as behind forever. Both refs are
therefore resolved to commits and the **commits** are compared, so `@v1`, `@v1.0.1` and a
raw SHA of the same commit all read as `current`. T05 traced this exact confusion.

### What this does not do

It does not bump anything. A consumer told it is behind is still behind until someone opens
a pull request there, and that window is unbounded — nothing here shortens it, it only stops
it being invisible. `docs/dependabot-for-consumers.yml` is the start of an answer, with two
demonstrated reasons it does not work on these consumers yet.

## Testing

| Command | Asserts |
|---|---|
| `scripts/test-cost-guard.sh` | the exit contract across six inputs |
| `scripts/test-suite-can-fail.sh` | that the suite above can actually go red |
| `scripts/demo-consumer.sh` | the action working from a repository holding neither file |
| `scripts/test-plan-size.sh` | a real ≥50 KB plan gets the right verdict inside a time budget |
| `scripts/test-freshness.sh` | every freshness rule, against a stubbed API |
| `scripts/test-no-network.sh` | the exit contract with the network actually removed |
| `scripts/probe-propagation.sh` | whether a given pin enforces a given plan |

All three run in CI on every push. `demo-consumer.sh` builds a throwaway consumer
repository and runs the action's real entrypoint against plans that repository wrote
itself; the `manifest` job covers the half a shell script cannot, where the runner resolves
`uses:` and binds the inputs and outputs for real.

## The guard has to survive a real plan

The fixtures a guard is written against are small. The plans it runs against are not, and
they grow with the infrastructure being guarded. `v1.0.1` and earlier tested emptiness by
deleting every whitespace character from the plan and asking whether anything remained —
correct, and catastrophically slow, because bash rebuilds the whole string to do it:

| Plan size | Deleting the whitespace | Looking for one non-whitespace character |
|---|---|---|
| 5.9 KB | 1.2 s | 0.002 s |
| 11.8 KB | 7.0 s | 0.002 s |
| 23.5 KB | 45 s | 0.002 s |
| 51 KB (real `tofu show -json`) | 391 s | 0.12 s |

It did not fail, and it did not hang forever either — it eventually returns the *correct*
verdict, six and a half minutes later. That is worse than a crash, not better: a guarded
plan job sits at no output for long enough to look like a stalled runner, gets killed by a
job timeout or an impatient operator, and bills for the wait. Every test passed throughout,
because **every negative case was about content and none was about size.**

`tests/fixtures/plan-large-*.json` are real `tofu show -json` output from a stack of
distinct resources — not one string repeated to length, which would be a different input
shape than the one that found this. `scripts/test-plan-size.sh` asserts a correct verdict
inside a time budget *and* that the string-rewriting shape cannot return, and it asserts
the fixtures are still large, so it cannot be defanged by quietly swapping in a small one.

**If you write a check over the whole plan, do not rewrite the string.** Test for the
presence of what you are looking for, or hand the work to `jq`, which streams.

## Layout

`scripts/cost-guard.sh` resolves its denylist as `../config/cost-guard-denylist.json`
relative to itself, and the script is byte-identical to the platform copies, so the
denylist's location is fixed at `config/cost-guard-denylist.json`. The
`cost-guard-denylist.json` at the repository root is a symlink to it — one file, reachable
by the root-relative path as well.
