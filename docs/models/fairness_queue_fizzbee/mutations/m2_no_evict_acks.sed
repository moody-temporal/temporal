# base: m2.fizz
# Bug 8ca7b640 #4: when tasks are evicted because new tasks were inserted
# under them, acked (nil) entries above the new readLevel must also be
# evicted, otherwise those stale acks let the ack level jump across the
# dropped (still unprocessed) range.
# Expected: MemoryInWindow violation (stale ack above readLevel), possibly
# escalating to AckLevelOnlyPassesAcked with larger write batches.
s/^    for t in \[l for l in outstanding if outstanding\[l\] == ACKED and l > read_level\]:$/    for t in []:  # MUTATION: pre-8ca7b640#4, keep acks above read level/
