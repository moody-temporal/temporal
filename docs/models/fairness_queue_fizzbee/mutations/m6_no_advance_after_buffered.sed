# base: m5.fizz
# Synthetic: readTasksImpl forgets to call advanceAckLevelLocked after
# processing newlyWrittenTasks. The merge itself can't advance (the ack
# level is pinned by the still-nonempty newlyWrittenTasks), so if the
# buffered tasks merge as pre-acked (expired / cached ack) and nothing else
# is loaded, no completeTask ever runs and the ack level is stuck forever.
# Expected: liveness failure (AllConfirmedTasksAcked).
s/^            advance_ack()$/            pass  # MUTATION: no advance after processing newlyWrittenTasks/
