// Test drivers for the fair queue model.

machine TestDriver {
  start state Init {
    entry {
      var db: machine;
      var reader: machine;
      var acker: machine;
      var writer: machine;
      var timer: machine;
      var hop: machine;

      // up to 3 injected db timeouts per run
      db = new Database(3);
      timer = new BackoffTimer();
      hop = new Hop();
      // batchSize 2, reload when <= 1 loaded: forces multiple read batches,
      // full-buffer merges, and evictions with few tasks
      // cacheSize 1: tiny evicted-acks cache so trimming is exercised
      reader = new FairReader((db = db, timer = timer, hop = hop, batchSize = 2, reloadAt = 1, cacheSize = 1, initLevel = 0));
      acker = new Acker(reader);
      writer = new FairWriter((db = db, reader = reader, numTasks = 4, maxLevel = 10));
      send reader, eBindAcker, acker;
    }
  }
}

// Bigger instance: more tasks, wider level universe, larger buffer.
machine TestDriverBig {
  start state Init {
    entry {
      var db: machine;
      var reader: machine;
      var acker: machine;
      var writer: machine;
      var timer: machine;
      var hop: machine;

      db = new Database(4);
      timer = new BackoffTimer();
      hop = new Hop();
      reader = new FairReader((db = db, timer = timer, hop = hop, batchSize = 3, reloadAt = 1, cacheSize = 1, initLevel = 0));
      acker = new Acker(reader);
      writer = new FairWriter((db = db, reader = reader, numTasks = 6, maxLevel = 12));
      send reader, eBindAcker, acker;
    }
  }
}

// No evicted-ack cache; every evicted ack forces a re-read + re-dispatch.
machine TestDriverNoCache {
  start state Init {
    entry {
      var db: machine;
      var reader: machine;
      var acker: machine;
      var writer: machine;
      var timer: machine;
      var hop: machine;

      db = new Database(3);
      timer = new BackoffTimer();
      hop = new Hop();
      reader = new FairReader((db = db, timer = timer, hop = hop, batchSize = 2, reloadAt = 1, cacheSize = 0, initLevel = 0));
      acker = new Acker(reader);
      writer = new FairWriter((db = db, reader = reader, numTasks = 5, maxLevel = 10));
      send reader, eBindAcker, acker;
    }
  }
}

// Lazy reload: only read when the buffer is completely empty.
machine TestDriverLazy {
  start state Init {
    entry {
      var db: machine;
      var reader: machine;
      var acker: machine;
      var writer: machine;
      var timer: machine;
      var hop: machine;

      db = new Database(3);
      timer = new BackoffTimer();
      hop = new Hop();
      reader = new FairReader((db = db, timer = timer, hop = hop, batchSize = 2, reloadAt = 0, cacheSize = 1, initLevel = 0));
      acker = new Acker(reader);
      writer = new FairWriter((db = db, reader = reader, numTasks = 5, maxLevel = 10));
      send reader, eBindAcker, acker;
    }
  }
}

test tcFairQueue [main = TestDriver]:
  assert GuaranteedDelivery, NoLostTask in
    { TestDriver, Database, FairReader, FairWriter, Acker, BackoffTimer, Hop };

// Churn check, kept separate from the green regression suite: this FAILS on
// the current code (finding #3 in findings.md, the busy re-read loop).
// Only PEx reaches it: p check -tc tcChurn --mode pex --sch-pex dfs
test tcChurn [main = TestDriver]:
  assert BoundedRedispatch in
    { TestDriver, Database, FairReader, FairWriter, Acker, BackoffTimer, Hop };

test tcBig [main = TestDriverBig]:
  assert GuaranteedDelivery, NoLostTask in
    { TestDriverBig, Database, FairReader, FairWriter, Acker, BackoffTimer, Hop };

test tcNoCache [main = TestDriverNoCache]:
  assert GuaranteedDelivery, NoLostTask in
    { TestDriverNoCache, Database, FairReader, FairWriter, Acker, BackoffTimer, Hop };

test tcLazy [main = TestDriverLazy]:
  assert GuaranteedDelivery, NoLostTask in
    { TestDriverLazy, Database, FairReader, FairWriter, Acker, BackoffTimer, Hop };
