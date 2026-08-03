# base: m4.fizz
# Bug 8ca7b640 #5 (historical form): after a failed write, atEnd is set to
# false, but nothing initiates a read; if the buffer is empty there will
# never be a completeTask call to trigger one, and newly written tasks above
# the read level are discarded by merge — reader stuck. At the time this bug
# existed the defensive "fair reader stuck" backstop did not exist either,
# so this mutation removes both.
# Expected: liveness failure (AllConfirmedTasksAcked).
/^    at_end = False$/{
N
s/^    at_end = False\n    maybe_read()$/    at_end = False\n    pass  # MUTATION: pre-8ca7b640#5, no read trigger in unpin(err)/
}
s/^            maybe_read()$/            pass  # MUTATION: no defensive backstop read (did not exist yet)/
