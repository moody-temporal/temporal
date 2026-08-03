# FizzBee model of the fair task queue (fairTaskReader / fairTaskWriter)

Formal model of `service/matching/fair_task_{reader,writer}.go` checked with
[FizzBee](https://fizzbee.io/). See `plan.md` for the milestone plan and
scope decisions (what's modeled, what's deliberately not).

## Files

| File | Contents |
|---|---|
| `m1.fizz` | Reader + acker over a reliable, pre-populated DB |
| `m2.fizz` | M1 + concurrent writer: pinning, mergeWrite, buffering, eviction |
| `m3.fizz` | M2 + expired tasks (pre-acked merge handling, 0b372d5e) |
| `m4.fizz` | M3 + DB timeouts (both sides), read retry/backoff, unpin(err) |
| `m5.fizz` | M4 + the bounded evicted-ack cache |
| `mbt/queue_mbt.fizz` | MBT variant (collapsed to test-controllable actions); see the MBT section |
| `mutations/` | Re-runnable mutations: each reintroduces a historical or synthetic bug and must make the checker FAIL |
| `probes/` | Tiny specs verifying FizzBee semantics the model relies on |

The MBT adapter itself lives in
`service/matching/fizz_mbt_{gen,adapter}_test.go` (it needs package-private
access), and adds a test-only `go.mod` dependency on
`github.com/fizzbee-io/fizzbee/mbt/lib/go`.

Run a model: `./check.sh mN.fizz` — this wraps `fizz` in a systemd scope
with a 32G memory cap (the checker keeps the whole state graph plus its BFS
queue in memory; an unbounded run can OOM the machine — run ONE at a time).
PASSED means all `always`/`transition` assertions hold on every reachable
state, every `exists` assertion is reachable, and the `eventually always`
liveness property holds on all fair paths. Run the mutation suite:
`cd mutations && ./run.sh` (a mutation is OK when the checker FAILS on it).

State-space budget: boolean ghost flags roughly double distinct states, so
m4/m5 keep only ghosts that assertions require (`confirmed`, `ever_acked`,
`expired`, `used_levels`, plus `ever_cache_hit` in m5), model `numToGC` as a
dirty bit, and keep `newlyWrittenTasks` sorted (its order is semantically
irrelevant). m3-m5 use a 3-level universe; m2 uses 4.

## Model structure

One flat spec per milestone; global state + top-level atomic actions (no
FizzBee roles — probes showed helper funcs can mutate globals, which lets
each `atomic fair action` correspond exactly to one lock-held region of the
Go code, with interleaving only between regions):

- Reader: `ReaderReadLoop` (one iteration of `readTasksImpl`, including the
  loop-exit processing of `newlyWrittenTasks`), `ReaderMergeRead`,
  `ReaderRetryArm`, `BackoffTimerFire`; `merge_tasks()` mirrors
  `mergeTasksLocked` line by line, `advance_ack()` mirrors
  `advanceAckLevelLocked` with the two pinning sources.
- Writer: `WriterWrite` (pin + pick level), `WriterMergeWrite`
  (`wroteNewTasks`, or buffering into `newlyWrittenTasks` when a read is
  pending), `WriterUnpin`, `WriterWriteError` (`unpinAckLevel(err)`).
- DB: `DbRead` / `DbWrite` / `DbGcComplete` actions consuming request state
  and producing responses; each can time out on either side (op applied vs
  not, response lost either way) from M4 on.
- Acker: `AckTask` acks any loaded task, with per-element fairness
  (`fair any`) — the model-level statement that every dispatched task
  eventually completes.
- GC: NOT modeled (review decision). GC only issues "delete where
  level <= ackLevel", which is safe by construction whenever
  `AckLevelOnlyPassesAcked` holds — that assertion IS the "never GC an
  unacked task" property. The delete is idempotent and carries no
  obligations, so modeling its scheduling/timeouts only multiplied states.
  A consequence used elsewhere: `db_tasks` is monotone.
- Levels: single small integers (the `<pass, id>` pair collapsed); the
  writer picks any level above the pinned ack level that is not in the DB —
  levels are deliberately NOT monotonic across writes. Real task ids are
  never reused, but a timed-out-unapplied write leaves no observable trace,
  so reusing its level explores an isomorphic behavior; this both shrinks
  the level universe needed and dedups failed-write retry states (and
  removes the `used_levels` ghost).
- Ghost state for assertions only: `confirmed` (write acknowledged to the
  caller), `ever_acked`, `expired`, plus a couple of reachability flags in
  the smaller models (each boolean ghost roughly doubles distinct states,
  so m4/m5 carry almost none).

## Properties

Safety (`always` / `transition`):
- `MemoryInWindow` — `outstandingTasks` ⊆ (ackLevel, readLevel], and
  ackLevel <= readLevel.
- `WindowComplete` — every confirmed task in the DB inside
  (ackLevel, readLevel] is tracked in `outstandingTasks` or held in
  `newlyWrittenTasks` (nothing at-or-below readLevel can be forgotten).
- `AckLevelOnlyPassesAcked` — the ack level never passes a confirmed task
  that wasn't acked (or expired). Since GC deletes only at-or-below a
  previously observed ack level, this subsumes "never GC an unacked task".
- `AckLevelMonotonic`.
- M5: `CacheOnlyHoldsAcked` — the evicted-ack cache only ever contains
  genuinely acked/expired levels.

Liveness (`eventually always`, under fairness assumptions: acker completes
every loaded task, DB reads eventually succeed when retried forever):
- `AllConfirmedTasksAcked` — every confirmed task is eventually
  acked-or-expired AND the ack level passes it; this subsumes "the reader
  never gets stuck".

`exists` assertions document that the interesting machinery is actually
exercised (buffer fills, eviction, buffered writes, GC, backoff, zombie
rows, cache hits/trims).

## Findings so far

1. **The "fair reader stuck" softassert state is reachable** (M3): with only
   pre-acked entries in memory (e.g. an expired task merged from a read) and
   a write whose task expired in flight, the write's merge regresses
   readLevel, evicts the older acks, clears atEnd, and loads nothing — while
   the ack level is pinned by the writer. `softassert.Fail("fair reader
   stuck")` at `fair_task_reader.go` fires on this path in the real code.
   More importantly, the *defensive backstop read* next to it is
   load-bearing there: in a model without it, the reader never reads again
   and liveness fails (later confirmed writes above readLevel would be
   dropped from memory and never dispatched). Suggestion: keep the backstop,
   but the softassert/metric will produce false alarms under short-TTL
   tasks.
2. **ReadLevel regression churn** (M1): after reading to the end, if the
   highest in-memory entries are acks and a merge leaves only lower loaded
   tasks, readLevel regresses and those acks are evicted, forcing a re-read
   and re-dispatch of acked tasks. Expected behavior (re-dispatch is
   allowed) — this is precisely the churn the M5 evicted-ack cache
   mitigates — but it surprised the liveness checker: the model must assume
   per-task ack fairness or a re-read task can starve its neighbor forever.

## Results / state space (as of last run)

NOTE: after review, GC was removed from all models and the `used_levels`
ghost replaced by level reuse; every result below except m1 predates that
refactor and needs a re-run (expected to be much smaller now — m1 went
803 -> 131 unique states).

| Model | Nodes | Unique states | Time | Result |
|---|---|---|---|---|
| m1 (4 tasks) | 228 | 131 | ~2s | PASSED (post-refactor) |
| m2 (4 levels) | ~169k | ~99k | ~4min | PASSED pre-refactor; re-run pending |
| m3 (3 levels) | ~195k | ~109k | ~5min | PASSED pre-refactor; re-run pending (4 levels exceeded 32G pre-refactor — retry at 4 after the refactor) |
| m4 (3 levels) | — | — | — | never completed pre-refactor (>32G); re-run post-refactor |
| m5 (3 levels) | — | — | — | same as m4 |

Memory notes: the checker holds the full state graph + BFS queue in RAM,
roughly 30G per ~1M states on these specs; `check.sh` caps it (default 32G,
`MEMMAX=96G` to raise on a big machine) and `--experimental_processed_queue`
(now default in check.sh) dedups the queue.

## Optimization notes (model-level)

Applied, in rough order of impact:
1. GC abstracted away entirely (see above) — removes two actions, a 3-way
   failure branch, and three state variables.
2. Level reuse instead of a `used_levels` ghost — failed-write retries
   collapse back into visited states instead of minting fresh ones.
3. Ghost booleans trimmed from m4/m5 (each roughly doubles states).
4. `numToGC` was already reduced to nothing by (1); before that it was a
   dirty bit rather than a counter.
5. `newlyWrittenTasks` kept sorted (its order is semantically irrelevant;
   permutations were distinct states).
6. Expiry bounded to one task total in m4/m5 (m3 checks full expiry).

Further ideas if still too big, roughly in order of preference:
- `--experimental_no_graph` for safety-only runs (refuses liveness specs):
  split each model's check into a big safety run + a smaller liveness run.
- Collapse the DB-response-in-flight step (merge `DbRead` into
  `ReaderMergeRead`): removes the RESP state and the `read_resp` lists.
  Trade-off: loses ack/expiry interleavings between the DB executing the
  query and the reader merging it (mostly guards the below-ack merge
  filter, which appears unreachable anyway — see m6_no_ack_filter).
- `BATCH_SIZE = 1` for m4/m5 (eviction and the cache still exercised).
- `max_actions: 60` — explicit depth bound; documents bounded checking.

## Model-based testing (MBT) — spec vs. the real code

`mbt/queue_mbt.fizz` is an MBT variant of the model (collapsed to the points
where a test can actually pause the real code), and
`service/matching/fizz_mbt_{gen,adapter}_test.go` hook it to the real
`fairBacklogManagerImpl` (real `fairTaskReader`/`fairTaskWriter`/
`taskQueueDB` over `testTaskManager`). Run:

    cd docs/models/fairness_queue_fizzbee/mbt && fizz queue_mbt.fizz   # regenerate states (13k states, ~30s)
    go test ./service/matching/ -run TestFizzQueueMbt -v               # needs fizzbee-mbt-server/-runner on PATH

The fizzbee-mbt runner replays generated action sequences against the SUT
and compares the full observable state after every action (read directly
from the reader's internals — the adapter lives in package matching):
readLevel/ackLevel (pass component), outstandingTasks, atEnd,
newlyWrittenTasks, evictedAcks, pinning, parked requests, and the fake
store's rows.

Control points: a gating TaskManager parks GetTasks until the trace
releases it; the injected `counter.Counter` parks the writer in pickPasses
and returns the trace-chosen level as the pass; CreateTasks outcomes
(ok / timeout applied / timeout not-applied) are pre-armed one-shot
decisions; the "acker" finishes captured spooled tasks; expiry rewrites the
stored task's ExpiryTime. Between actions the SUT quiesces (all goroutines
parked or idle), making comparison deterministic.

Findings and caveats:

1. **Write parking must happen in pickPasses, not in the store.**
   `taskQueueDB.CreateFairTasks` holds the taskQueueDB mutex across the
   store call, and a completing read's merge takes that mutex (via
   `setKnownFairBacklogCount`/`updateFairAckLevel`) while holding the
   reader lock — so a slow store write delays read merges *and task
   completions*. For the harness this was a deadlock; for production it's
   a latency coupling worth knowing about.
