# base: m5.fizz
# Synthetic (8ca7b640 #1): mergeTasksLocked stops ignoring tasks at-or-below
# the ack level. In the current structure reads always start at readLevel
# >= ackLevel and writes are pinned above it, so this filter may be
# unreachable belt-and-braces — this mutation documents whether the model
# can distinguish it. If NOT caught, that is itself information: the filter
# guards against races the current model (and possibly the current code)
# cannot produce.
# Expected: possibly not caught (documented); harm would be re-delivering
# an already-acked task below the ack level (MemoryInWindow).
s/^        if t <= ack_level:$/        if False:  # MUTATION: no below-ack filter in merge/
