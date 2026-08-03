
We have a component with some very tricky logic, that we've found some tricky
bugs in before. I would like to increase my confidence in the component by
writing a P model for it and checking various properties (primarily liveness).

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

In general I don't want the model to verify anything about "fairness", even
though that's the purpose of the system. Our notion of fairness is statistical
and not something that P is suited to handle. We're looking for correctness
and liveness properties here.

It may be too complicated to build the full desired model in one shot. First,
please list a series of milestones of increasing model complexity. After that
we'll implement them one by one.

Milestones:

Status (2026-07-28): M1-M5 done and committed (one jj commit each; model in
PSrc/, specs in PSpec/, driver in PTst/, mutation results in mutations.md,
findings in findings.md — one so far: reachable "fair reader stuck"
softassert). M7 done: all mutations in mutations/ caught via ./mutate.sh. M8 done (matcher handoff: evict-vs-add race + setEvicted tombstone). Findings 1-2 in findings.md.

Modeling choices that apply throughout:

- Machines: `Writer`, `Reader`, `Database`, `Acker`, and (from M3) `GC`, plus
  spec monitors observing `announce` events. The database is its own machine,
  so every operation is a request/response message pair — in-flight windows
  exist even before we model timeouts.
- Task levels are single unique integers, chosen nondeterministically by the
  writer (abstracting stride scheduling), always above the current ack level.
- Small bounded instances: ~4-6 tasks total, batch size 2-3, reload threshold
  1. Liveness checking needs full schedule exploration, so keep instances tiny
  and only grow them for safety-only checks.
- Each milestone ends with a quick mutation check of the logic just added
  (break it on purpose, confirm the checker complains), in addition to the
  systematic mutation pass in M7.

**M1: Happy path.** Writer writes tasks with increasing levels; all DB calls
succeed. Reader: read loop with readLevel/ackLevel, bounded in-memory buffer,
shouldReadMore gating, atEnd. Acker acks loaded tasks in any order; ack level
advances to the lowest unacked task. Specs: liveness monitor "every
write-confirmed task is eventually acked" (hot until drained); invariant that
the buffer is exactly the unacked tasks in (ackLevel, readLevel]. The real goal
is scaffolding: project layout, test driver, and a working
counterexample-trace workflow before any concurrency trickiness.

**M2: Out-of-order writes and the merge.** Writer levels may now land below
readLevel. Model wroteNewTasks and the full mergeTasksLocked semantics: bypass
merge, atEnd updates, dropping above-readLevel writes when not atEnd, eviction
of loaded tasks and of acks above the new readLevel, leaving readLevel alone
when the merged set is empty, newlyWrittenTasks buffered while a read is
pending, and ack-level pinning during a write. Bugs this milestone should be
able to catch: 12e7c43a, 8ca7b640 items 1-4, f534e74e.

**M3: GC.** A GC process deletes tasks <= ackLevel (as a DB request, so it
interleaves with everything else). New safety spec: never delete a task that
was confirmed written but not acked. This is the property ack-level pinning
exists for (see "Ack level movement while a write is in flight" in
fairness.md) — check that pinning is actually sufficient.

**M4: Timeouts and retries.** DB requests (read, write, GC) may
nondeterministically time out on the outgoing side (op not performed) or the
incoming side (op performed, response lost); bound the number of failures (or
use fairness) so a run can't fail forever. Adds the read-retry backoff timer
as a concurrent event, and failed-write handling in unpin (atEnd = false, kick
a read). The delivery property now conditions on confirmed writes only: a
timed-out write may or may not be durable. Bugs targeted: 26d9a561 (backoff
timer firing while readPending), 8ca7b640 item 5.

**M5: Expired tasks.** Tasks may be expired by the time they're read
(nondeterministic at merge time); expired tasks flow through the merge as
pre-acked entries so read/ack levels advance past them. Bug targeted: 0b372d5e
(reader stuck re-reading an all-expired batch forever). The delivery guarantee
exempts expired tasks; the no-stuck-reader property must still hold.

**M6: Evicted ack cache.** Model evictedAcks: acks evicted above readLevel go
into a bounded cache (trimmed from the highest level); re-reading a cached
level turns it back into a pre-acked entry instead of re-delivering. Check
that the cache preserves all specs under trimming — re-delivery after a trim
is allowed (at-least-once), lost tasks and stuck readers are not.

**M7: Systematic mutation testing.** Re-introduce each historical bug into the
model (one mutation each for 12e7c43a, the five 8ca7b640 items, 26d9a561,
f534e74e, 0b372d5e) and confirm the checker reports a violation. Record which
spec catches which mutation and at what bounds. This calibrates whether the
model is detailed enough to trust as a regression net.

**M8 (stretch): Matcher handoff.** A minimal matcher machine so that a task
can be matched-and-removed concurrently with eviction (ad717eae: completeTask
arriving for a task no longer in outstandingTasks). Possibly out of scope per
the notes above; decide after M7.


