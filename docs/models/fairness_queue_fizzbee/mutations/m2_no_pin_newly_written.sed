# base: m2.fizz
# Bug class: ackLevelPinnedLocked must also count held newlyWrittenTasks
# (the write's own pin is released right after the merge buffered the tasks;
# if the ack level can advance before the buffered tasks are processed, the
# late merge drops them as below-ack and they are never dispatched).
# Expected: safety failure (AckLevelOnlyPassesAcked / WindowComplete).
s/^    return pinned_by_writer or len(newly_written) > 0$/    return pinned_by_writer  # MUTATION: ignore held newlyWrittenTasks/