2. **Sensitivity scales with trace volume.** The runner generates uniform
   random action sequences (fizzbee-mbt 0.2.0), so narrow multi-step races
   need volume: re-introducing the 0b372d5e bug (drop expired tasks
   instead of pre-acking) into fair_task_reader.go passes 200 traces (3s)
   but is caught within a 20k-trace budget (~8s to failure) with the exact
   historical signature (ack level stops advancing past an expired task).
   Default is 2000 traces (~25s); crank `max-seq-runs` for a nightly run.
3. **Collapsed actions exclude in-flight-write races by construction**:
   the spec applies the store write inside WriterWriteOk, so races that
   depend on "write applied at the store but not yet merged" (f534e74e)
   are out of MBT scope — they remain covered by the m-series model
   checking. Same for backoff-timer races (real wall-clock timer).
4. fizzbee-mbt 0.2.0 gotchas, encoded in the test files: the plugin must
   call `mbt.ParseFlags()` (otherwise its option-override flags default to
   0 and silently force zero runs); the registry needs a no-op `"end"`
   pseudo-action for graphs with terminal states; role dict keys are
   compared as strings; top-level (non-role) state is not compared — put
   all state in a role.

## Mutation results

See `mutations/*.sed` headers for the bug each reintroduces and the
expected counterexample; `mutations/run.sh [name...]` re-checks them
(one at a time, memory-capped).

