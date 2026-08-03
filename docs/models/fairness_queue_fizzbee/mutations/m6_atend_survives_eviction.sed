# base: m5.fizz
# Synthetic: atEnd is not reset when tasks are evicted from memory. Evicted
# tasks live only in the DB below atEnd's horizon; with atEnd stuck true the
# reader never reads again and the evicted tasks are never re-dispatched.
# Expected: liveness failure (AllConfirmedTasksAcked).
s/^    if mode == MODE_MIDDLE or evicted_any:$/    if mode == MODE_MIDDLE:  # MUTATION: eviction does not reset atEnd/
