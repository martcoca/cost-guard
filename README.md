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
