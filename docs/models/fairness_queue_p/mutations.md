# Mutation testing log

All mutations are automated: `./mutate.sh` applies each `mutations/<id>.old ->
<id>.new` replacement, compiles, runs the checker (random, then feedbackpct),
expects a bug, and restores the source. `./mutate.sh M2c` runs one.

Each mutation reintroduces a historical bug (or breaks newly-added logic) to
verify the model can detect it. "Caught by" lists what actually failed.
Detection strategy portfolio: `--sch-random`, `--sch-pct 10`,
`--sch-feedbackpct 20`, 20-30k schedules each.

## M1

| id  | mutation | target | result |
|-----|----------|--------|--------|
| M1a | no maybeRead() after completing a task | harness sanity | caught: liveness, 0.15s, 33% of schedules |
| M1b | don't clear atEnd when a written task doesn't fit | harness sanity | caught: liveness, <1s |

## M2

| id  | mutation | target | result |
|-----|----------|--------|--------|
| M2a | merge writes immediately instead of buffering during pending read | 12e7c43a | caught: liveness, 0.2s, 25% of schedules — but ONLY after modeling in-flight read responses (see below) |
| M2b | keep acks above new readLevel instead of evicting | 8ca7b640 #4 | caught: invariant `outstanding <= readLevel`, 100% of schedules; with that invariant disabled: `ackLevel <= readLevel`; with both disabled: liveness (lost task). Three independent detection layers. |
| M2c | collapse readLevel to ackLevel when merged set is empty | f534e74e | caught: "fair reader stuck" assert — but only by `--sch-feedbackpct 20` (12.6s, 0.06% of schedules). Random and plain feedback missed it at 20-30k schedules. |

## M3

| id  | mutation | target | result |
|-----|----------|--------|--------|
| M3a | disable ack level pinning | fairness.md "ack level movement while a write is in flight" | caught: 100% of schedules. Liveness (write filtered below runaway ackLevel) on most seeds; NoLostTask "task deleted before completion" (GC deletes an in-flight write) on 3/8 seeds. |

## M5

| id  | mutation | target | result |
|-----|----------|--------|--------|
| M5a | drop expired tasks at merge intake instead of pre-acking them | 0b372d5e | caught: potential-liveness (hot monitor through max-steps: infinite re-read loop starves a confirmed task), 4s. NOTE: a first, unfaithful version of this mutation (dropping expired tasks after the merged-set cut, where they still advance readLevel) was NOT caught — mutation placement must match where the old code actually differed. |

Also in M5: the base model itself found finding #1 (reachable "fair reader
stuck" softassert via expired writes) — see findings.md. The model now
implements Go's repair read, plus an assertion that the stuck state is only
reachable when expired tasks are involved.

## M7

| id  | mutation | target | result |
|-----|----------|--------|--------|
| M7a | eviction no longer clears atEnd | merge rule: evicted ranges must force a re-read | caught: liveness |

M1b (don't clear atEnd when a written task doesn't fit) no longer maps to the
current merge structure; M7a covers the same rule in its current form.

Full harness run on the M6 model (all caught by --sch-random at 20k, ~11 min
total; the layered asserts catch stuck states much earlier than quiescence,
which is why M2c no longer needs feedbackpct):

    M1a: caught -- liveness
    M2a: caught -- liveness
    M2b: caught -- invariant: outstanding level > readLevel
    M2c: caught -- assert: fair reader stuck without expired tasks
    M3a: caught -- liveness
    M4a: caught -- assert: fair reader stuck without expired tasks
    M4b: caught -- assert: fair reader stuck without expired tasks
    M5a: caught -- potential liveness (infinite re-read loop)
    M6a: caught -- NoLostTask: task deleted before completion
    M7a: caught -- liveness

## M8

| id  | mutation | target | result |
|-----|----------|--------|--------|
| M8a | remove the setEvicted tombstone: a matcher add that lost the race to an eviction proceeds anyway | ad717eae | confirmed NOT CAUGHT (as expected) — the phantom instance is completed and ignored by the reader (missing/already-acked no-ops), then the level is re-read and re-dispatched, so no modeled property breaks. The real-world harm (matcher bookkeeping / phantom entries) is outside this abstraction. Excluded from mutate.sh's default set for that reason; run manually with `./mutate.sh M8a` to confirm. |

## M6

| id  | mutation | target | result |
|-----|----------|--------|--------|
| M6a | also cache evicted UNACKED tasks in evictedAcks (cache poisoning) | evictedAcks correctness rationale | caught: liveness (undelivered task treated as completed on re-read), 1.4s |

Note: the cache itself is a pure optimization — removing it entirely is the
M2-M5 model, which was verified clean — so the meaningful check is that only
genuinely-acked levels can enter it. Trim direction (highest-first) is an
efficiency choice, not a correctness one: trimming just causes re-dispatch,
which the spec permits.

## M4

| id  | mutation | target | result |
|-----|----------|--------|--------|
| M4a | no final maybeRead() at the end of the failed-read loop tail | 26d9a561 | caught: liveness, first schedule explored |
| M4b | failed-write unpin clears atEnd but doesn't kick a read | 8ca7b640 #5 | caught: "fair reader stuck" assert, first schedule explored |

### Modeling lessons

- **The backoff-timer race needs a hop machine.** The tail of the read loop
  after an error (eReadLoopDone) is bounced through a Hop machine instead of a
  direct self-send: a self-send is one hop and would always beat the timer's
  two-hop firing path, making the 26d9a561 race unexplorable.
- **In-flight read responses are load-bearing.** P's `send` enqueues atomically
  into a FIFO queue, so a DB read response would always beat any eWroteTasks
  triggered by a later DB op, hiding the 12e7c43a race entirely. The Database
  machine therefore holds computed read results in a self-send hop
  (eReadServed) before delivering, modeling Go's lock-released-during-IO
  window. Mutation M2a is invisible without this.
- **Search strategy matters.** M2c is only found by feedbackpct. Every clean
  claim should run the full portfolio.
- **Cycle-shaped bugs need systematic search.** The churn loop (finding #3)
  was invisible to 100k+ sampled schedules across every strategy — random
  scheduling breaks the cycle probabilistically — but PEx DFS (`p compile
  --mode pex`, `p check --mode pex --sch-pex dfs`; needs maven + jdk21, e.g.
  `nix-shell -p openjdk21 maven`) sustained it immediately. Converting the
  liveness-flavored churn into a bounded safety property (BoundedRedispatch)
  is what made it checkable at all. PEx also dedups states (TLC-like) and
  reports distinct-state counts.
- 8ca7b640 #1 (ignore read tasks <= ackLevel): analysis says this filter is
  unreachable in the current code structure (single sequential read loop;
  response tasks are always > readLevel-at-send >= any reachable ackLevel, as
  ackLevel <= readLevel and readLevel is frozen while a read is in flight). It
  appears to be defensive. Not usable as a mutation; revisit in M7 and when
  M4-M6 change reachability.
- 8ca7b640 #3 (ignore re-read tasks that are already-acked in outstanding):
  reverting it re-dispatches an acked task; the spec permits duplicate
  dispatch (at-least-once), so no violation is expected. Its real-world
  consequence was accounting corruption not modeled here.
