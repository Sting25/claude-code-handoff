#!/usr/bin/env bash
# The /handoff SKILL.md carries three load-bearing curation disciplines that
# are model-followed guidance, not script behavior, so they can't be exercised
# by running a binary. This test is their contract: it guards them against a
# future edit silently deleting them.
#
#   1. Garbage-collect inherited lessons — triage each carried-forward caution
#      as Settled (graduate into a permanent home, drop), Still live (carry),
#      or Stale (drop).
#   2. The handoff should trend smaller, not grow monotonically.
#   3. State claims are written as checks, not verdicts (proof-not-conclusion).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

skill="$REPO_ROOT/skills/handoff/SKILL.md"

has() { grep -qiF -- "$2" "$1" && echo yes || echo no; }

check "SKILL.md exists"                       yes "$([[ -f "$skill" ]] && echo yes || echo no)"
check "GC triage: Settled lessons graduate"   yes "$(has "$skill" "**Settled**")"
check "GC triage: Still live lessons carried" yes "$(has "$skill" "**Still live**")"
check "GC triage: Stale lessons dropped"      yes "$(has "$skill" "**Stale**")"
check "trend-smaller principle present"       yes "$(has "$skill" "trend")"
check "trend-smaller names monotonic growth"  yes "$(has "$skill" "monotonic growth")"
check "proof-not-conclusion guidance present" yes "$(has "$skill" "checks, not verdicts")"

finish
