# base: m4.fizz
# Bug 26d9a561: readTasksImpl did not re-check maybeReadTasksLocked after
# setting readPending = false. If the backoff timer fires while readPending
# is still true, its maybeReadTasksLocked call is a no-op, and when the loop
# then finishes nothing ever restarts the read: the reader is stuck.
# Expected: liveness failure (AllConfirmedTasksAcked).
s/^        maybe_read()$/        pass  # MUTATION: pre-26d9a561, no re-check after readPending=false/
