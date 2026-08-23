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

## Testing

| Command | Asserts |
|---|---|
| `scripts/test-cost-guard.sh` | the exit contract across six inputs |
| `scripts/test-suite-can-fail.sh` | that the suite above can actually go red |
| `scripts/demo-consumer.sh` | the action working from a repository holding neither file |

All three run in CI on every push. `demo-consumer.sh` builds a throwaway consumer
repository and runs the action's real entrypoint against plans that repository wrote
itself; the `manifest` job covers the half a shell script cannot, where the runner resolves
`uses:` and binds the inputs and outputs for real.

## Layout

`scripts/cost-guard.sh` resolves its denylist as `../config/cost-guard-denylist.json`
relative to itself, and the script is byte-identical to the platform copies, so the
denylist's location is fixed at `config/cost-guard-denylist.json`. The
`cost-guard-denylist.json` at the repository root is a symlink to it — one file, reachable
by the root-relative path as well.
