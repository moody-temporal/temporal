// P model of service/matching/fair_task_{reader,writer}.go
// (full model: milestones M1-M8, see plan.md)
//
//  - Database, Writer, Reader, Acker as separate machines.
//  - Writer picks nondeterministic unique levels above the pinned ack level,
//    possibly below the reader's readLevel, in batches of 1-2.
//  - Ack level pinning during writes (getAndPinAckLevel / unpinAckLevel).
//  - Full mergeTasksLocked semantics: merged set of loaded + incoming tasks,
//    keep first batchSize, eviction of loaded tasks and of acks above the new
//    readLevel, readLevel left alone when the merged set is empty (f534e74e),
//    newlyWrittenTasks held while a read is pending (12e7c43a).
//  - Acker stands in for matcher + pollers; eviction can race an in-flight
//    completion, so completions for missing/already-acked tasks are no-ops.
//  - GC deletes <= ackLevel, triggered nondeterministically after acks.
//  - DB ops can time out (bounded budget), on the outgoing side (op not
//    performed) or incoming side (op performed, response lost). Reads retry
//    via a backoff timer whose firing races the read loop tail (26d9a561);
//    failed writes surface to the caller, which retries with fresh levels,
//    and clear atEnd + kick a read on unpin (8ca7b640 #5).
//
// Levels are single unique integers (abstracting the <pass, id> fair level).
// Level 0 is the initial ack/read level; real tasks have level >= 1.

enum tMergeMode { MERGE_READ_MIDDLE, MERGE_READ_TO_END, MERGE_WRITE }

// ---- events ----

// Writer <-> Database (CreateFairTasks)
event eWriteTasksReq: (writer: machine, tasks: seq[int]);
event eWriteTasksResp: seq[int];
event eWriteTasksErr: seq[int]; // timed out: applied or not, writer can't tell

// Reader <-> Database (GetFairTasks): return up to `count` tasks with level > gtLevel
event eGetTasksReq: (reader: machine, gtLevel: int, count: int);
event eGetTasksResp: seq[int];
// Database internal: a computed read result that hasn't been delivered yet.
// Models the window in Go between the db computing a read result and the
// reader merging it (the reader lock is not held during the db call): without
// this hop, P's atomic send + FIFO queues would deliver read results to the
// reader before any eWroteTasks from later db operations, hiding real races.
event eReadServed: (reader: machine, tasks: seq[int]);
event eGetTasksErr; // read timed out (reads are idempotent, no applied/not distinction)

// Writer <-> Reader: getAndPinAckLevel / wroteNewTasks / unpinAckLevel
event eGetPinReq: machine;
event ePinResp: int;
event eWroteTasks: seq[int];
event eUnpin: bool; // payload: did the write fail?

// Reader -> Acker (addTaskToMatcher / setEvicted) and Acker -> Reader (completeTask).
// Loads carry a per-delivery instance id and are routed through the Hop
// machine, because Go adds tasks to the matcher OUTSIDE the reader lock: an
// eviction (setEvicted, under the lock) can happen before the matcher add
// runs (ad717eae). Evictions go direct. Completions are by level, matching
// completeTask's lookup.
event eHopTaskLoaded: (target: machine, lvl: int, id: int);
event eTaskLoaded: (lvl: int, id: int);
event eTaskEvicted: (lvl: int, id: int);
event eAckTask: int;
event eAckKick;

// Reader <-> Database (CompleteFairTasksLessThan): delete tasks <= upTo
event eGcReq: (reader: machine, upTo: int);
event eGcResp;
event eGcErr; // timed out: applied or not

// Backoff timer for read retries (retryReadAfter). A separate machine so its
// firing races other events.
event eStartBackoff: machine;
event eBackoffFired;

// The tail of readTasksImpl after a read error (readPending=false, process
// newlyWritten, final maybeRead). Bounced through the Hop machine so the
// backoff timer can fire before it, like a goroutine losing the race for the
// lock (26d9a561); a direct self-send would always beat the timer.
event eHopLoopDone: machine;
event eReadLoopDone;

