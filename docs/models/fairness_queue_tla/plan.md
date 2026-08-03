
We have a component with some very tricky logic, that we've found some tricky
bugs in before. I would like to increase my confidence in the component by
writing a TLA+ model for it and checking various properties (primarily
liveness).

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
  for us in a fair order based on a stride scheduling algorithm.
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

Details in the code to explicitly **not** include:

- Database calls that explicitly fail: this would primarily be due to
  "conflict", i.e. task queue partition ownership loss. We'll create a separate
  model for the ownership/write fencing protocol if necessary.
- Subqueues: assume only one writer and one reader.

For other questions about which details of the code should be reflected in the
model or ignored, please ask.

Properties to check:

- If a task is written it will eventually be acked. That implies these
  properties, which could be worth checking separately:
  - The reader never gets "stuck" (in a state where there are tasks in the
    database but the reader will never read them).
  - We never GC a task before acking it (this would be even worse.. a restart
    could fix the previous situation but not this).

In general I don't want the model to verify anything about "fairness", even
though that's the purpose of the system. Our notion of fairness is statistical
and not something that TLA+ is suited to handle. We're looking for correctness
and liveness properties here.

Please use PlusCal, it'll be much easier to read and maintain. `java` is
available on the PATH, and `tla2tools.jar` is available in
`./docs/models/tla2tools.jar`.

It may be too complicated to build the full desired model in one shot. First,
please list a series of milestones of increasing model complexity. After that
we'll implement them one by one.

Milestones:

General approach notes (apply to all milestones):

- One growing PlusCal spec (checked in per-milestone via git history), plus a
  small `.cfg` per property set. Keep constants tiny: ~3-4 tasks total, batch
  size 2, 2-3 distinct pass values, so TLC state space stays tractable.
- The DB is a separate process from the start: callers place a request in a
  network variable and block for a response, so a request can be in flight
  while other processes act. Milestone 1 makes all calls succeed; timeouts are
  added later as a change to network behavior only.
- Abstract the stride counter: the writer picks each task's pass
  nondeterministically, constrained only to be >= the pinned base pass, with
  ids assigned sequentially. This preserves the one property the reader relies
  on (writes may land below or above readLevel, never at-or-below ackLevel)
  without modeling weights/fairness.
- Ignore: subqueues, task forwarding/matcher details, rangeID/fencing,
  explicit DB errors, throttling, backlog age/metrics.
- Validation step for each milestone: after the properties pass, re-introduce
  the corresponding historical bug (mutation test) and confirm TLC finds a
  counterexample. A milestone isn't done until its target bugs are caught.

**M1 — Reader + acker over a reliable async DB (static queue).**
Scope: DB pre-populated with tasks at distinct levels; reader process with
readLevel / ackLevel / outstandingTasks (task-or-ack entries) / loadedTasks /
atEnd / readPending; batch reads with mergeReadMiddle vs mergeReadToEnd;
acker process acks loaded tasks in any order; advanceAckLevel. No writer, no
GC, no failures, no expiry.
Properties: invariants — in-memory tasks are exactly a subset of (ackLevel,
readLevel]; ackLevel monotonic and never passes an unacked task; loadedTasks
matches the map. Liveness — every task is eventually acked; reader never
wedges (if DB has tasks above ackLevel, a read eventually happens).
Purpose: establish the skeleton and vocabulary; shake out level-ordering and
merge scaffolding.

**M2 — Concurrent writer with ack-level pinning.**
Scope: writer process writes batches (size 1-2): getAndPinAckLevel, pick
levels, async DB write, wroteNewTasks/mergeWrite, unpin. Includes the
newlyWrittenTasks holding buffer (write lands while read pending), eviction
of tasks *and* acks above the new readLevel on merge, the "ignore writes
above readLevel when not atEnd" rule, and the "don't move readLevel when the
merged set is empty" rule. Writes still always succeed.
Properties: M1 properties, now with writes: every *written* task is
eventually acked; plus "never write at-or-below ackLevel".
Target bugs: 12e7c43a (buffer writes during pending read), 8ca7b640 bugs 1-4
(below-ack reads, readLevel collapse, re-read of acked tasks, ack eviction),
f534e74e (readLevel reset to ackLevel when merged set empty → stuck reader).
Note: model the defensive "fair reader stuck" check as an invariant violation
rather than a repair, so TLC reports it instead of papering over it.

