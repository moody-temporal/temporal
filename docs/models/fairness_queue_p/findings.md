# Findings

## 1. The "fair reader stuck" softassert is reachable (via expired tasks)

**Status: model-confirmed against the current code structure (M5).**

`fairTaskReader.mergeTasks` (fair_task_reader.go:397) treats the state
`mode == mergeWrite && !atEnd && loadedTasks == 0 && !readPending &&
backoffTimer == nil` as a should-never-happen bug: it fires
`softassert.Fail("fair reader stuck")`, bumps `FairReaderStuckDetected`, and
does a repair read described as defensive.

The model reaches this state with no bug present, in a few steps
(FairQueue_0_0.txt trace, 0.3s to find):

1. Writer writes task at level 3; reader merges it directly (atEnd), acker
   completes it. The ack level stays pinned at 0 because the writer has
   already pinned for its next write. Buffer now holds only the ack for 3.
2. Writer writes level 2 (below readLevel 3; legal, it's above the pinned ack
   level 0), and by merge time the task is expired.
3. mergeTasksLocked: merged = {2} (3 is an ack, not part of the merged set),
   so readLevel regresses to 2 — correct per the merge rules — and the ack at
   3 is evicted as "above the new readLevel", clearing atEnd. The expired
   task 2 becomes a pre-acked entry, not a loaded task.
4. Result: loadedTasks == 0, !atEnd, no read pending, no backoff timer →
   softassert fires; without the repair read the reader would be stuck (the
   evicted ack at 3 means the db still holds task 3, and nothing else would
   trigger a read).

Consequences:

- The softassert and metric will fire spuriously in production whenever a
  write below readLevel expires before merging while the buffer holds only
  acks. (Requires an already-expired task to be written / merged, e.g. a very
  short schedule-to-start timeout combined with write latency or a respool.)
- The repair read is load-bearing for correctness in this scenario, not
  defensive: the model asserts the stuck state is unreachable *except* via
  expired tasks, and that holds across the search portfolio.

Suggested code changes (either or both):

- Downgrade the softassert to a debug log / expected-case metric when the
  merge involved expired tasks, or
- Trigger the read directly when a write-merge ends with loadedTasks == 0 &&
  !atEnd instead of treating it as an anomaly.

A Go unit test reproducing the sequence above would confirm on the real code.

## 2. The "completed task was already acked" softassert is reachable

**Status: model-confirmed against the current code structure (M7).**

`fairTaskReader.completeTask` (fair_task_reader.go:146) softasserts that a
completing task is not already marked acked in outstandingTasks. The model
reaches that state with no bug present (probe assert, found by both random
and feedbackpct within seconds):

1. Task 5 is loaded and added to the matcher; a poller matches it, so its
   completion is in flight (evicting it from the matcher is now a no-op —
   the code's own comment at the top of completeTask covers this half).
2. A write of two lower-level tasks merges in; the buffer is full, so task 5
   (unacked, loaded) is evicted from outstandingTasks and readLevel drops
   below it.
3. A later read re-reads task 5, which has meanwhile expired: it is
   re-inserted as a pre-acked (nil) entry per the expired-task handling.
4. The original completion from step 1 arrives: outstandingTasks has a nil at
   that level → softassert "completed task was already acked" fires.

A variant without expiry also exists: the re-read task is re-dispatched and
completed a second time; whichever completion lands second hits the same
branch (or the "missing" branch if the ack level has moved past it — that one
is already treated as expected: TaskCompletedMissing metric, no softassert).

Consequence: spurious softassert noise under eviction pressure (buffer
overflow from below-readLevel writes) combined with in-flight completions —
i.e. exactly under heavy fairness-weighted load. The no-op behavior itself is
correct; only the softassert's "this indicates a bug" assumption is wrong.
Suggested change: treat it like the missing case (metric, no softassert).

## 3. Busy re-read churn while the lowest loaded task is unmatched

**Status: model-confirmed (PEx counterexample, 189 steps, found in 3s);
mechanism traced through the Go code by hand. Corroborates the TLA+ model's
independent finding of the same loop.**

Setup: the lowest loaded task L never completes (realistic: a backlogged
fairness key with no pollers), while tasks above it (levels m, n) have
completed but their acks can't advance ackLevel past L. Then this cycle runs
forever inside a single readTasksImpl loop, with no completions driving it:

1. Read > readLevel returns m, n; both hit the evictedAcks cache and are
   re-inserted as pre-acked entries; readLevel = n.
2. The next batch returns empty (read-to-end). merged = {L} only (acks are
   not part of the merged set), so readLevel regresses to L, and the acks at
   m and n are evicted as "above the new readLevel" (re-cached), setting
   evictedAnyTasks and therefore atEnd = false — even though this read just
   proved we're at the end.
3. shouldReadMoreLocked: !atEnd && loadedTasks (=1) <= reloadAt → read again
   from L. Same responses. Loop.

Each lap does 2 db reads. Nothing bounds it: not time, not completions. The
reader hammers the db until L completes or the partition unloads.

Model specifics: BoundedRedispatch (PSpec) converts the churn into a bounded
safety property (no level dispatched > 10 times). With the model's tiny
evictedAcks cache (cacheSize 1), the cycle also re-DISPATCHES the task whose
ack got trimmed, every lap — Go's 256-entry cache bounds the re-dispatch
variant in practice until the cache overflows, but not the read churn.

Notably: only PEx (systematic DFS) finds this; 70k+ sampled schedules per
config never sustained the cycle (all terminated <= 174 steps). Cycle-shaped
bugs are the sampling checker's blind spot.

Suggested fix direction: in mergeTasksLocked, a mergeReadToEnd that adds no
new tasks should not regress readLevel below already-read acks (the same
spirit as the f534e74e fix, which handled the merged-set-empty case; this is
the merged-set-nonempty-but-lower case). Alternatively, don't treat evicted
*acks* as "evictedAnyTasks" for the purpose of clearing atEnd on a
read-to-end: the acks being evicted were all within the range just read.
