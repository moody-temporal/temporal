# base: m3.fizz
# Bug 0b372d5e: expired tasks were dropped by the reader before
# mergeTasksLocked instead of being passed through as pre-acked entries.
# A batch of entirely expired tasks then never advances readLevel, and the
# reader re-reads the same expired range forever — tasks beyond it are
# never dispatched.
# Expected: liveness failure (AllConfirmedTasksAcked).
s/^    tasks = read_resp\[0\]$/    tasks = [t for t in read_resp[0] if t not in expired]  # MUTATION: pre-0b372d5e, drop expired before merge/
