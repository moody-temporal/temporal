#!/usr/bin/env bash
# Mutation testing harness: apply each mutation in mutations/, compile, run
# the checker, and expect a bug. Restores the source afterwards.
# Usage: ./mutate.sh [mutation ids...]   (default: all)
set -u
cd "$(dirname "$0")"
src=PSrc/FairQueue.p
schedules=20000
# M8a is expected NOT CAUGHT (documents an abstraction boundary, see
# mutations.md) and is excluded from the default set.
ids=${@:-$(ls mutations/*.old | sed 's|.*/||;s|\.old$||' | grep -v '^M8a$' | sort)}
fail=0

for m in $ids; do
  cp "$src" "$src.orig"
  OLD=$(cat "mutations/$m.old") NEW=$(cat "mutations/$m.new") \
    perl -0777 -pi -e 's/\Q$ENV{OLD}\E/$ENV{NEW}/' "$src"
  if cmp -s "$src" "$src.orig"; then
    echo "$m: PATTERN NOT FOUND (model changed? update mutations/$m.old)"
    rm "$src.orig"; fail=1; continue
  fi
  if ! p compile >/dev/null 2>&1; then
    echo "$m: COMPILE FAILED"
    mv "$src.orig" "$src"; fail=1; continue
  fi
  caught=""
  for st in "--sch-random" "--sch-feedbackpct 20"; do
    out=$(p check -tc tcFairQueue -s $schedules $st 2>&1 | grep -oE 'Found 1 bug')
    if [ -n "$out" ]; then caught="$st"; break; fi
  done
  if [ -n "$caught" ]; then
    why=$(grep -m1 'ErrorLog' PCheckerOutput/BugFinding/FairQueue_0_0.txt 2>/dev/null \
          | sed 's/<ErrorLog> //' | cut -c1-100)
    echo "$m: caught ($caught) -- $why"
  else
    echo "$m: NOT CAUGHT"
    fail=1
  fi
  mv "$src.orig" "$src"
done

p compile >/dev/null 2>&1 # leave a clean build behind
exit $fail
