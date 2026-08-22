# Packets

Work in this repository is defined by packets. A packet states a Goal, a Boundary, a
Check, and enough context to execute without reading another repository.

## Working order

| # | Packet | Status | Is |
|---|---|---|---|
| 1 | [`0010-E01-T01.md`](0010-E01-T01.md) | not started | Move the guard and the denylist here, and give them an interface another repository's CI can consume without copying either file |

Take the packet the Founder names. Otherwise take the next one in this table whose
`Status:` is not `done`. The table is the order; the numbers are only identity.

T02 — making the three platform repositories consume this instead of their own copies —
is deliberately unwritten. Its shape depends on the interface T01 chooses, and writing it
now would put a guess into a packet.

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