**M3 — GC.**
Scope: GC process that deletes DB tasks <= ackLevel (triggered
nondeterministically whenever numToGC > 0; batch limit optional). Deletes are
idempotent.
Properties: the big safety one — a task is never deleted from the DB before
it is acked. This exercises the pinning protocol end-to-end (the "ack level
movement while a write is in flight" problem in fairness.md): without
pinning, GC between pass-selection and write completion destroys just-written
tasks.
Target bugs: the pre-production design flaw described in fairness.md
"Problems" section (verify by removing pinning as the mutation).

**M4 — DB timeouts and retry.**
Scope: any DB call may now time out on the outgoing side (op not performed)
or incoming side (op performed, caller doesn't know). Reader: failed read →
backoff timer → retry, including the timer-fires-while-readPending
interleaving; readPending cleared and rechecked at end of read loop. Writer:
failed write → atEnd=false + trigger read + (modeled) caller retries the
tasks as *new* writes with fresh ids; the timed-out-but-landed write must
still be found and acked. GC timeouts are harmless (retried later).
Properties: same safety; liveness now needs fairness assumptions ("the
network eventually stops timing out" — e.g., weak fairness on the success
branch, or a bound on consecutive timeouts). Every task that *landed in the
DB* is eventually acked, whether or not its writer learned of success.
Target bugs: 26d9a561 (backoff timer vs readPending race → reader stuck),
8ca7b640 bug 5 (failed write with empty buffer → atEnd=false forever, no
read ever triggered).

**M5 — Expired tasks.**
Scope: a task in the DB may nondeterministically become expired before it is
read; expired tasks flow through merge as pre-acked entries (advancing
readLevel and ackLevel) rather than being dropped.
Properties: liveness restated — every *non-expired* task is eventually acked;
expired tasks don't have to be dispatched but must never wedge the reader or
stall the ack level (an all-expired batch must still make progress).
Target bug: 0b372d5e (dropping expired tasks pre-merge → readLevel never
advances → infinite re-read loop).

**M6 — Evicted-ack cache.**
Scope: the bounded evictedAcks cache: acks evicted above the new readLevel
are remembered; re-reading a cached level re-inserts it as pre-acked instead
of redelivering; cache trims highest levels when over capacity.
Properties: the cache must never create a *new* ack (safety: ackLevel never
passes a task that was not genuinely acked), and liveness is preserved with
the cache in play, including when the cache overflows and drops entries
(redelivery is allowed; skipping is not).
Target bugs: none historical — this milestone is insurance for newer logic.

**Status (2026-07-27): M1-M6 implemented** in FairQueue.tla with all
mutation tests passing; see README.md for how to run and findings.md for
three findings (two model-confirmed against current code: the busy re-read
churn loop, and the reachable "fair reader stuck" softassert; plus spec
clarifications around timed-out writes). M7 not started.

**M7 (stretch) — matcher handoff races.**
Scope: a minimal matcher: between "added to matcher" and "completed", a task
may be matched-and-removed concurrently with eviction (setEvicted no-op
race), and completeTask may find the task missing from outstandingTasks
(re-read + duplicate dispatch path).
Target bug: ad717eae. May be out of scope for a single model, per the plan;
decide after M6 whether the state space allows it.

M7 feasibility assessment (post-M6): modeling the matcher handoff means
per-loaded-task state (pending-add / in-matcher / matched-completion-in-
flight) instead of a set of levels, roughly a 3^loaded multiplier on an
already ~4M-state model (~14 min liveness at MaxLevel=3). Expect it to
need MaxLevel=2 and/or safety-only checking, plus reworking every merge
call site. Doable as a follow-up if the ad717eae class of races is worth
it, but suggest reviewing findings.md first -- the current model already
surfaced two confirmed issues without it.


