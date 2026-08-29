# Packets

Work in this repository is defined by packets. A packet states a Goal, a Boundary, a
Check, and enough context to execute without reading another repository.

## Working order

| # | Packet | Status | Is |
|---|---|---|---|
| 1 | [`0010-E01-T01.md`](0010-E01-T01.md) | done | Move the guard and the denylist here, and give them an interface another repository's CI can consume without copying either file |
| 2 | [`0010-E01-T05.md`](0010-E01-T05.md) | done | One denylist change, demonstrably enforced by all three clouds. The initiative's actual claim, currently untested |
| 3 | [`0010-E02-T01.md`](0010-E02-T01.md) | done | Report an out-of-date pin, without giving the guard's verdict a network dependency |
| 3 | [`0010-E02-T02.md`](0010-E02-T02.md) | not started | The guard hangs on a 47 KB plan. Fix it, and give the suite a size test that would have caught it |

Take the packet the Founder names. Otherwise take the next one in this table whose
`Status:` is not `done`. The table is the order; the numbers are only identity.

T02, T03 and T04 are the three consumer cutovers and live in the platform repositories,
not here. T05 below is the one that tests this initiative's actual claim.

## Rules

- **One packet in flight at a time.** Never widen a packet to absorb the next, and never
  open one pull request covering two.
- **Never edit a packet body.** It is the record of what was asked. If it asks for the
  wrong thing, say so and stop. If a *step* is impossible as written but its intent is
  clear, do the nearest thing that satisfies the intent and say what you changed — stopping
  is for authority, not for difficulty.
- **You may set `Status:`** and nothing else in the file.
- **Run the Check yourself** before opening a pull request. Opening one asserts you ran it
  and it passed.
- **Write `evidence/<packet-id>.md`** and commit it in the same pull request: the Check
  output, what you verified, what you could not, and any decision the packet left to you.
- **If you are blocked, open an issue labelled `blocked`** naming the packet and what you
  need. A blocker mentioned only in conversation does not survive the conversation.
- **Branch, commit, open a pull request.** Never commit to `main`, never merge your own
  work.
- **Stop at anything irreversible or cost-incurring** — cloud apply, provisioning,
  deletion, publishing, spend — and tell the Founder. You hold no such authority.

## Running packets in sequence

After you open a pull request, **stop**. Do not start the next packet. Wait for the checks
to pass, then `git checkout main && git pull` and branch fresh. Resyncing is mandatory:
`main` may have moved, including corrections to your own merged work.

## If no packet applies

Stop and ask. Do not infer work from the repository: the absence of a packet is
information, not an invitation.

## Where these come from

Each packet is copied from the initiative tree in the doctrine repository, which holds the
intent it was derived from. The `Source:` line names the original. That original is the
canonical record; this copy is deliberately frozen so scope cannot move under a session
mid-flight.
