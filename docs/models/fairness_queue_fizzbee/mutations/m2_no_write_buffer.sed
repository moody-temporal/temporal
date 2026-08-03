# base: m2.fizz
# Bug 12e7c43a: writes that complete while a read is pending were merged
# immediately instead of being buffered until the read finishes; the merge
# uses a readLevel/atEnd snapshot that the in-flight read is about to
# invalidate, dropping tasks that should have ended up in memory.
# Expected: liveness failure (task in DB above readLevel with atEnd true) or
# WindowComplete violation.
s/^    if read_state != RS.IDLE:$/    if False:  # MUTATION: pre-12e7c43a, never buffer newlyWrittenTasks/
