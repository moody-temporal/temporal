
We have a component with some very tricky logic, that we've found some tricky
bugs in before. I would like to increase my confidence in the component by
writing a FizzBee model for it and checking various properties (primarily
liveness).

FizzBee is a relatively new formal modeling and verification tool that I don't
know that much about and you probably don't either. Please read all the docs on
https://fizzbee.io/ to familiarize yourself with it! I've installed the `fizz`
cli on the PATH and also installed their bundled skills.

Full disclosure: I've given versions of this prompt for TLA+ and for P before.
You may see traces of that in git history or memories (though I tried to disable
memories). Give it a fair shot without specific reference to those sessions.

The code is in `./service/matching/fair_task_{reader,writer}.go` from the base
of this repo, and related files. It implements a fair queue processor on top of
a database. More details are available in `fairness.md` in that directory as
well.

The basic ideas that I think the model should include are:

- The system works on top of a database. The database should be modeled as
  a concurrent process connected over the network.
  - Database calls may succeed.
  - Database calls may time out, either on the outgoing side (the operation was
    not performed) or the incoming side (the operation was performed). In both
    cases the queue logic is not aware of the success of the operation.
  - In this model, we don't need to include database calls that explicitly fail.
- Tasks are written by the task writer (another concurrent process). Note the
  "pinning ack level" logic in the code that does synchronize the writer and
   reader to some degree.
- The primary key includes a `<pass, id>` pair to have the database sort tasks
  for us in a fair order based on a stride scheduling algorithm, but I think the
  model can use a single integer level dimension for simplicity.
- Tasks are read by the task reader (another concurrent process).
- The task reader attempts to maintain a bounded head of the queue in memory at
  all times.
- Tasks that are either read or written successfully are merged into the head
  according to the logic in mergeTasksLocked.
- A task in memory may be "acked", marking it complete. The "acker" should be
  considered another concurrent process, that will eventually ack all the tasks
  loaded in memory.
- The ack level may move up to the lowest unacked task.
- Tasks below the ack level may be GCed (deleted). This should be modeled as
  another current process.
- The "evicted ack cache" (in a later milestone).
- Pay attention to the logic that retries failed reads after a timeout. There
  was a bug there that I think should be caught by a detailed-enough model
  (commit 26d9a561).
- Pay attention to the comment about not resetting the read level after a
  merge-after-write results in zero loaded tasks. There was a bug there that I
  think should be caught by a model (commit f534e74e).
- Pay attention to expired tasks. There was a bug there too (commit 0b372d5e).
- Older commits worth looking at to see what kind of bugs we're trying to catch:
  - ad717eae: tricky race that involves matcher, maybe outside the scope of what
    we can do with a single model
  - 8ca7b640: five(!) early bugs fixed (before production thankfully)
  - 12e7c43a: another early bug, fixed writer pinning+merge logic
  (hint: try mutation testing to check that the model would actually find the
  bug)

Details in the code to explicitly **not** include:

- Database calls that explicitly fail: this would primarily be due to
  "conflict", i.e. task queue partition ownership loss. We'll create a separate
  model for the ownership/write fencing protocol if necessary.
- Subqueues: assume only one writer and one reader.

For other questions about which details of the code should be reflected in the
model or ignored, please ask.

Properties to check:

- If a task is confirmed written it will eventually be acked. That implies these
  properties, which could be worth checking separately:
  - The reader never gets "stuck" (in a state where there are tasks in the
    database but the reader will never read them).
  - We never GC a task before acking it (this would be even worse.. a restart
    could fix the previous situation but not this).

In general I don't want the model to verify anything about "fairness" in our
application-defined sense, even though that's the purpose of the system. We're
looking for correctness and liveness properties here.

It may be too complicated to build the full desired model in one shot. First,
please list a series of milestones of increasing model complexity. After that
we'll implement them one by one.

Milestones:

> Status: M1-M5 implemented (`m1.fizz`..`m5.fizz`), mutation suite in
> `mutations/` (run with `mutations/run.sh`), notes and results in
> `README.md`. M2 originally asserted the "fair reader stuck" softassert
> state unreachable; M3 (expiry) proved it reachable and that the code's
> defensive backstop read is load-bearing on that path — models now include
> the backstop, matching the code. M6 is folded into per-milestone mutation
> files plus README documentation; M7 (restart) not started.
>
> Review decisions (post-M5): the GC process is no longer modeled — GC only
> deletes at-or-below an observed ack level, so AckLevelOnlyPassesAcked
> subsumes "never GC an unacked task" (the M1/M4 GC bullets below are
> superseded). Likewise the writer reuses levels of traceless failed writes
> instead of tracking `used_levels`. Both cut the state space dramatically
> (m1: 6x). m2-m5 re-runs + the mutation suite are queued for a bigger
> machine; run everything through `check.sh` (32G memory cap, one at a
> time).
>
> MBT (post-review): `mbt/queue_mbt.fizz` + a Go adapter in
> `service/matching/fizz_mbt_*_test.go` run generated traces against the
> REAL fairTaskReader/fairTaskWriter with full-state comparison after every
> action; 2000 traces in ~25s, green. Reverting 0b372d5e in the real code
> is caught by a 20k-trace budget. Details + caveats in README.md.

