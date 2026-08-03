// Specs for the fair queue model.

// NoLostTask (safety): the database never deletes a CONFIRMED task that
// hasn't been completed. GC only deletes <= ackLevel, and ackLevel is only
// supposed to cover completed tasks (ack level pinning protects in-flight
// writes); this checks that end to end.
//
// Tasks from timed-out writes carry no delivery guarantee (the caller sees an
// error and retries), so an unconfirmed task may be deleted uncompleted. A
// confirmation arriving after such a deletion would still be a real loss, so
// check both directions.
// BoundedRedispatch (safety proxy for churn): re-dispatch of the same level
// is legitimate a few times (evict + re-read), but an unbounded loop of
// dispatch/ack/evict/re-read is the "busy churn" failure mode. K = 10 is far
// above anything a legitimate schedule needs at these instance sizes.
spec BoundedRedispatch observes eTaskDispatched {
  var count: map[int, int];

  start state Monitoring {
    on eTaskDispatched do (lvl: int) {
      if (!(lvl in count)) {
        count[lvl] = 0;
      }
      count[lvl] = count[lvl] + 1;
      assert count[lvl] <= 10,
        format("task {0} dispatched {1} times: churn loop", lvl, count[lvl]);
    }
  }
}

// An expired task is treated as completed by both specs: expiry discharges
// the delivery obligation.
spec NoLostTask observes eTaskConfirmed, eTaskCompleted, eTaskDeleted, eTaskExpired {
  var confirmed: set[int];
  var completed: set[int];
  var deleted: set[int];

  start state Monitoring {
    on eTaskConfirmed do (lvl: int) {
      confirmed += (lvl);
      assert !(lvl in deleted) || lvl in completed,
        format("task {0} confirmed after uncompleted deletion", lvl);
    }
    on eTaskCompleted do (lvl: int) {
      completed += (lvl);
    }
    on eTaskExpired do (lvl: int) {
      completed += (lvl);
    }
    on eTaskDeleted do (lvl: int) {
      deleted += (lvl);
      assert !(lvl in confirmed) || lvl in completed,
        format("task {0} deleted before completion", lvl);
    }
  }
}

// GuaranteedDelivery (liveness): every task whose write was confirmed to the
// writer is eventually completed (acked) by the reader. Hot while any
// confirmed task is un-acked; a schedule that ends hot is a liveness bug
// (covers both lost tasks and a stuck reader).
//
// A task can be completed before the writer sees the write confirmation (a
// concurrent read can load it while the write response is still in flight),
// and eviction/re-read races can complete the same level more than once, so
// track ever-completed levels.
spec GuaranteedDelivery observes eTaskConfirmed, eTaskCompleted, eTaskExpired {
  var pending: set[int];   // confirmed but not yet completed
  var completed: set[int]; // ever completed

  start cold state AllCompleted {
    on eTaskConfirmed do (lvl: int) {
      handleConfirmed(lvl);
      if (sizeof(pending) > 0) {
        goto PendingCompletion;
      }
    }
    on eTaskCompleted do (lvl: int) {
      handleCompleted(lvl);
    }
    on eTaskExpired do (lvl: int) {
      handleCompleted(lvl);
    }
  }

  hot state PendingCompletion {
    on eTaskConfirmed do (lvl: int) {
      handleConfirmed(lvl);
    }
    on eTaskCompleted do (lvl: int) {
      handleCompleted(lvl);
      if (sizeof(pending) == 0) {
        goto AllCompleted;
      }
    }
    on eTaskExpired do (lvl: int) {
      handleCompleted(lvl);
      if (sizeof(pending) == 0) {
        goto AllCompleted;
      }
    }
  }

  fun handleConfirmed(lvl: int) {
    if (!(lvl in completed)) {
      pending += (lvl);
    }
  }

  fun handleCompleted(lvl: int) {
    completed += (lvl);
    if (lvl in pending) {
      pending -= (lvl);
    }
  }
}