// Driver -> Reader (to close the Reader <-> Acker reference cycle)
event eBindAcker: machine;

// announcements for spec monitors
event eTaskConfirmed: int; // writer observed a successful write of this level
event eTaskCompleted: int; // reader marked this level acked (completeTask)
event eTaskDeleted: int;   // db deleted this level (GC)
event eTaskExpired: int;   // reader saw this level expired at merge time
event eTaskDispatched: int; // reader handed this level to the matcher

// ---- database ----

machine Database {
  var tasks: seq[int];   // sorted ascending
  var failuresLeft: int; // budget of injected timeouts (bounds retry loops)

  start state Serving {
    entry (maxFailures: int) {
      failuresLeft = maxFailures;
    }

    on eWriteTasksReq do (req: (writer: machine, tasks: seq[int])) {
      var i: int;
      var outcome: int;
      outcome = pickOutcome();
      if (outcome != 1) {
        // applied (success or incoming timeout)
        i = 0;
        while (i < sizeof(req.tasks)) {
          insertTask(req.tasks[i]);
          i = i + 1;
        }
      }
      if (outcome == 0) {
        send req.writer, eWriteTasksResp, req.tasks;
      } else {
        send req.writer, eWriteTasksErr, req.tasks;
      }
    }

    on eGetTasksReq do (req: (reader: machine, gtLevel: int, count: int)) {
      var res: seq[int];
      var i: int;
      if (pickOutcome() != 0) {
        send req.reader, eGetTasksErr;
        return;
      }
      i = 0;
      while (i < sizeof(tasks) && sizeof(res) < req.count) {
        if (tasks[i] > req.gtLevel) {
          res += (sizeof(res), tasks[i]);
        }
        i = i + 1;
      }
      send this, eReadServed, (reader = req.reader, tasks = res);
    }

    on eReadServed do (r: (reader: machine, tasks: seq[int])) {
      send r.reader, eGetTasksResp, r.tasks;
    }

    // GC: delete everything <= upTo (Cassandra range-delete semantics; the
    // SQL batch-limited variant only deletes less, which is strictly safer)
    on eGcReq do (req: (reader: machine, upTo: int)) {
      var outcome: int;
      outcome = pickOutcome();
      if (outcome != 1) {
        while (sizeof(tasks) > 0 && tasks[0] <= req.upTo) {
          announce eTaskDeleted, tasks[0];
          tasks -= (0);
        }
      }
      if (outcome == 0) {
        send req.reader, eGcResp;
      } else {
        send req.reader, eGcErr;
      }
    }
  }

  // 0 = success; 1 = outgoing timeout (op not performed); 2 = incoming
  // timeout (op performed, response lost). The caller sees 1 and 2
  // identically.
  fun pickOutcome(): int {
    if (failuresLeft > 0 && choose()) {
      failuresLeft = failuresLeft - 1;
      if (choose()) {
        return 1;
      }
      return 2;
    }
    return 0;
  }

  fun insertTask(lvl: int) {
    var i: int;
    i = 0;
    while (i < sizeof(tasks) && tasks[i] < lvl) {
      i = i + 1;
    }
    assert i == sizeof(tasks) || tasks[i] != lvl, "duplicate task level written";
    tasks += (i, lvl);
  }
}

// ---- reader (fairTaskReader) ----

