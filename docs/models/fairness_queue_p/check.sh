#!/usr/bin/env bash
# Run the P checker over the strategy portfolio.
# Usage: ./check.sh [testcase] [schedules]
set -e
cd "$(dirname "$0")"
tc=${1:-tcFairQueue}
s=${2:-20000}
p compile | tail -1
for st in "--sch-random" "--sch-pct 10" "--sch-feedbackpct 20" "--sch-random --fail-on-maxsteps"; do
  echo "== $tc $st -s $s =="
  p check -tc "$tc" -s "$s" $st | grep -E 'Found [0-9]+ bug|buggy|Elapsed' || true
done
