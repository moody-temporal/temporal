# TLA+ model of the fair task queue

A PlusCal/TLA+ model of `service/matching/fair_task_{reader,writer}.go`,
checking correctness and liveness properties of the reader/writer/acker/GC
machinery over an unreliable database. See `plan.md` for goals and
milestones, `findings.md` for issues surfaced by the model.

## Files

- `FairQueue.tla` — the model (PlusCal; the TLA+ translation is embedded).
- `FairQueue.cfg` — default config: safety + liveness at MaxLevel=3.
- `FairQueue_safety4.cfg` — safety only at MaxLevel=4 (liveness at 4 is too
  slow for routine runs; run it manually before big changes if desired).
- `FairQueue_churn.cfg` — findings.md #1 regression: a task that never
  completes makes the reader busy-loop instead of quiescing (expected to
  VIOLATE ReaderQuiesce on current code).
- `run.sh` — translate + check the real model, then check every mutation
  and verify TLC catches it, then reproduce the confirmed findings.
- `Trivial.tla/.cfg` — toolchain smoke test.

## Running

```sh
./run.sh                  # full suite (real model + all mutations)
# single run:
java -cp ../tla2tools.jar pcal.trans -nocfg FairQueue.tla
java -XX:+UseParallelGC -cp ../tla2tools.jar tlc2.TLC -workers auto FairQueue.tla
```

Note: always translate with `-nocfg` or pcal.trans clobbers the hand-written
`.cfg`.

## Model structure

Processes: `reader` (readTasksImpl loop), `timer` (read-retry backoff),
`writer` (taskWriterLoop/writeBatch), `acker` (completeTask calls),
`gc` (maybeGC/doGC), and `dbRead`/`dbWrite`/`dbGc` (the database serving
each RPC channel). Requests/responses are separate steps, so RPCs interleave
with everything.

Go's `tr.lock` critical sections map to single atomic PlusCal steps;
`mergeTasksLocked` is the pure operator `MergeResult` composed atomically at
each call site.

Key abstractions (see the header comment in FairQueue.tla for the full
list):

- Fair levels `<pass, id>` are plain integers: the logic only compares
  levels, so this preserves all orderings. The stride counter is abstracted
  to "writer picks any unused levels above the pinned ack level".
- DB calls may time out with the operation applied (incoming timeout) or
  not applied (outgoing). Liveness assumes only that *reads* succeed
  infinitely often if attempted infinitely often (SF on read success).
- Only "committed" tasks (initial backlog + writes whose RPC succeeded)
  carry delivery guarantees; rows landed by timed-out writes are
  unguaranteed duplicates (the caller re-submits).
- The acker has per-level strong fairness: every loaded task is eventually
  acked, even across evict/re-read cycles.
- Not modeled: subqueues, ownership/fencing (separate model if needed),
  matcher handoff races, explicit DB errors, throttling.

## Properties

Safety (invariants):
- `MemWindow`: in-memory entries are exactly within (ackLevel, readLevel].
- `NoAckSkipped`: the ack level never passes an unacked committed task.
- `GCOnlyAcked`: GC never deletes an unacked committed task.
- `PinProtectsWrites`: the write pin keeps ackLevel below in-flight writes.
- `CacheOnlyAcked`/`CacheBounded`: the evicted-ack cache never fabricates
  an ack and stays within its size bound.
- `NoStuck`: the defensive "fair reader stuck" softassert does not fire.
  NOT an invariant of current code (findings.md #3) — used by run.sh as a
  findings regression and for historical mutations with StuckRepair=FALSE.
- plus type/bookkeeping invariants (`TypeInv`, `AckBelowRead`, `LoadedInDb`,
  `LoadedBounded`).

Liveness (under the fairness assumptions above):
- `AllTasksAcked`: every committed task is eventually acked.
- `EventuallyDrained`: the reader eventually reaches (and keeps) the
  drained state: atEnd with nothing loaded.
- `AckLevelMonotonic`: the ack level never moves backwards.

## Mutation tests

Each `Mut*` constant re-introduces one bug (historical bugs are tagged with
their fixing commit; "seeded" ones are synthetic). `run.sh` checks that TLC
finds the expected violation for each — a milestone isn't trusted until its
target bugs are demonstrably caught. All flags FALSE = current code.