machine FairReader {
  var db: machine;
  var acker: machine;
  var timer: machine; // backoff timer for read retries
  var hop: machine;   // scheduling-delay hop for the read-error loop tail
  var batchSize: int; // GetTasksBatchSize
  var reloadAt: int;  // GetTasksReloadAt: read more when loaded <= reloadAt
  var cacheSize: int; // evictedAcksCacheSize

  var outstanding: map[int, bool]; // level -> acked? (false = loaded, true = acked/nil)
  var loaded: int;                 // number of unacked entries in outstanding
  var readLevel: int;              // we have (ackLevel, readLevel] in outstanding
  var ackLevel: int;               // inclusive: task at ackLevel has been acked
  var atEnd: bool;                 // outstanding covers the whole queue right now
  var readPending: bool;           // a read is in flight
  var lastReqCount: int;           // batch size of the in-flight read
  var newlyWritten: seq[int];      // tasks written while readPending
  var pinnedByWriter: bool;        // ackLevelPinnedByWriter
  var backoffTimer: bool;          // a read-retry backoff timer is armed

  // gc state
  var inGC: bool;
  var numToGC: int;

  // levels this reader has observed as expired (IsTaskExpired is monotone:
  // once a task's expiry has passed, every later check also sees it expired)
  var knownExpired: set[int];

  // acked levels that were evicted from outstanding before they could advance
  // ackLevel; consulted on re-read to avoid re-dispatching completed tasks
  var evictedAcks: set[int];

  // per-delivery instance ids (an evicted + re-read task is a new instance)
  var deliverySeq: int;
  var deliveryId: map[int, int]; // level -> id of currently tracked instance

  start state Init {
    entry (cfg: (db: machine, timer: machine, hop: machine, batchSize: int, reloadAt: int, cacheSize: int, initLevel: int)) {
      db = cfg.db;
      timer = cfg.timer;
      hop = cfg.hop;
      batchSize = cfg.batchSize;
      reloadAt = cfg.reloadAt;
      cacheSize = cfg.cacheSize;
      readLevel = cfg.initLevel;
      ackLevel = cfg.initLevel;
    }
    on eBindAcker do (a: machine) {
      acker = a;
      goto Running;
    }
    // the writer may start before we're bound
    defer eWroteTasks;
    defer eGetPinReq;
  }

  state Running {
    entry {
      maybeRead(); // Start()
    }

    // one batch of readTasksImpl's loop
    on eGetTasksResp do (batch: seq[int]) {
      var reachedEnd: bool;
      reachedEnd = sizeof(batch) < lastReqCount;
      if (reachedEnd) {
        mergeTasks(batch, MERGE_READ_TO_END);
      } else {
        mergeTasks(batch, MERGE_READ_MIDDLE);
      }
      if (shouldReadMore()) {
        sendRead(); // loop again; readPending stays true
      } else {
        readPending = false;
        // process tasks that were written while the read was pending; note
        // sizeof(newlyWritten) > 0 keeps the ack level pinned during the merge
        if (sizeof(newlyWritten) > 0) {
          mergeTasks(newlyWritten, MERGE_WRITE);
          newlyWritten = default(seq[int]);
          advanceAckLevel();
        }
        // re-check before finishing (the 26d9a561 fix; trivial until we model
        // the backoff timer, but keep the structure)
        maybeRead();
      }
    }

    // read timed out: retryReadAfter, then the rest of readTasksImpl runs as
    // a separately-scheduled step (eReadLoopDone via the hop)
    on eGetTasksErr do {
      if (!backoffTimer) {
        backoffTimer = true;
        send timer, eStartBackoff, this;
      }
      send hop, eHopLoopDone, this;
    }

    // the tail of readTasksImpl after a failed read
    on eReadLoopDone do {
      readPending = false;
      if (sizeof(newlyWritten) > 0) {
        mergeTasks(newlyWritten, MERGE_WRITE);
        newlyWritten = default(seq[int]);
        advanceAckLevel();
      }
      // re-check before finishing, in case the backoff timer already fired
      // while readPending was still true (the 26d9a561 fix)
      maybeRead();
    }

    on eBackoffFired do {
      backoffTimer = false;
      maybeRead();
    }

    // wroteNewTasks -> mergeTasks(mergeWrite)
    on eWroteTasks do (batch: seq[int]) {
      var i: int;
      if (readPending) {
        i = 0;
        while (i < sizeof(batch)) {
          newlyWritten += (sizeof(newlyWritten), batch[i]);
          i = i + 1;
        }
        return;
      }
      mergeTasks(batch, MERGE_WRITE);
      if (loaded == 0 && !atEnd && !readPending && !backoffTimer) {
        // Go's "fair reader stuck" detector: softassert + repair read.
        // FINDING (see findings.md): this state is reachable -- a write of an
        // already-expired task below readLevel while the buffer holds only
        // acks -- so the softassert fires spuriously and the "defensive" read
        // is actually load-bearing. It should NOT be reachable any other way,
        // which this assertion checks (and which keeps mutation sensitivity
        // for non-expiry bugs like f534e74e).
        assert sizeof(knownExpired) > 0, "fair reader stuck without expired tasks";
        maybeRead();
      }
    }

    // getAndPinAckLevel
    on eGetPinReq do (w: machine) {
      assert !pinnedByWriter, "ack level already pinned";
      pinnedByWriter = true;
      send w, ePinResp, ackLevel;
    }

    // unpinAckLevel
    on eUnpin do (hadErr: bool) {
      if (hadErr) {
        // the write may have taken effect anyway: we can't assume we know
        // where the end is anymore, and must initiate a read to find it
        // (8ca7b640 #5)
        atEnd = false;
        maybeRead();
      }
      assert pinnedByWriter, "ack level wasn't pinned";
      pinnedByWriter = false;
      advanceAckLevel();
    }

    // doGC completed (Cassandra: everything <= upTo is gone)
    on eGcResp do {
      inGC = false;
      numToGC = 0;
    }

    // doGC failed; keep numToGC so a later trigger retries
    on eGcErr do {
      inGC = false;
    }

    // completeTask
    on eAckTask do (lvl: int) {
      if (!(lvl in outstanding)) {
        // the task was evicted while this completion was in flight; it will be
        // re-read and re-dispatched later (Go: TaskCompletedMissing)
        return;
      }
      if (outstanding[lvl]) {
        // Completion for a task that is already marked acked. Go softasserts
        // "completed task was already acked" here, but this is reachable with
        // no bug (finding #2, see findings.md): an in-flight completion can
        // land after the same level was evicted and re-read as expired (or
        // re-dispatched and completed). Modeled as the no-op Go performs.
        return;
      }
      outstanding[lvl] = true;
      loaded = loaded - 1;
      assert loaded >= 0, "loadedTasks went negative";
      announce eTaskCompleted, lvl;
      advanceAckLevel();
      maybeRead();
      checkInvariants();
    }
  }

  // mergeTasksLocked
  fun mergeTasks(incoming: seq[int], mode: tMergeMode) {
    var merged: seq[int]; // sorted: unacked loaded levels + accepted new levels
    var isNew: set[int];  // subset of merged not yet in outstanding
    var ks: seq[int];
    var i: int;
    var lvl: int;
    var kept: int; // how many of merged we keep in memory
    var evictedAny: bool;

    // (1) currently loaded (unacked) tasks
    ks = keys(outstanding);
    i = 0;
    while (i < sizeof(ks)) {
      if (!outstanding[ks[i]]) {
        merged = insertSorted(merged, ks[i]);
      }
      i = i + 1;
    }

    // (2) the tasks we just read/wrote
    i = 0;
    while (i < sizeof(incoming)) {
      lvl = incoming[i];
      if (lvl <= ackLevel) {
        // reads may race with acks; ignore tasks already acked
      } else if (mode == MERGE_WRITE && !atEnd && lvl > readLevel) {
        // writing while not at the end: we don't know what's between
        // readLevel and lvl, so ignore tasks above readLevel
      } else if (lvl in outstanding) {
        // already have it (loaded or acked); ignore
      } else {
        assert !(lvl in isNew), "duplicate level in merge batch";
        merged = insertSorted(merged, lvl);
        isNew += (lvl);
      }
      i = i + 1;
    }

    // keep the first batchSize of the merged set
    kept = sizeof(merged);
    if (kept > batchSize) {
      kept = batchSize;
    }
    if (kept > 0) {
      // if we have any tasks at all in memory, readLevel is the max of that set
      readLevel = merged[kept - 1];
    }
    // else: merged is empty (only acks in memory); leave readLevel unchanged
    // (f534e74e: collapsing it to ackLevel would evict all acks and strand the
    // reader)

    // evict whatever doesn't fit: loaded tasks are removed from memory and the
    // matcher; new tasks are simply not taken (they stay in the db)
    evictedAny = false;
    i = kept;
    while (i < sizeof(merged)) {
      lvl = merged[i];
      evictedAny = true;
      if (!(lvl in isNew)) {
        outstanding -= (lvl);
        loaded = loaded - 1;
        // setEvicted: direct (under the reader lock), so it can beat the
        // matcher add for the same instance, which goes through the hop
        send acker, eTaskEvicted, (lvl = lvl, id = deliveryId[lvl]);
      }
      i = i + 1;
    }

    // also evict acked (nil) entries above the new readLevel, otherwise we'd
    // use them to jump the ack level across ranges we just dropped; cache
    // them so a re-read can skip re-dispatching (trim highest levels first)
    ks = keys(outstanding);
    i = 0;
    while (i < sizeof(ks)) {
      if (outstanding[ks[i]] && ks[i] > readLevel) {
        outstanding -= (ks[i]);
        evictedAcks += (ks[i]);
        evictedAny = true;
      }
      i = i + 1;
    }
    while (sizeof(evictedAcks) > cacheSize) {
      evictedAcks -= (maxOf(evictedAcks));
    }

    // take the new tasks that made the cut
    i = 0;
    while (i < kept) {
      lvl = merged[i];
      if (lvl in isNew) {
        if (lvl in evictedAcks) {
          // already completed, but the ack was evicted before it could
          // advance ackLevel and we re-read the task: re-insert it as a
          // pre-acked entry instead of re-dispatching. Remove from the cache
          // since it's tracked in outstanding again. (Its level made the
          // in-memory cut, so the ack eviction above can't have touched it.)
          evictedAcks -= (lvl);
          outstanding[lvl] = true;
        } else if (isExpired(lvl)) {
          // expired: add as pre-acked (nil) so it advances readLevel (it
          // already participated in the cut above) and ackLevel + GC below,
          // instead of being dispatched (0b372d5e)
          outstanding[lvl] = true;
          announce eTaskExpired, lvl;
        } else {
          outstanding[lvl] = false;
          loaded = loaded + 1;
          deliverySeq = deliverySeq + 1;
          deliveryId[lvl] = deliverySeq;
          announce eTaskDispatched, lvl;
          // addTaskToMatcher happens outside the reader lock: route via hop
          send hop, eHopTaskLoaded, (target = acker, lvl = lvl, id = deliverySeq);
        }
      }
      i = i + 1;
    }

    // pre-acked entries may now be at the bottom (no-op until M5/M6; also
    // normally pinned during writes)
    advanceAckLevel();

    // update atEnd
    if (mode == MERGE_READ_MIDDLE || evictedAny) {
      atEnd = false;
    } else if (mode == MERGE_READ_TO_END) {
      atEnd = true;
    }
    // on write: leave unchanged

    checkInvariants();
  }

  // IsTaskExpired at merge time: nondeterministic, but monotone per level
  fun isExpired(lvl: int): bool {
    if (lvl in knownExpired) {
      return true;
    }
    if (choose()) {
      knownExpired += (lvl);
      return true;
    }
    return false;
  }

  fun insertSorted(s: seq[int], v: int): seq[int] {
    var i: int;
    i = 0;
    while (i < sizeof(s) && s[i] < v) {
      i = i + 1;
    }
    assert i == sizeof(s) || s[i] != v, "insertSorted: duplicate";
    s += (i, v);
    return s;
  }

  fun ackLevelPinned(): bool {
    return pinnedByWriter || sizeof(newlyWritten) > 0;
  }

  fun advanceAckLevel() {
    var mn: int;
    var moving: bool;
    var numAcked: int;
    if (ackLevelPinned()) {
      return;
    }
    moving = true;
    while (moving && sizeof(outstanding) > 0) {
      mn = minKey();
      if (outstanding[mn]) {
        ackLevel = mn;
        outstanding -= (mn);
        numAcked = numAcked + 1;
      } else {
        moving = false;
      }
    }
    if (numAcked > 0) {
      numToGC = numToGC + numAcked;
      maybeGC();
    }
  }

  // maybeGCLocked: Go triggers on a count threshold or elapsed time; both are
  // abstracted into a nondeterministic choice
  fun maybeGC() {
    if (inGC || numToGC == 0) {
      return;
    }
    if (choose()) {
      inGC = true;
      send db, eGcReq, (reader = this, upTo = ackLevel);
    }
  }

  fun maxOf(s: set[int]): int {
    var v: int;
    var mx: int;
    mx = -1;
    foreach (v in s) {
      if (v > mx) {
        mx = v;
      }
    }
    return mx;
  }

  fun minKey(): int {
    var ks: seq[int];
    var i: int;
    var mn: int;
    ks = keys(outstanding);
    mn = ks[0];
    i = 1;
    while (i < sizeof(ks)) {
      if (ks[i] < mn) {
        mn = ks[i];
      }
      i = i + 1;
    }
    return mn;
  }

  fun shouldReadMore(): bool {
    if (atEnd) {
      return false;
    }
    if (loaded > reloadAt) {
      return false;
    }
    return true;
  }

  fun maybeRead() {
    if (readPending || backoffTimer || !shouldReadMore()) {
      return;
    }
    readPending = true;
    sendRead();
  }

  fun sendRead() {
    lastReqCount = batchSize - loaded;
    assert lastReqCount > 0, "read batch size must be positive";
    send db, eGetTasksReq, (reader = this, gtLevel = readLevel, count = lastReqCount);
  }

  fun checkInvariants() {
    var ks: seq[int];
    var i: int;
    var cnt: int;
    assert ackLevel <= readLevel, "ackLevel above readLevel";
    ks = keys(outstanding);
    i = 0;
    cnt = 0;
    while (i < sizeof(ks)) {
      assert ks[i] > ackLevel, format("outstanding level {0} <= ackLevel {1}", ks[i], ackLevel);
      assert ks[i] <= readLevel, format("outstanding level {0} > readLevel {1}", ks[i], readLevel);
      if (!outstanding[ks[i]]) {
        cnt = cnt + 1;
      }
      i = i + 1;
    }
    assert cnt == loaded, "loaded count mismatch";
  }
}

