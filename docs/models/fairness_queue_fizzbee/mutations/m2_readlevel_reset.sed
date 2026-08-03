# base: m2.fizz
# Bug f534e74e: mergeTasksLocked collapsed readLevel to ackLevel when the
# merged set was empty (no loaded tasks, only acks). A read racing a write
# can load + ack the just-written task before the write's own merge runs;
# the write's merge then sees an empty merged set, resets readLevel, evicts
# all acks, sets atEnd=false — and with nothing loaded, nothing ever
# triggers another read.
# Expected: NeverDetectsStuck (the softassert state) and/or liveness failure.
s/^    # else: merged is empty, leave read_level unchanged (fix f534e74e)$/    else:\n        read_level = ack_level  # MUTATION: pre-f534e74e behavior/
