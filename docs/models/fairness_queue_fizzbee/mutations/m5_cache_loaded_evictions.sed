# base: m5.fizz
# Bug class (hypothetical, guards the cache's key precondition): the two
# eviction categories get conflated and evicted LOADED (never-dispatched)
# tasks are also remembered in the evicted-ack cache. A later re-read then
# pre-acks a task that was never dispatched — silently losing it.
# Expected: CacheOnlyHoldsAcked (immediately), or AckLevelOnlyPassesAcked /
# liveness if that guard assertion is removed.
s/^            outstanding.pop(t)$/            outstanding.pop(t)\n            evicted_acks.add(t)  # MUTATION: cache never-dispatched evictions too/