// ---- writer (fairTaskWriter) ----

machine FairWriter {
  var db: machine;
  var reader: machine;
  var numTasks: int; // total tasks to write
  var maxLevel: int; // level universe is 1..maxLevel
  var used: set[int]; // levels ever allocated (task ids are never reused)
  var written: int;

  start state Writing {
    entry (cfg: (db: machine, reader: machine, numTasks: int, maxLevel: int)) {
      db = cfg.db;
      reader = cfg.reader;
      numTasks = cfg.numTasks;
      maxLevel = cfg.maxLevel;
      startWrite();
    }

    // writeBatch: pin ack level, pick levels above it, write
    on ePinResp do (pinnedAck: int) {
      var candidates: seq[int];
      var batch: seq[int];
      var target: int;
      var lvl: int;
      var i: int;

      candidates = default(seq[int]);
      lvl = pinnedAck + 1;
      while (lvl <= maxLevel) {
        if (!(lvl in used)) {
          candidates += (sizeof(candidates), lvl);
        }
        lvl = lvl + 1;
      }

      target = 1 + choose(2); // batch of 1 or 2 (getWriteBatch)
      if (target > numTasks - written) {
        target = numTasks - written;
      }
      while (sizeof(batch) < target && sizeof(candidates) > 0) {
        i = choose(sizeof(candidates));
        lvl = candidates[i];
        candidates -= (i);
        used += (lvl);
        batch += (sizeof(batch), lvl);
      }

      if (sizeof(batch) == 0) {
        // no usable levels left (level universe exhausted): stop writing
        send reader, eUnpin, false;
        return;
      }
      written = written + sizeof(batch);
      send db, eWriteTasksReq, (writer = this, tasks = batch);
    }

    on eWriteTasksResp do (batch: seq[int]) {
      var i: int;
      i = 0;
      while (i < sizeof(batch)) {
        announce eTaskConfirmed, batch[i];
        i = i + 1;
      }
      // wroteNewTasks must be called before unpin
      send reader, eWroteTasks, batch;
      send reader, eUnpin, false;
      startWrite();
    }

    // write timed out: the error propagates to the caller, which retries
    // AddTask from scratch; the retry allocates fresh task ids (levels)
    on eWriteTasksErr do (batch: seq[int]) {
      written = written - sizeof(batch);
      send reader, eUnpin, true;
      startWrite();
    }
  }

  fun startWrite() {
    if (written >= numTasks) {
      return;
    }
    send reader, eGetPinReq, this;
  }
}

