# base: m1.fizz
# Bug class: missing read trigger after tasks drain (generic stuckness).
# completeTaskLocked stops calling maybeReadTasksLocked, so once the buffer
# drains with readPending false, nothing ever starts a read again.
# Expected: liveness failure (AllConfirmedTasksAcked).
/^    advance_ack()$/{
N
s/^    advance_ack()\n    maybe_read()$/    advance_ack()\n    # MUTATION: completeTaskLocked does not trigger a read/
}