## Modeling conventions (all milestones)

- Levels are single small integers (no <pass, id> pair). The DB sorts by level.
  Task identity == level (two tasks never share a level).
- The DB is a role holding a sorted set of tasks plus the persisted ack level.
  Reader/writer/GC talk to it via explicit request/response steps so that
  timeouts on either side can be interleaved with other actions.
- Reader state mirrors the code directly so mutations map 1:1 onto real bugs:
  `outstandingTasks` (level -> LOADED | ACKED), `loadedTasks`, `readLevel`,
  `ackLevel`, `atEnd`, `readPending`, `backoffTimer`, `newlyWrittenTasks`,
  `ackLevelPinnedByWriter`, and later `evictedAcks`.
- A read is **not atomic**: "issue read at readLevel" and "merge response" are
  separate steps with `readPending` true in between, because several real bugs
  (12e7c43a, f534e74e, 26d9a561) live exactly in that window.
- The acker is a separate action: nondeterministically ack any LOADED task
  (weakly fair, so every loaded task is eventually acked). The matcher itself
  is not modeled (see Out of scope).
- Small constants to bound state: ~3-5 total tasks ever written,
  batch size 2, reload-at threshold 1. Tune per milestone.
- Ghost/history variables: `confirmedWritten` (tasks whose write response
  reached the writer) and `everAcked`, used only by assertions.

Core properties (introduced in M1, carried through every later milestone):

- **Safety / NoLostTasks**: a task deleted from the DB (GC) or skipped by the
  ack level was acked first. Equivalently: ackLevel never moves past a task
  that is in the DB (or confirmed written) but was never acked.
- **Safety / structural invariants** (cheap, catch modeling and logic errors
  early): ackLevel <= readLevel ordering, ackLevel monotonic per owner,
  loadedTasks == count of LOADED entries, everything in memory is in
  (ackLevel, readLevel], no LOADED task at or below ackLevel.