// ---- helper machines: backoff timer and scheduling-delay hop ----

// Backoff timer for read retries. Firing takes two hops (reader -> timer ->
// reader), so it races the read-error loop tail, which also takes two hops.
machine BackoffTimer {
  start state Idle {
    on eStartBackoff do (target: machine) {
      send target, eBackoffFired;
    }
  }
}

// Bounces events that Go performs outside the reader lock, modeling goroutine
// scheduling delay: the read-error loop tail, and matcher adds (which can
// therefore lose a race against an eviction of the same instance, ad717eae).
machine Hop {
  start state Idle {
    on eHopLoopDone do (target: machine) {
      send target, eReadLoopDone;
    }
    on eHopTaskLoaded do (t: (target: machine, lvl: int, id: int)) {
      send t.target, eTaskLoaded, (lvl = t.lvl, id = t.id);
    }
  }
}

// ---- acker (stands in for matcher + poller: eventually completes every loaded task) ----

machine Acker {
  var reader: machine;
  var pending: set[(lvl: int, id: int)];
  // instances evicted before their matcher add arrived (the setEvicted flag,
  // ad717eae): the late add must be a no-op
  var evictedEarly: set[(lvl: int, id: int)];

  start state Acking {
    entry (r: machine) {
      reader = r;
    }
    on eTaskLoaded do (t: (lvl: int, id: int)) {
      if (t in evictedEarly) {
        // this instance was evicted before it reached the matcher
        evictedEarly -= (t);
        return;
      }
      pending += (t);
      send this, eAckKick; // one kick per task: everything acks eventually
    }
    on eTaskEvicted do (t: (lvl: int, id: int)) {
      if (t in pending) {
        pending -= (t);
      } else {
        // either the matcher add hasn't arrived yet (tombstone it), or this
        // instance already matched and its completion is in flight (the
        // reader will treat that completion as missing/already-acked); a
        // stale tombstone is harmless since instance ids are never reused
        evictedEarly += (t);
      }
    }
    on eAckKick do {
      var t: (lvl: int, id: int);
      if (sizeof(pending) == 0) {
        return; // its task was evicted or acked by an earlier kick
      }
      t = choose(pending);
      pending -= (t);
      send reader, eAckTask, t.lvl;
    }
  }
}
