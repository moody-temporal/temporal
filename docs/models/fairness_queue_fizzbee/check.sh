#!/usr/bin/env bash
# Run the FizzBee model checker with a memory cap so a large state space
# cannot take down the machine (the checker is killed by its cgroup's OOM
# killer instead of pushing the desktop into swap).
#
# Usage: ./check.sh spec.fizz [timeout-seconds]
#   MEMMAX=16G ./check.sh m5.fizz     # override the default 32G cap
set -u
spec="$1"
tmo="${2:-5400}"
shift; [ $# -gt 0 ] && shift
exec systemd-run --user --quiet --scope \
    -p MemoryMax="${MEMMAX:-32G}" -p MemorySwapMax=0 \
    timeout "$tmo" fizz --experimental_processed_queue "$@" "$spec"
