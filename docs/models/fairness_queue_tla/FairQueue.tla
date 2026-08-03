---------------------------- MODULE FairQueue ----------------------------
(***************************************************************************)
(* PlusCal model of matching's fair task queue reader/writer.              *)
(* Source: service/matching/fair_task_{reader,writer}.go                   *)
(* Milestones and scope decisions: see plan.md. Currently at: M6.          *)
(*                                                                         *)
(* Key abstractions:                                                       *)
(*                                                                         *)
(* - Fair levels <pass,id> are modeled as plain integers 1..MaxLevel.      *)
(*   The reader/writer logic is order-invariant: it only ever compares     *)
(*   levels, so any real execution maps to an integer execution that       *)
(*   preserves order. The stride counter is abstracted: the writer picks   *)
(*   any unused levels above the pinned ack level, which is the only       *)
(*   property the reader relies on (writes may land below or above         *)
(*   readLevel, never at-or-below the pinned ackLevel).                    *)
(*                                                                         *)
(* - Go guards reader state with tr.lock; every locked critical section    *)
(*   is one atomic PlusCal step (one label). Lock release points (network  *)
(*   calls) are label boundaries, which is where processes interleave.     *)
(*   mergeTasksLocked is the pure operator MergeResult so that each call   *)
(*   site can atomically compose it with its own pre/post logic.           *)
(*                                                                         *)
(* - outstandingTasks (treemap level -> task|nil) is split into two sets:  *)
(*   "loaded" (unacked *internalTask entries) and "ackedInMem" (nil        *)
(*   entries). loadedTasks == Cardinality(loaded).                         *)
(*                                                                         *)
(* - A task is ackable as soon as it is merged into "loaded"; the matcher  *)
(*   handoff is not modeled (see plan.md M7).                              *)
(*                                                                         *)
(* - The DB is reached via request/response channels (rdState.., wrState..,*)
(*   gcState..) modeled as separate processes. Calls may time out with     *)
(*   the op applied (incoming) or not applied (outgoing); liveness         *)
(*   assumes only that reads succeed infinitely often if attempted         *)
(*   infinitely often (SF on read success). Only "committed" tasks         *)
(*   (initial backlog + writes whose RPC succeeded) carry delivery         *)
(*   guarantees; rows landed by timed-out writes are unguaranteed          *)
(*   duplicates, since the caller re-submits on error.                     *)
(*                                                                         *)
(* - GC may fire whenever the ack level is above zero (the numToGC/time    *)
(*   trigger conditions are abstracted away); it is unfair, so liveness    *)
(*   cannot depend on GC running. The delete batch size is not modeled.    *)
(*                                                                         *)
(* - The defensive "fair reader stuck" softassert+repair in mergeTasks is  *)
(*   modeled as a ghost flag (stuckFlag) plus, when StuckRepair is TRUE    *)
(*   (current code), its repair read. The stuck state is REACHABLE via     *)
(*   writes of already-expired tasks (findings.md #3), so NoStuck is not   *)
(*   an invariant of the current code; run.sh keeps it as a reproducible   *)
(*   finding demo and uses StuckRepair=FALSE for historical mutations.     *)
(*                                                                         *)
(* - Task expiry is a nondeterministic per-merge choice (expSel): any      *)
(*   subset of the incoming tasks may be expired by the time the merge     *)
(*   looks at them. Consumed expired tasks become pre-acked nil entries    *)
(*   and leave the "committed" guarantee set. This avoids a persistent     *)
(*   expired-set variable (state-space explosion); it slightly widens      *)
(*   behavior (a re-read task's expiry status could flip), which is sound  *)
(*   for the properties checked here.                                      *)
(*                                                                         *)
(* Mutation flags "Mut...": each TRUE re-introduces a (mostly historical)  *)
(* bug to validate that the properties catch it; all FALSE models the      *)
(* current code. See run.sh.                                               *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, Sequences, TLC

CONSTANTS
  MaxLevel,        \* task levels are 1..MaxLevel
  BatchTarget,     \* config.GetTasksBatchSize: max tasks to keep loaded
  ReloadAt,        \* config.GetTasksReloadAt: read more when loaded <= this
  WBatchMax,       \* max tasks per write batch
  StuckRepair,     \* model the defensive stuck check's read trigger (TRUE =
                   \* current code; FALSE = the detector is absent)
  EvictedCacheMax, \* evictedAcksCacheSize: max evicted-ack cache entries
  AckableLevels,   \* levels the acker may ack (all of Levels normally; a
                   \* subset models tasks with no available poller, for the
                   \* finding-1 churn regression)
  \* --- mutation flags ---
  MutAtEndOnMiddleRead,  \* seeded: treat every read as reaching the end
  MutAckPastLoaded,      \* seeded: ack level advance ignores loaded tasks
  MutNoWriteBuffering,   \* 12e7c43a: merge writes directly during a pending read
  MutResetReadLevelOnEmptyMerge, \* f534e74e: readLevel := ackLevel when merge is empty
  MutKeepEvictedAcks,    \* 8ca7b640 #4: don't evict acks above new readLevel
  MutNoPin,              \* fairness.md problem 1: no ack level pinning during writes
  MutGcReadLevel,        \* seeded: GC deletes up to readLevel instead of ackLevel
  MutNoExitRecheck,      \* 26d9a561: no maybeReadTasksLocked after clearing readPending
  MutNoReadOnWriteError, \* 8ca7b640 #5: no read trigger from unpin on write error
  MutNoAtEndResetOnWriteError, \* 8ca7b640 #5: keep atEnd on write error
  MutDropExpiredEarly,   \* 0b372d5e: drop expired tasks before the merge
  MutCachePoison         \* seeded: evicted (unacked) tasks also enter the
                         \* evicted-ack cache (task/ack confusion)

ASSUME ReloadAt < BatchTarget
ASSUME MaxLevel >= 1
ASSUME AckableLevels \subseteq 1..MaxLevel

Levels  == 1..MaxLevel
NoLevel == 0

\* merge modes (mergeMode in fair_task_reader.go)
MMiddle == "readMiddle"
MToEnd  == "readToEnd"
MWrite  == "write"

SetMax(S) == CHOOSE x \in S : \A y \in S : y <= x
\* The n lowest elements of S (all of S if it has <= n elements).
KeepLowest(S, n) == {l \in S : Cardinality({m \in S : m <= l}) <= n}

\* ackLevelPinnedLocked, with the MutNoPin mutation applied
PinActive(p) == p /\ ~MutNoPin

(***************************************************************************)
(* mergeTasksLocked as a pure function: given the current ack-manager      *)
(* state and a set of incoming task levels, compute the new state.         *)
(*   inc:       levels just read or written                                *)
(*   pinnedNow: ackLevelPinnedLocked() at the time of the merge            *)
(* Returns a record; .stuck is the condition of the defensive "fair        *)
(* reader stuck" check (the call site must additionally rule out a         *)
(* pending read / backoff timer).                                          *)
(***************************************************************************)
MergeResult(loaded0, acks0, rl0, al0, atEnd0, inc, mode, pinnedNow, expSel,
            cache0) ==
  LET
    \* filter incoming: skip at-or-below ackLevel (raced with acks); on
    \* write when not atEnd, skip above readLevel (unknown range in
    \* between); skip levels we already have. Expired tasks flow through
    \* (0b372d5e); MutDropExpiredEarly restores the old drop-before-merge.
    eligible == {l \in inc :
                   /\ l > al0
                   /\ ~(mode = MWrite /\ ~atEnd0 /\ l > rl0)
                   /\ l \notin (loaded0 \cup acks0)}
    filtered == IF MutDropExpiredEarly THEN eligible \ expSel ELSE eligible
    \* loaded tasks plus incoming, keep the BatchTarget lowest
    merged == loaded0 \cup filtered
    kept   == KeepLowest(merged, BatchTarget)
    \* "if we have any tasks at all in memory, set readLevel to the max of
    \* that set"; if merged is empty leave readLevel unchanged (f534e74e)
    newRL == IF kept /= {} THEN SetMax(kept)
             ELSE IF MutResetReadLevelOnEmptyMerge THEN al0
             ELSE rl0
    \* evict acked (nil) entries above the new read level (8ca7b640 #4)
    keptAcks == IF MutKeepEvictedAcks THEN acks0
                ELSE {l \in acks0 : l <= newRL}
    \* evictedAnyTasks: any merged entry beyond BatchTarget (loaded
    \* evictions and ignored new tasks), or any evicted ack
    evictedAny == \/ (merged \ kept) /= {}
                  \/ keptAcks /= acks0
    \* the evicted-ack cache: acks evicted above the new readLevel are
    \* remembered (plus, under MutCachePoison, evicted unacked tasks --
    \* the bug the cache design must not have); trim to the cache size by
    \* dropping the highest levels (PopMax)
    cacheAdd == (acks0 \ keptAcks)
                \cup (IF MutCachePoison THEN loaded0 \ kept ELSE {})
    cacheTrimmed == KeepLowest(cache0 \cup cacheAdd, EvictedCacheMax)
    \* incoming tasks that made the cut but whose level is in the cache
    \* were already acked: re-insert as pre-acked (nil) entries instead of
    \* re-delivering, and drop them from the cache
    cacheHits == (kept \cap filtered) \cap cacheTrimmed
    \* incoming tasks that made the cut but are expired are added as
    \* pre-acked (nil) entries: they advance readLevel (above) and the ack
    \* level (below) and get GC'd, instead of being delivered (0b372d5e).
    \* Note: already-loaded tasks are not re-checked for expiry here.
    keptNewExpired == (kept \cap filtered) \cap expSel
    newLoaded == kept \ (keptNewExpired \cup cacheHits)
    newAcks   == keptAcks \cup keptNewExpired \cup cacheHits
    \* advanceAckLevelLocked: pop acked entries below the lowest loaded
    \* task, unless the ack level is pinned
    clear == IF PinActive(pinnedNow) THEN {}
             ELSE {c \in newAcks : MutAckPastLoaded \/ \A m \in newLoaded : c < m}
    newAtEnd == IF MutAtEndOnMiddleRead /\ mode \in {MMiddle, MToEnd} THEN TRUE
                ELSE IF (mode = MMiddle) \/ evictedAny THEN FALSE
                ELSE IF mode = MToEnd THEN TRUE
                ELSE atEnd0
  IN [
    loaded  |-> newLoaded,
    acks    |-> newAcks \ clear,
    rl      |-> newRL,
    al      |-> IF clear = {} THEN al0 ELSE SetMax(clear),
    atEnd   |-> newAtEnd,
    stuck   |-> mode = MWrite /\ ~newAtEnd /\ newLoaded = {},
    cache   |-> cacheTrimmed \ cacheHits,
    \* expired tasks consumed by this merge; the call site removes them
    \* from the "committed" guarantee set (deciding a task is expired ends
    \* its delivery obligation, whether handled as a nil entry or, under
    \* MutDropExpiredEarly, dropped like the historical code did)
    consumed |-> IF MutDropExpiredEarly THEN eligible \cap expSel
                 ELSE keptNewExpired
  ]

(* --algorithm FairQueue

variables
  \* ---- database ----
  dbTasks \in SUBSET Levels,   \* nondeterministic initial backlog
  \* ---- read RPC channel: reader -> db ----
  rdState  = "idle",           \* idle -> req -> resp -> idle
  rdFrom   = NoLevel,
  rdMax    = 0,
  rdResult = {},
  rdOk     = TRUE,             \* FALSE: read timed out (no side effects)
  \* ---- write RPC channel: writer -> db ----
  wrState  = "idle",           \* idle -> req -> resp -> idle
  wrBatch  = {},
  wrOk     = TRUE,             \* FALSE: write timed out (may still have applied)
  \* ---- gc RPC channel: gc -> db ----
  gcState  = "idle",           \* idle -> req -> resp -> idle
  gcFrom   = NoLevel,
  \* ---- reader state (fields of fairTaskReader, guarded by tr.lock) ----
  loaded       = {},           \* levels of unacked tasks in memory
  ackedInMem   = {},           \* levels of acked (nil) placeholder entries
  readLevel    = NoLevel,
  ackLevel     = NoLevel,
  atEnd        = FALSE,
  readPending  = TRUE,         \* Start() calls maybeReadTasksLocked
  newlyWritten = {},           \* newlyWrittenTasks: writes held during a read
  pinned       = FALSE,        \* ackLevelPinnedByWriter
  evictedAcks  = {},           \* the evicted-ack cache
  backoffTimer = FALSE,        \* a read-retry backoff timer is pending
  \* ---- writer state ----
  usedLevels = dbTasks,        \* levels ever allocated to a task (ids are unique)
  \* ---- ghost state (not part of the implementation) ----
  everInDb   = dbTasks,        \* every level ever present in dbTasks
  committed  = dbTasks,        \* initial backlog + writes whose RPC succeeded;
                               \* only these carry a delivery guarantee (a write
                               \* that returns an error may still have landed,
                               \* but the caller re-submits, so the landed row
                               \* is unguaranteed garbage; see fairness.md)
  ackedGhost = {},             \* every level ever acked
  gcVictims  = {},             \* every level ever deleted by GC
  stuckFlag  = FALSE;          \* defensive "fair reader stuck" check fired

define
  Outstanding    == loaded \cup ackedInMem
  LoadedCount    == Cardinality(loaded)
  \* shouldReadMoreLocked
  ShouldReadMore == ~atEnd /\ LoadedCount <= ReloadAt
  \* levels the writer may still allocate: unused, above the (pinned) ack level
  AvailableLevels == {l \in Levels : l \notin usedLevels /\ l > ackLevel}
  WriteBatches    == {B \in SUBSET AvailableLevels :
                        B /= {} /\ Cardinality(B) <= WBatchMax}
end define;

\* Assign the results of MergeResult r to the reader state.
macro applyMerge(r) begin
  loaded      := r.loaded;
  ackedInMem  := r.acks;
  readLevel   := r.rl;
  ackLevel    := r.al;
  atEnd       := r.atEnd;
  evictedAcks := r.cache;
end macro;

\* The exit path of readTasksImpl, one critical section (with the lock
\* still held from the loop check): clear readPending, merge tasks written
\* while the read was pending, advance ack level, then re-check
\* maybeReadTasksLocked (the 26d9a561 fix; MutNoExitRecheck removes it).
macro readerExit() begin
  if newlyWritten /= {} then
    with expSel \in SUBSET newlyWritten,
         r = MergeResult(loaded, ackedInMem, readLevel, ackLevel, atEnd,
                         newlyWritten, MWrite, pinned, expSel, evictedAcks)
    do
      applyMerge(r);
      committed    := committed \ r.consumed;
      newlyWritten := {};
      readPending  := /\ ~MutNoExitRecheck
                      /\ ~r.atEnd /\ Cardinality(r.loaded) <= ReloadAt
                      /\ ~backoffTimer;
    end with;
  else
    readPending := ~MutNoExitRecheck /\ ShouldReadMore /\ ~backoffTimer;
  end if;
end macro;

\* readTasksImpl: loop reading batches while shouldReadMoreLocked.
fair process reader = "reader"
begin
RWait:
  while TRUE do
    await readPending;
RCheck:
    \* top of readTasksImpl loop: check and capture under lock, then
    \* release the lock for the network call
    if ShouldReadMore then
      rdFrom  := readLevel + 1;      \* readLevel.max(minFairLevel).inc()
      rdMax   := BatchTarget - LoadedCount;
      rdState := "req";
RResp:
      await rdState = "resp";
      rdState := "idle";
      if rdOk then
        \* got fewer than asked for => we hit the end (mergeReadToEnd)
        with expSel \in SUBSET rdResult,
             mode = IF Cardinality(rdResult) < rdMax THEN MToEnd ELSE MMiddle,
             r    = MergeResult(loaded, ackedInMem, readLevel, ackLevel, atEnd,
                                rdResult, mode, pinned \/ newlyWritten /= {},
                                expSel, evictedAcks)
        do
          applyMerge(r);
          committed := committed \ r.consumed;
        end with;
        goto RCheck;
      else
        \* read error: retryReadAfter arms the backoff timer in its own
        \* critical section, separate from the exit path below -- this
        \* gap is where the 26d9a561 timer race lives
        if ~backoffTimer then
          backoffTimer := TRUE;
        end if;
      end if;
RExit:
      \* lastErr != nil: exit readTasksImpl
      readerExit();
    else
      readerExit();
    end if;
  end while;
end process;

\* The read-retry backoff timer (time.AfterFunc callback): clear the timer,
\* then maybeReadTasksLocked.
fair process timer = "timer"
begin
TimerLoop:
  while TRUE do
    await backoffTimer;
    backoffTimer := FALSE;
    if ~readPending /\ ShouldReadMore then
      readPending := TRUE;
    end if;
  end while;
end process;

\* taskWriterLoop/writeBatch: pin ack level, pick levels, write to db,
\* merge (or buffer) the written tasks, unpin.
fair process writer = "writer"
begin
WLoop:
  while TRUE do
    either
      \* getAndPinAckLevels + pickPasses: levels must be above the pinned
      \* ack level; ids are never reused
      with B \in WriteBatches do
        pinned     := TRUE;
        wrBatch    := B;
        usedLevels := usedLevels \cup B;
        wrState    := "req";
      end with;
WResp:
      await wrState = "resp";
      wrState := "idle";
      \* on success, wroteNewTasks -> mergeTasks(mergeWrite): if a read is
      \* pending, hold the tasks in newlyWrittenTasks (12e7c43a); else
      \* merge directly (this call site has the defensive stuck check).
      \* on error, wroteNewTasks is not called (the tasks may still be in
      \* the db -- incoming timeout).
      if wrOk then
        if readPending /\ ~MutNoWriteBuffering then
          newlyWritten := newlyWritten \cup wrBatch;
        else
          with expSel \in SUBSET wrBatch,
               r = MergeResult(loaded, ackedInMem, readLevel, ackLevel, atEnd,
                               wrBatch, MWrite, TRUE, expSel, evictedAcks)
          do
            applyMerge(r);
            committed := committed \ r.consumed;
            \* the defensive "fair reader stuck" check: record that it
            \* fired (ghost), and model its repair (maybeReadTasksLocked).
            \* NOTE: this state IS reachable in current code via a write
            \* of an already-expired task; see findings.md #3.
            stuckFlag := stuckFlag \/ (r.stuck /\ ~readPending /\ ~backoffTimer);
            if StuckRepair /\ r.stuck /\ ~readPending /\ ~backoffTimer then
              readPending := TRUE;
            end if;
          end with;
        end if;
      end if;
WUnpin:
      \* unpinAckLevel(writeErr) (separate critical section, via defer):
      \* on error, we can't assume we know where the end is anymore:
      \* reset atEnd and initiate a read to find the end again
      \* (8ca7b640 #5). Then clear the pin and advance the ack level
      \* (still pinned if a read is holding newlyWritten tasks).
      if ~wrOk then
        if ~MutNoAtEndResetOnWriteError then
          atEnd := FALSE;
        end if;
        if /\ ~MutNoReadOnWriteError
           /\ ~readPending /\ ~backoffTimer
           /\ ~(MutNoAtEndResetOnWriteError /\ atEnd)
           /\ LoadedCount <= ReloadAt
        then
          readPending := TRUE;
        end if;
      end if;
      pinned := FALSE;
      with clear = IF PinActive(newlyWritten /= {}) THEN {}
                   ELSE {c \in ackedInMem :
                           MutAckPastLoaded \/ \A m \in loaded : c < m}
      do
        ackedInMem := ackedInMem \ clear;
        if clear /= {} then
          ackLevel := SetMax(clear);
        end if;
      end with;
    or
      \* no more tasks will be written
      goto WDone;
    end either;
  end while;
WDone:
  skip;
end process;

\* The database, serving reads and writes concurrently. M2: all succeed.
fair process dbRead = "dbRead"
begin
DbReadLoop:
  while TRUE do
    await rdState = "req";
    either
      \* success
      rdResult := KeepLowest({l \in dbTasks : l >= rdFrom}, rdMax);
      rdOk     := TRUE;
    or
      \* timeout (reads have no side effects, so one error kind suffices)
      rdOk := FALSE;
    end either;
    rdState := "resp";
  end while;
end process;

fair process dbWrite = "dbWrite"
begin
DbWriteLoop:
  while TRUE do
    await wrState = "req";
    either
      \* success
      dbTasks   := dbTasks \cup wrBatch;
      everInDb  := everInDb \cup wrBatch;
      committed := committed \cup wrBatch;
      wrOk      := TRUE;
    or
      \* incoming timeout: the write applied, but the writer sees an error
      dbTasks  := dbTasks \cup wrBatch;
      everInDb := everInDb \cup wrBatch;
      wrOk     := FALSE;
    or
      \* outgoing timeout: the write did not apply
      wrOk := FALSE;
    end either;
    wrState := "resp";
  end while;
end process;

fair process dbGc = "dbGc"
begin
DbGcLoop:
  while TRUE do
    await gcState = "req";
    \* CompleteFairTasksLessThan(gcFrom.inc()): delete tasks <= gcFrom.
    \* The delete batch size limit is not modeled (it only splits the
    \* delete across calls; deletes are idempotent). The delete may time
    \* out on either side; GC ignores the result, so just: it may or may
    \* not apply.
    either
      with victims = {l \in dbTasks : l <= gcFrom} do
        dbTasks   := dbTasks \ victims;
        gcVictims := gcVictims \cup victims;
      end with;
    or
      skip;
    end either;
    gcState := "resp";
  end while;
end process;

\* GC: maybeGCLocked/doGC. Triggered nondeterministically whenever the ack
\* level has moved (the numToGC/time trigger conditions are abstracted to
\* "may run at any such time"). inGC (single outstanding GC) is implied by
\* this being one sequential process. Deliberately NOT fair: liveness must
\* not depend on GC running.
process gc = "gc"
begin
GcLoop:
  while TRUE do
    \* doGC captures ackLevel under lock, then calls the db unlocked
    await ackLevel > NoLevel;
    gcFrom  := IF MutGcReadLevel THEN readLevel ELSE ackLevel;
    gcState := "req";
GcResp:
    await gcState = "resp";
    gcState := "idle";
  end while;
end process;

\* The acker: eventually acks every loaded task, in any order.
\* One step = completeTaskLocked: mark acked, advanceAckLevelLocked,
\* maybeReadTasksLocked.
fair process acker = "acker"
begin
AckLoop:
  while TRUE do
    await loaded \cap AckableLevels /= {};
    with
      l     \in loaded \cap AckableLevels,
      ld    =   loaded \ {l},
      ackd  =   ackedInMem \cup {l},
      clear =   IF PinActive(pinned \/ newlyWritten /= {}) THEN {}
                ELSE {c \in ackd : MutAckPastLoaded \/ \A m \in ld : c < m}
    do
      loaded     := ld;
      ackedInMem := ackd \ clear;
      if clear /= {} then
        ackLevel := SetMax(clear);
      end if;
      ackedGhost := ackedGhost \cup {l};
      \* maybeReadTasksLocked (inlined with post-ack values)
      if ~readPending /\ ~atEnd /\ Cardinality(ld) <= ReloadAt /\ ~backoffTimer then
        readPending := TRUE;
      end if;
    end with;
  end while;
end process;

end algorithm; *)

\* BEGIN TRANSLATION
VARIABLES pc, dbTasks, rdState, rdFrom, rdMax, rdResult, rdOk, wrState, 
          wrBatch, wrOk, gcState, gcFrom, loaded, ackedInMem, readLevel, 
          ackLevel, atEnd, readPending, newlyWritten, pinned, evictedAcks, 
          backoffTimer, usedLevels, everInDb, committed, ackedGhost, 
          gcVictims, stuckFlag

(* define statement *)
Outstanding    == loaded \cup ackedInMem
LoadedCount    == Cardinality(loaded)

ShouldReadMore == ~atEnd /\ LoadedCount <= ReloadAt

AvailableLevels == {l \in Levels : l \notin usedLevels /\ l > ackLevel}
WriteBatches    == {B \in SUBSET AvailableLevels :
                      B /= {} /\ Cardinality(B) <= WBatchMax}


vars == << pc, dbTasks, rdState, rdFrom, rdMax, rdResult, rdOk, wrState, 
           wrBatch, wrOk, gcState, gcFrom, loaded, ackedInMem, readLevel, 
           ackLevel, atEnd, readPending, newlyWritten, pinned, evictedAcks, 
           backoffTimer, usedLevels, everInDb, committed, ackedGhost, 
           gcVictims, stuckFlag >>

ProcSet == {"reader"} \cup {"timer"} \cup {"writer"} \cup {"dbRead"} \cup {"dbWrite"} \cup {"dbGc"} \cup {"gc"} \cup {"acker"}

Init == (* Global variables *)
        /\ dbTasks \in SUBSET Levels
        /\ rdState = "idle"
        /\ rdFrom = NoLevel
        /\ rdMax = 0
        /\ rdResult = {}
        /\ rdOk = TRUE
        /\ wrState = "idle"
        /\ wrBatch = {}
        /\ wrOk = TRUE
        /\ gcState = "idle"
        /\ gcFrom = NoLevel
        /\ loaded = {}
        /\ ackedInMem = {}
        /\ readLevel = NoLevel
        /\ ackLevel = NoLevel
        /\ atEnd = FALSE
        /\ readPending = TRUE
        /\ newlyWritten = {}
        /\ pinned = FALSE
        /\ evictedAcks = {}
        /\ backoffTimer = FALSE
        /\ usedLevels = dbTasks
        /\ everInDb = dbTasks
        /\ committed = dbTasks
        /\ ackedGhost = {}
        /\ gcVictims = {}
        /\ stuckFlag = FALSE
        /\ pc = [self \in ProcSet |-> CASE self = "reader" -> "RWait"
                                        [] self = "timer" -> "TimerLoop"
                                        [] self = "writer" -> "WLoop"
                                        [] self = "dbRead" -> "DbReadLoop"
                                        [] self = "dbWrite" -> "DbWriteLoop"
                                        [] self = "dbGc" -> "DbGcLoop"
                                        [] self = "gc" -> "GcLoop"
                                        [] self = "acker" -> "AckLoop"]

RWait == /\ pc["reader"] = "RWait"
         /\ readPending
         /\ pc' = [pc EXCEPT !["reader"] = "RCheck"]
         /\ UNCHANGED << dbTasks, rdState, rdFrom, rdMax, rdResult, rdOk, 
                         wrState, wrBatch, wrOk, gcState, gcFrom, loaded, 
                         ackedInMem, readLevel, ackLevel, atEnd, readPending, 
                         newlyWritten, pinned, evictedAcks, backoffTimer, 
                         usedLevels, everInDb, committed, ackedGhost, 
                         gcVictims, stuckFlag >>

RCheck == /\ pc["reader"] = "RCheck"
          /\ IF ShouldReadMore
                THEN /\ rdFrom' = readLevel + 1
                     /\ rdMax' = BatchTarget - LoadedCount
                     /\ rdState' = "req"
                     /\ pc' = [pc EXCEPT !["reader"] = "RResp"]
                     /\ UNCHANGED << loaded, ackedInMem, readLevel, ackLevel, 
                                     atEnd, readPending, newlyWritten, 
                                     evictedAcks, committed >>
                ELSE /\ IF newlyWritten /= {}
                           THEN /\ \E expSel \in SUBSET newlyWritten:
                                     LET r == MergeResult(loaded, ackedInMem, readLevel, ackLevel, atEnd,
                                                          newlyWritten, MWrite, pinned, expSel, evictedAcks) IN
                                       /\ loaded' = r.loaded
                                       /\ ackedInMem' = r.acks
                                       /\ readLevel' = r.rl
                                       /\ ackLevel' = r.al
                                       /\ atEnd' = r.atEnd
                                       /\ evictedAcks' = r.cache
                                       /\ committed' = committed \ r.consumed
                                       /\ newlyWritten' = {}
                                       /\ readPending' = (/\ ~MutNoExitRecheck
                                                          /\ ~r.atEnd /\ Cardinality(r.loaded) <= ReloadAt
                                                          /\ ~backoffTimer)
                           ELSE /\ readPending' = (~MutNoExitRecheck /\ ShouldReadMore /\ ~backoffTimer)
                                /\ UNCHANGED << loaded, ackedInMem, readLevel, 
                                                ackLevel, atEnd, newlyWritten, 
                                                evictedAcks, committed >>
                     /\ pc' = [pc EXCEPT !["reader"] = "RWait"]
                     /\ UNCHANGED << rdState, rdFrom, rdMax >>
          /\ UNCHANGED << dbTasks, rdResult, rdOk, wrState, wrBatch, wrOk, 
                          gcState, gcFrom, pinned, backoffTimer, usedLevels, 
                          everInDb, ackedGhost, gcVictims, stuckFlag >>

RResp == /\ pc["reader"] = "RResp"
         /\ rdState = "resp"
         /\ rdState' = "idle"
         /\ IF rdOk
               THEN /\ \E expSel \in SUBSET rdResult:
                         LET mode == IF Cardinality(rdResult) < rdMax THEN MToEnd ELSE MMiddle IN
                           LET r == MergeResult(loaded, ackedInMem, readLevel, ackLevel, atEnd,
                                                rdResult, mode, pinned \/ newlyWritten /= {},
                                                expSel, evictedAcks) IN
                             /\ loaded' = r.loaded
                             /\ ackedInMem' = r.acks
                             /\ readLevel' = r.rl
                             /\ ackLevel' = r.al
                             /\ atEnd' = r.atEnd
                             /\ evictedAcks' = r.cache
                             /\ committed' = committed \ r.consumed
                    /\ pc' = [pc EXCEPT !["reader"] = "RCheck"]
                    /\ UNCHANGED backoffTimer
               ELSE /\ IF ~backoffTimer
                          THEN /\ backoffTimer' = TRUE
                          ELSE /\ TRUE
                               /\ UNCHANGED backoffTimer
                    /\ pc' = [pc EXCEPT !["reader"] = "RExit"]
                    /\ UNCHANGED << loaded, ackedInMem, readLevel, ackLevel, 
                                    atEnd, evictedAcks, committed >>
         /\ UNCHANGED << dbTasks, rdFrom, rdMax, rdResult, rdOk, wrState, 
                         wrBatch, wrOk, gcState, gcFrom, readPending, 
                         newlyWritten, pinned, usedLevels, everInDb, 
                         ackedGhost, gcVictims, stuckFlag >>

RExit == /\ pc["reader"] = "RExit"
         /\ IF newlyWritten /= {}
               THEN /\ \E expSel \in SUBSET newlyWritten:
                         LET r == MergeResult(loaded, ackedInMem, readLevel, ackLevel, atEnd,
                                              newlyWritten, MWrite, pinned, expSel, evictedAcks) IN
                           /\ loaded' = r.loaded
                           /\ ackedInMem' = r.acks
                           /\ readLevel' = r.rl
                           /\ ackLevel' = r.al
                           /\ atEnd' = r.atEnd
                           /\ evictedAcks' = r.cache
                           /\ committed' = committed \ r.consumed
                           /\ newlyWritten' = {}
                           /\ readPending' = (/\ ~MutNoExitRecheck
                                              /\ ~r.atEnd /\ Cardinality(r.loaded) <= ReloadAt
                                              /\ ~backoffTimer)
               ELSE /\ readPending' = (~MutNoExitRecheck /\ ShouldReadMore /\ ~backoffTimer)
                    /\ UNCHANGED << loaded, ackedInMem, readLevel, ackLevel, 
                                    atEnd, newlyWritten, evictedAcks, 
                                    committed >>
         /\ pc' = [pc EXCEPT !["reader"] = "RWait"]
         /\ UNCHANGED << dbTasks, rdState, rdFrom, rdMax, rdResult, rdOk, 
                         wrState, wrBatch, wrOk, gcState, gcFrom, pinned, 
                         backoffTimer, usedLevels, everInDb, ackedGhost, 
                         gcVictims, stuckFlag >>

reader == RWait \/ RCheck \/ RResp \/ RExit

TimerLoop == /\ pc["timer"] = "TimerLoop"
             /\ backoffTimer
             /\ backoffTimer' = FALSE
             /\ IF ~readPending /\ ShouldReadMore
                   THEN /\ readPending' = TRUE
                   ELSE /\ TRUE
                        /\ UNCHANGED readPending
             /\ pc' = [pc EXCEPT !["timer"] = "TimerLoop"]
             /\ UNCHANGED << dbTasks, rdState, rdFrom, rdMax, rdResult, rdOk, 
                             wrState, wrBatch, wrOk, gcState, gcFrom, loaded, 
                             ackedInMem, readLevel, ackLevel, atEnd, 
                             newlyWritten, pinned, evictedAcks, usedLevels, 
                             everInDb, committed, ackedGhost, gcVictims, 
                             stuckFlag >>

timer == TimerLoop

WLoop == /\ pc["writer"] = "WLoop"
         /\ \/ /\ \E B \in WriteBatches:
                    /\ pinned' = TRUE
                    /\ wrBatch' = B
                    /\ usedLevels' = (usedLevels \cup B)
                    /\ wrState' = "req"
               /\ pc' = [pc EXCEPT !["writer"] = "WResp"]
            \/ /\ pc' = [pc EXCEPT !["writer"] = "WDone"]
               /\ UNCHANGED <<wrState, wrBatch, pinned, usedLevels>>
         /\ UNCHANGED << dbTasks, rdState, rdFrom, rdMax, rdResult, rdOk, wrOk, 
                         gcState, gcFrom, loaded, ackedInMem, readLevel, 
                         ackLevel, atEnd, readPending, newlyWritten, 
                         evictedAcks, backoffTimer, everInDb, committed, 
                         ackedGhost, gcVictims, stuckFlag >>

WResp == /\ pc["writer"] = "WResp"
         /\ wrState = "resp"
         /\ wrState' = "idle"
         /\ IF wrOk
               THEN /\ IF readPending /\ ~MutNoWriteBuffering
                          THEN /\ newlyWritten' = (newlyWritten \cup wrBatch)
                               /\ UNCHANGED << loaded, ackedInMem, readLevel, 
                                               ackLevel, atEnd, readPending, 
                                               evictedAcks, committed, 
                                               stuckFlag >>
                          ELSE /\ \E expSel \in SUBSET wrBatch:
                                    LET r == MergeResult(loaded, ackedInMem, readLevel, ackLevel, atEnd,
                                                         wrBatch, MWrite, TRUE, expSel, evictedAcks) IN
                                      /\ loaded' = r.loaded
                                      /\ ackedInMem' = r.acks
                                      /\ readLevel' = r.rl
                                      /\ ackLevel' = r.al
                                      /\ atEnd' = r.atEnd
                                      /\ evictedAcks' = r.cache
                                      /\ committed' = committed \ r.consumed
                                      /\ stuckFlag' = (stuckFlag \/ (r.stuck /\ ~readPending /\ ~backoffTimer))
                                      /\ IF StuckRepair /\ r.stuck /\ ~readPending /\ ~backoffTimer
                                            THEN /\ readPending' = TRUE
                                            ELSE /\ TRUE
                                                 /\ UNCHANGED readPending
                               /\ UNCHANGED newlyWritten
               ELSE /\ TRUE
                    /\ UNCHANGED << loaded, ackedInMem, readLevel, ackLevel, 
                                    atEnd, readPending, newlyWritten, 
                                    evictedAcks, committed, stuckFlag >>
         /\ pc' = [pc EXCEPT !["writer"] = "WUnpin"]
         /\ UNCHANGED << dbTasks, rdState, rdFrom, rdMax, rdResult, rdOk, 
                         wrBatch, wrOk, gcState, gcFrom, pinned, backoffTimer, 
                         usedLevels, everInDb, ackedGhost, gcVictims >>

WUnpin == /\ pc["writer"] = "WUnpin"
          /\ IF ~wrOk
                THEN /\ IF ~MutNoAtEndResetOnWriteError
                           THEN /\ atEnd' = FALSE
                           ELSE /\ TRUE
                                /\ atEnd' = atEnd
                     /\ IF /\ ~MutNoReadOnWriteError
                           /\ ~readPending /\ ~backoffTimer
                           /\ ~(MutNoAtEndResetOnWriteError /\ atEnd')
                           /\ LoadedCount <= ReloadAt
                           THEN /\ readPending' = TRUE
                           ELSE /\ TRUE
                                /\ UNCHANGED readPending
                ELSE /\ TRUE
                     /\ UNCHANGED << atEnd, readPending >>
          /\ pinned' = FALSE
          /\ LET clear == IF PinActive(newlyWritten /= {}) THEN {}
                          ELSE {c \in ackedInMem :
                                  MutAckPastLoaded \/ \A m \in loaded : c < m} IN
               /\ ackedInMem' = ackedInMem \ clear
               /\ IF clear /= {}
                     THEN /\ ackLevel' = SetMax(clear)
                     ELSE /\ TRUE
                          /\ UNCHANGED ackLevel
          /\ pc' = [pc EXCEPT !["writer"] = "WLoop"]
          /\ UNCHANGED << dbTasks, rdState, rdFrom, rdMax, rdResult, rdOk, 
                          wrState, wrBatch, wrOk, gcState, gcFrom, loaded, 
                          readLevel, newlyWritten, evictedAcks, backoffTimer, 
                          usedLevels, everInDb, committed, ackedGhost, 
                          gcVictims, stuckFlag >>

WDone == /\ pc["writer"] = "WDone"
         /\ TRUE
         /\ pc' = [pc EXCEPT !["writer"] = "Done"]
         /\ UNCHANGED << dbTasks, rdState, rdFrom, rdMax, rdResult, rdOk, 
                         wrState, wrBatch, wrOk, gcState, gcFrom, loaded, 
                         ackedInMem, readLevel, ackLevel, atEnd, readPending, 
                         newlyWritten, pinned, evictedAcks, backoffTimer, 
                         usedLevels, everInDb, committed, ackedGhost, 
                         gcVictims, stuckFlag >>

writer == WLoop \/ WResp \/ WUnpin \/ WDone

DbReadLoop == /\ pc["dbRead"] = "DbReadLoop"
              /\ rdState = "req"
              /\ \/ /\ rdResult' = KeepLowest({l \in dbTasks : l >= rdFrom}, rdMax)
                    /\ rdOk' = TRUE
                 \/ /\ rdOk' = FALSE
                    /\ UNCHANGED rdResult
              /\ rdState' = "resp"
              /\ pc' = [pc EXCEPT !["dbRead"] = "DbReadLoop"]
              /\ UNCHANGED << dbTasks, rdFrom, rdMax, wrState, wrBatch, wrOk, 
                              gcState, gcFrom, loaded, ackedInMem, readLevel, 
                              ackLevel, atEnd, readPending, newlyWritten, 
                              pinned, evictedAcks, backoffTimer, usedLevels, 
                              everInDb, committed, ackedGhost, gcVictims, 
                              stuckFlag >>

dbRead == DbReadLoop

DbWriteLoop == /\ pc["dbWrite"] = "DbWriteLoop"
               /\ wrState = "req"
               /\ \/ /\ dbTasks' = (dbTasks \cup wrBatch)
                     /\ everInDb' = (everInDb \cup wrBatch)
                     /\ committed' = (committed \cup wrBatch)
                     /\ wrOk' = TRUE
                  \/ /\ dbTasks' = (dbTasks \cup wrBatch)
                     /\ everInDb' = (everInDb \cup wrBatch)
                     /\ wrOk' = FALSE
                     /\ UNCHANGED committed
                  \/ /\ wrOk' = FALSE
                     /\ UNCHANGED <<dbTasks, everInDb, committed>>
               /\ wrState' = "resp"
               /\ pc' = [pc EXCEPT !["dbWrite"] = "DbWriteLoop"]
               /\ UNCHANGED << rdState, rdFrom, rdMax, rdResult, rdOk, wrBatch, 
                               gcState, gcFrom, loaded, ackedInMem, readLevel, 
                               ackLevel, atEnd, readPending, newlyWritten, 
                               pinned, evictedAcks, backoffTimer, usedLevels, 
                               ackedGhost, gcVictims, stuckFlag >>

dbWrite == DbWriteLoop

DbGcLoop == /\ pc["dbGc"] = "DbGcLoop"
            /\ gcState = "req"
            /\ \/ /\ LET victims == {l \in dbTasks : l <= gcFrom} IN
                       /\ dbTasks' = dbTasks \ victims
                       /\ gcVictims' = (gcVictims \cup victims)
               \/ /\ TRUE
                  /\ UNCHANGED <<dbTasks, gcVictims>>
            /\ gcState' = "resp"
            /\ pc' = [pc EXCEPT !["dbGc"] = "DbGcLoop"]
            /\ UNCHANGED << rdState, rdFrom, rdMax, rdResult, rdOk, wrState, 
                            wrBatch, wrOk, gcFrom, loaded, ackedInMem, 
                            readLevel, ackLevel, atEnd, readPending, 
                            newlyWritten, pinned, evictedAcks, backoffTimer, 
                            usedLevels, everInDb, committed, ackedGhost, 
                            stuckFlag >>

dbGc == DbGcLoop

GcLoop == /\ pc["gc"] = "GcLoop"
          /\ ackLevel > NoLevel
          /\ gcFrom' = IF MutGcReadLevel THEN readLevel ELSE ackLevel
          /\ gcState' = "req"
          /\ pc' = [pc EXCEPT !["gc"] = "GcResp"]
          /\ UNCHANGED << dbTasks, rdState, rdFrom, rdMax, rdResult, rdOk, 
                          wrState, wrBatch, wrOk, loaded, ackedInMem, 
                          readLevel, ackLevel, atEnd, readPending, 
                          newlyWritten, pinned, evictedAcks, backoffTimer, 
                          usedLevels, everInDb, committed, ackedGhost, 
                          gcVictims, stuckFlag >>

GcResp == /\ pc["gc"] = "GcResp"
          /\ gcState = "resp"
          /\ gcState' = "idle"
          /\ pc' = [pc EXCEPT !["gc"] = "GcLoop"]
          /\ UNCHANGED << dbTasks, rdState, rdFrom, rdMax, rdResult, rdOk, 
                          wrState, wrBatch, wrOk, gcFrom, loaded, ackedInMem, 
                          readLevel, ackLevel, atEnd, readPending, 
                          newlyWritten, pinned, evictedAcks, backoffTimer, 
                          usedLevels, everInDb, committed, ackedGhost, 
                          gcVictims, stuckFlag >>

gc == GcLoop \/ GcResp

AckLoop == /\ pc["acker"] = "AckLoop"
           /\ loaded \cap AckableLevels /= {}
           /\ \E l \in loaded \cap AckableLevels:
                LET ld == loaded \ {l} IN
                  LET ackd == ackedInMem \cup {l} IN
                    LET clear == IF PinActive(pinned \/ newlyWritten /= {}) THEN {}
                                 ELSE {c \in ackd : MutAckPastLoaded \/ \A m \in ld : c < m} IN
                      /\ loaded' = ld
                      /\ ackedInMem' = ackd \ clear
                      /\ IF clear /= {}
                            THEN /\ ackLevel' = SetMax(clear)
                            ELSE /\ TRUE
                                 /\ UNCHANGED ackLevel
                      /\ ackedGhost' = (ackedGhost \cup {l})
                      /\ IF ~readPending /\ ~atEnd /\ Cardinality(ld) <= ReloadAt /\ ~backoffTimer
                            THEN /\ readPending' = TRUE
                            ELSE /\ TRUE
                                 /\ UNCHANGED readPending
           /\ pc' = [pc EXCEPT !["acker"] = "AckLoop"]
           /\ UNCHANGED << dbTasks, rdState, rdFrom, rdMax, rdResult, rdOk, 
                           wrState, wrBatch, wrOk, gcState, gcFrom, readLevel, 
                           atEnd, newlyWritten, pinned, evictedAcks, 
                           backoffTimer, usedLevels, everInDb, committed, 
                           gcVictims, stuckFlag >>

acker == AckLoop

Next == reader \/ timer \/ writer \/ dbRead \/ dbWrite \/ dbGc \/ gc
           \/ acker

Spec == /\ Init /\ [][Next]_vars
        /\ WF_vars(reader)
        /\ WF_vars(timer)
        /\ WF_vars(writer)
        /\ WF_vars(dbRead)
        /\ WF_vars(dbWrite)
        /\ WF_vars(dbGc)
        /\ WF_vars(acker)

\* END TRANSLATION

---------------------------------------------------------------------------
(* Fairness *)

(* The acker step that acks specifically level l. *)
AckOf(l) == AckLoop /\ l \in loaded /\ l \notin loaded'

(* Weak fairness on the acker process is not enough: if a task is evicted,
   re-read, and re-delivered in a cycle, WF lets the acker ack only the
   re-delivered task forever and starve another loaded task. The intended
   assumption (see plan.md) is that every loaded task is eventually acked,
   which is per-level strong fairness. *)
AckerFairness == \A l \in AckableLevels : SF_vars(AckOf(l))

(* "The network eventually stops timing out": strong fairness on read
   success -- if reads are attempted infinitely often, they succeed
   infinitely often. Write/GC success fairness is NOT assumed: recovery
   from write errors must be reader-driven, and liveness must not depend
   on GC at all. *)
DbReadSuccess == DbReadLoop /\ rdState = "req" /\ rdState' = "resp" /\ rdOk'

FairSpec == Spec /\ AckerFairness /\ SF_vars(DbReadSuccess)

---------------------------------------------------------------------------
(* Invariants *)

TypeInv ==
  /\ loaded \subseteq Levels
  /\ ackedInMem \subseteq Levels
  /\ loaded \cap ackedInMem = {}
  /\ ackLevel \in NoLevel..MaxLevel
  /\ readLevel \in NoLevel..MaxLevel
  /\ newlyWritten \subseteq Levels
  /\ wrBatch \subseteq Levels
  /\ dbTasks \subseteq everInDb
  /\ everInDb \subseteq usedLevels
  /\ committed \subseteq everInDb
  /\ evictedAcks \subseteq Levels

\* the evicted-ack cache is bounded, and a cache entry for a still-committed
\* task must be genuinely acked -- else a cache hit would fabricate an ack
\* and let the ack level skip a live task. (Cache entries for non-committed
\* levels are fine: nil entries of expired-consumed tasks and of orphans
\* acked after an incidental re-read also flow into the cache.)
CacheBounded   == Cardinality(evictedAcks) <= EvictedCacheMax
CacheOnlyAcked == (evictedAcks \cap committed) \subseteq ackedGhost

\* in-memory entries are exactly within (ackLevel, readLevel]
MemWindow == \A l \in loaded \cup ackedInMem : ackLevel < l /\ l <= readLevel

AckBelowRead == ackLevel <= readLevel

LoadedInDb == loaded \subseteq dbTasks /\ newlyWritten \subseteq dbTasks

LoadedBounded == Cardinality(loaded) <= BatchTarget

\* Safety: the ack level never passes a committed task that was not acked.
\* (Tasks from timed-out writes carry no guarantee: the caller re-submits.
\* Tasks consumed as expired leave the committed set at merge time.)
NoAckSkipped ==
  \A l \in committed : (l <= ackLevel) => (l \in ackedGhost)

\* While a write is in flight, the pin keeps the ack level below all levels
\* being written (else the merge would drop them / GC could delete them).
\* Ditto for written tasks held in newlyWrittenTasks during a read.
PinProtectsWrites ==
  /\ pinned => \A l \in wrBatch : l > ackLevel
  /\ \A l \in newlyWritten : l > ackLevel

\* Safety: a committed task is never deleted from the database unless it
\* was acked. ("Even worse than getting stuck: a restart fixes stuck, not
\* deleted.") Orphans from timed-out writes and tasks consumed as expired
\* (both out of the committed set) may be GC'd unacked.
GCOnlyAcked == (gcVictims \cap committed) \subseteq ackedGhost

\* The defensive "fair reader stuck" condition (see mergeTasks in
\* fair_task_reader.go). NOT an invariant of the current code: it is
\* reachable via a write of an already-expired task (findings.md #3), and
\* the check's repair (a triggered read) is what rescues the reader. Not
\* in the default cfg; run.sh uses it to (a) demonstrate finding #3 on the
\* real model and (b) catch historical bugs with StuckRepair=FALSE.
NoStuck == ~stuckFlag

---------------------------------------------------------------------------
(* Temporal properties *)

AckLevelMonotonic == [][ackLevel' >= ackLevel]_vars

\* Liveness: every committed task is eventually acked (tasks consumed as
\* expired leave the committed set and are exempt).
AllTasksAcked == <>(\A l \in committed : l \in ackedGhost)

\* Liveness: the reader eventually learns it drained the whole queue
\* (isDrained) and stays that way. Implies the reader never gets stuck.
EventuallyDrained == <>[](atEnd /\ loaded = {})

\* The reader eventually stops issuing reads. Not checked on the default
\* config (implied by EventuallyDrained there); checked with a restricted
\* acker (AckableLevels < Levels: some task never completes) to expose the
\* finding-1 busy re-read churn: an empty read-to-end merge lowers
\* readLevel to max(loaded), evicting acks above it, forcing atEnd=false
\* and an endless re-read cycle while the lowest task stays unacked.
ReaderQuiesce == <>[](rdState = "idle" /\ ~readPending /\ ~backoffTimer)

===========================================================================