- **Liveness / EventuallyAcked**: every confirmed-written task is eventually
  acked (`always eventually` / `eventually always` on "all confirmed tasks
  acked"), given fairness assumptions on reader/acker/DB actions.
- **Liveness / NeverStuck**: implied by EventuallyAcked, but also checked
  directly as "if the DB has a task above ackLevel, eventually a read is
  issued or the task is loaded" — this gives shorter counterexample traces
  than the end-to-end property.

## M1 — Sequential core: reader + acker + GC over a reliable DB

Pre-populate the DB with N tasks (no writer yet; `confirmedWritten` = initial
set). Reliable DB: every call succeeds, responses always arrive.

Model: read batches at readLevel with bounded buffer (a simplified
mergeTasksLocked: only mergeReadMiddle / mergeReadToEnd paths, no eviction
since nothing is ever inserted below readLevel), atEnd tracking, ack level
advance over ACKED prefix, GC deleting DB tasks <= ackLevel (as its own
concurrent process).

Check: all core properties above. Also `exists` assertions as sanity checks
that interesting states are reachable (buffer full, GC actually ran, atEnd
true). Goal of this milestone is mostly to validate FizzBee conventions and
get the state space and fairness annotations right.

## M2 — Concurrent writer: pinning, mergeWrite, eviction (still reliable DB)

Add the writer as a concurrent process: pick a batch of new levels (above the
pinned ack level; nondeterministically below or above readLevel), pin ack
level, write to DB, merge into the reader (mergeWrite mode), unpin.

This milestone brings in the full mergeTasksLocked logic from the code:

- pin/unpin and advanceAckLevelLocked gating (fairness.md "Problems" section:
  ack level must not move past an in-flight write; GC racing with a write).
- newlyWrittenTasks buffering when a write's merge arrives while readPending
  (bug 12e7c43a), including the "pinned until newlyWrittenTasks processed"
  rule in ackLevelPinnedLocked.
- bypass/merge: drop written tasks above readLevel when !atEnd; keep first
  batchSize by level; eviction of LOADED tasks and of ACKED entries above the
  new readLevel (bugs 1-4 of 8ca7b640). Evicted acks are simply forgotten in
  this milestone (re-read + re-dispatch is allowed; the cache comes in M5).
  Eviction just returns tasks to "only in DB" state; matcher races (ad717eae)
  are out of scope.
- the do-not-reset-readLevel-when-merged-is-empty rule (bug f534e74e): read
  races write, task gets loaded by the read and acked before the write's
  merge runs.

Check: same core properties. Then **mutation-test** the model: re-introduce
each of the M2-relevant historical bugs (12e7c43a; 8ca7b640 #1-#4; f534e74e)
as one-line mutations and confirm the checker reports a violation with a
readable trace. Record each mutation + expected counterexample in a
`mutations/` directory so they can be re-run.

## M3 — Expired tasks

Tasks get a nondeterministic, monotonic `expired` flag (no real clock; an
action may mark any unacked task expired). Reads pass expired tasks through
merge as pre-acked entries (bug 0b372d5e); the acker skips them.

Check: liveness properties weaken from "eventually acked" to "eventually
acked-or-expired, and ackLevel eventually passes it". The key new check is
NeverStuck when a read returns a batch that is entirely expired (pre-fix
behavior: readLevel never advances and the reader spins/sticks). Mutation
test: revert to "drop expired tasks before merge" and confirm the liveness
violation is found.

## M4 — Unreliable DB: timeouts, retries, backoff races

Add the failure modes from the prompt to all three DB call types (read,
write, GC-delete):

- outgoing timeout: operation not performed, caller sees error.
- incoming timeout: operation performed, caller sees error (for reads this is
  equivalent to outgoing; for writes and deletes it is not).

Consequences modeled:

- failed read -> backoffTimer path, with the timer as a separate action that
  races readTasksImpl completion (bug 26d9a561: timer fires while readPending
  still true, must re-check after clearing readPending).
- failed write -> unpin(err): atEnd = false + defensive read trigger (bug #5
  of 8ca7b640). Written-but-unconfirmed tasks stay out of `confirmedWritten`
  (no liveness obligation) but NoLostTasks still applies once they land in
  the DB and get read/merged.
- writer retry of a timed-out write writes fresh levels (the caller retries
  through the whole stack); the old write may still land later ("delayed
  write" is out of scope per Fencing — but "landed, response lost" is in).
- GC delete partially applied / applied-but-error: numToGC bookkeeping only
  matters for scheduling, so model GC firing nondeterministically instead.

Liveness needs care here: unrestricted timeouts trivially break liveness, so
failures must be bounded (e.g. `eventually always` DB behaves, or a bounded
failure counter) — standard "fairness of the network" assumption. Mutation
tests: 26d9a561 and 8ca7b640 #5.

## M5 — Evicted-ack cache

Add the bounded `evictedAcks` cache: acks evicted above the new readLevel go
into the cache; re-read tasks found in the cache are merged as pre-acked;
cache trims highest levels when over capacity.

Check: same properties (the cache is a pure optimization, so all M1-M4
properties must still hold with the cache active — the interesting risk is a
cached ack incorrectly skipping a task that was *not* acked, violating
NoLostTasks). Use a tiny cache size (1-2) so trimming is exercised. Add an
`exists` assertion that the cache actually gets hit, so we know we're testing
it. Mutation ideas: skip the "delete from cache on hit" step, or trim lowest
instead of highest levels.

## M6 — Mutation sweep + model validation

Systematic pass to gain confidence the model is *sensitive*, not just green:

- Re-run all recorded mutations from M2-M5 against the final full model.
- Add a few synthetic mutations of tricky guards (drop the ackLevel filter in
  merge, skip advanceAckLevel after merging newlyWrittenTasks, drop the
  pinned-check in advanceAckLevelLocked, set atEnd = true on mergeWrite).
- Check state-space stats (distinct states, depth) are stable enough to run
  in CI-ish time; document how long a full check takes and at what constants.

Deliverable: a small script/README to re-run the checker and the mutation
suite, plus notes on which real-code invariants the model does and does not
cover.

## M7 (stretch) — Owner restart

Model partition unload/reload with a single owner at a time (no concurrent
owners / fencing — that's the separate model): in-memory state is lost,
reader restarts from the *persisted* ack level (which may lag the in-memory
one), M from metadata. This checks the "restart can cause re-dispatch but
never loss" claim in fairness.md, and that persisted-ack-level updates are
always safe to crash after. Also a natural home for checking that finalGC
can't delete unacked tasks.

## Out of scope (confirmed from prompt + code reading)

- DB "explicit failure" / conflict errors, ownership fencing, LWTs, rangeID.
- Subqueues: one reader, one writer, one subqueue.
- Matcher internals: completeTask's respool/transient-error paths, forwarded
  tasks, the setEvicted/matcher race (ad717eae), sync match.
- Application-level fairness (pass assignment, weights, dither, counters):
  levels are opaque ordered integers picked nondeterministically.
- Task ID block allocation / lease renewal in the writer.
- Backlog age/count metrics, numToGC scheduling details (GC timing is
  nondeterministic in the model).

## Assumptions to confirm

- The acker model ("any loaded task may be acked at any time, all eventually
  acked") is a fair abstraction of matcher + completeTask happy path.
- GC firing at arbitrary times (rather than modeling numToGC/interval) is
  acceptable — it strictly over-approximates real schedules.
- Writer retries of timed-out writes allocate fresh task levels (matches
  history retrying AddTask through SpoolTask).
- Read timeouts don't need the "performed anyway" variant (reads have no
  side effects on the DB).


