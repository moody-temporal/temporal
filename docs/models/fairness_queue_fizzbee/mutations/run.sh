#!/usr/bin/env bash
# Mutation-test runner for the fairness queue FizzBee models.
#
# Each mutation is a <name>.sed file applied to a base model (named in the
# first line comment: "# base: m1.fizz"). A mutation "passes" (i.e. the model
# is sensitive to it) when the checker reports FAILED.
#
# Usage: ./run.sh [mutation-name ...]   (default: all)

set -u
cd "$(dirname "$0")"

fail=0
for mut in "${@:-$(ls *.sed 2>/dev/null | sed 's/\.sed$//')}"; do
    mut="${mut%.sed}"
    base=$(sed -n 's/^# base: //p' "$mut.sed" | head -1)
    if [[ -z "$base" ]]; then echo "SKIP $mut: no '# base:' line"; continue; fi
    tmp=$(mktemp -d)
    sed -f "$mut.sed" "../$base" > "$tmp/$mut.fizz"
    if diff -q "../$base" "$tmp/$mut.fizz" >/dev/null; then
        echo "BAD  $mut: sed script made no change"; fail=1; rm -rf "$tmp"; continue
    fi
    # memory-capped, one at a time (see ../check.sh)
    out=$(cd "$tmp" && systemd-run --user --quiet --scope \
        -p MemoryMax="${MEMMAX:-32G}" -p MemorySwapMax=0 \
        timeout "${MUT_TIMEOUT:-5400}" fizz "$mut.fizz" 2>&1)
    if echo "$out" | grep -q "FAILED"; then
        reason=$(echo "$out" | grep -E "^(FAILED|Invariant)" | tr '\n' ' ')
        echo "OK   $mut: caught ($reason)"
    else
        echo "BAD  $mut: NOT caught (model checker passed or errored)"
        echo "$out" | tail -5 | sed 's/^/     /'
        fail=1
    fi
    rm -rf "$tmp"
done
exit $fail