| Mutation | Historical bug | Status |
|---|---|---|
| m1_no_read_after_ack | (generic stuckness) | CAUGHT: liveness |
| m2_readlevel_reset | f534e74e | CAUGHT: NeverDetectsStuck |
| m2_no_write_buffer | 12e7c43a | CAUGHT: NeverDetectsStuck |
| m2_no_pin | fairness.md "Problems" | CAUGHT: AckLevelOnlyPassesAcked |
| m2_no_evict_acks | 8ca7b640 #4 | CAUGHT: MemoryInWindow |
| m2_no_pin_newly_written | (pinning via newlyWrittenTasks) | not yet run |
| m3_drop_expired | 0b372d5e | not yet run |
| m4_no_final_maybe_read | 26d9a561 | blocked on m4 base run |
| m4_no_read_after_write_error | 8ca7b640 #5 | blocked on m4 base run |
| m5_cache_loaded_evictions | (cache poisoning) | blocked on m5 base run |
| m6_no_ack_filter | 8ca7b640 #1 | blocked on m5; may be UNREACHABLE (documented) |
| m6_no_advance_after_buffered | (synthetic) | blocked on m5 |
| m6_atend_survives_eviction | (synthetic) | blocked on m5 |

Note: all "CAUGHT" results above predate the backstop-read change and the
GC-removal/level-reuse refactor. The expected verdicts are unchanged (none
of those mutations touch GC, and the m2_no_pin harm is caught at the
ack-level property rather than via GC deletion), but the whole suite needs
one re-run on the big machine to confirm.
