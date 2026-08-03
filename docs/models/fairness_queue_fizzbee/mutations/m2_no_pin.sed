# base: m2.fizz
# Bug class: fairness.md "Problems / Ack level movement while a write is in
# flight". Without pinning, the ack level can advance while a write is in
# flight, and GC can then delete the just-written tasks (or the merge drops
# them as below-ack), losing them forever.
# Expected: safety failure (NoUnackedTaskDeleted / AckLevelOnlyPassesAcked /
# WindowComplete) or liveness failure.
s/^    return pinned_by_writer or len(newly_written) > 0$/    return False  # MUTATION: ack level never pinned/
