#!/usr/bin/env bash
# Coverage for issue #131: a trimmed fallback load could hide the current
# doc's git state entirely.
#
# Root cause: the output budget (see test_ss_output_budget.sh) trims
# narrative regions by priority, lowest first, and the current doc's whole
# region (priority 3) has always outranked LOWER than the placeholder
# fallback's curated history snapshot (priority 4). On a tight budget the
# trimmer could zero out the current doc's entire region — HEAD, branch, and
# recent commits included — before the fallback lost a single byte. Measured
# live on a real repo: "trimmed 2746 of 2746 bytes" from the current doc's
# section, so the model got no git state at all, only the trim notice.
#
# Fix: handoff_session_start.sh now extracts a short, capped git-state head
# (the "## Repo:" line, HEAD, Branch, and up to 5 Recent-commits lines) from
# the current doc into its OWN region with the highest trim priority in use
# (git_head_priority=9, trimmed last of everything narrative), stripped out
# of the main current-doc region so it is never duplicated.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SS="$REPO_ROOT/bin/handoff_session_start.sh"
SENTINEL='<!-- HANDOFF_PLACEHOLDER: keep until /handoff replaces this block -->'

has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
bytes() { printf '%s' "$1" | LC_ALL=C wc -c | tr -d ' '; }
le() { [ "$1" -le "$2" ] && echo yes || echo no; }
count_of() {  # <text> <fixed string> -> occurrence count
  printf '%s\n' "$1" | grep -oF -- "$2" | wc -l | tr -d ' '
}
run_ss() {  # <dir> [ENV=VAL ...]
  local dir="$1"; shift
  ( cd "$dir" && env CLAUDE_PROJECT_DIR="$dir" HANDOFF_SECRET_FILE="$dir/.secret" \
      HANDOFF_NO_HEALTH_WARN=1 "$@" bash "$SS" </dev/null 2>/dev/null )
}

# A placeholder current doc (git-state only, no curated Notes) with a REAL
# git snapshot in write_handoff.sh's own format, so extract_git_head's state
# machine sees the real shape it is written against.
mk_current_placeholder() {  # <dir>
  local d="$1"
  mkdir -p "$d/.claude" || return 1
  {
    echo "# handoff: session handoff (auto-generated)"
    echo
    echo "**Generated:** 2026-09-22 12:00 UTC"
    echo
    echo "---"
    echo
    echo "## Repo: fixture"
    echo
    # shellcheck disable=SC2016  # backticks are literal markdown code spans, not command substitution
    printf '**HEAD:** `%s` — %s\n\n' \
      "$(git -C "$d" rev-parse --short HEAD)" "$(git -C "$d" log -1 --pretty=%s)"
    # shellcheck disable=SC2016  # backticks are literal markdown code spans, not command substitution
    printf '**Branch:** `%s` (main)\n\n' "$(git -C "$d" rev-parse --abbrev-ref HEAD)"
    echo "### Recent commits"
    echo
    echo '```'
    git -C "$d" log --oneline -10
    echo '```'
    echo
    echo "### Working tree"
    echo
    echo "_clean_"
    echo
    echo "## Notes from this session"
    echo
    echo "$SENTINEL"
  } > "$d/.claude/handoff_current.md"
}

# A large CURATED fallback snapshot in handoff_history/, named to match the
# writer's rotation shape so handoff_newest_curated_history_snapshot picks
# it up. Big enough on its own to force trimming once combined with anything
# else in the load.
mk_fallback_curated() {  # <dir> <filler lines>
  local d="$1" n="$2" i
  mkdir -p "$d/.claude/handoff_history" || return 1
  {
    echo "# handoff: session handoff (auto-generated)"
    echo
    echo "## Notes from this session"
    echo
    echo "FALLBACK_NOTE_HEAD curated prose starts here."
    for ((i = 1; i <= n; i++)); do
      echo "FALLBACK_FILLER line $i: curated prose padding to force a trim of this load."
    done
    echo "FALLBACK_NOTE_TAIL curated prose ends here."
  } > "$d/.claude/handoff_history/handoff_2026-01-01_000000.md"
}

echo "SessionStart: protected git-state head survives a trimmed fallback (issue #131)"

# --- (a) Fallback case: large curated history snapshot + placeholder current
#     doc with a real git snapshot. HEAD and at least the first recent commit
#     must survive, the whole load must stay within budget, and the
#     fallback's own curated head must still be there too. -------------------
p1="$(mk_repo)" || exit 1
cleanup_on_exit "$p1"
# A second commit so "recent commits" has more than one line to check against.
must bash -c "echo more >> '$p1/seed.txt' && git -C '$p1' add seed.txt && git -C '$p1' commit -qm 'second commit'"
head_short="$(git -C "$p1" rev-parse --short HEAD)"
first_commit_line="$(git -C "$p1" log --oneline -1)"
must mk_current_placeholder "$p1"
must mk_fallback_curated "$p1" 300

out="$(run_ss "$p1")"
check "fallback -> within 9000 bytes"        yes "$(le "$(bytes "$out")" 9000)"
check "fallback -> HEAD sha present"         yes "$(has "$out" "$head_short")"
check "fallback -> first recent commit present" yes "$(has "$out" "$first_commit_line")"
check "fallback -> HEAD line printed once"   1   "$(count_of "$out" '**HEAD:**')"
check "fallback -> fallback notes head survives" yes "$(has "$out" FALLBACK_NOTE_HEAD)"

# --- (a2) Same shape, but with long commit subjects so the protected head
#     region itself is bigger than the trimmer's fixed 240-byte-plus-path
#     per-region reserve (below that reserve a region is never trimmed at
#     all, priority or not — see the "res" check in handoff_session_start.sh's
#     ss_awk). This is the case that actually exercises git_head_priority:
#     a small everyday repo's head never gets near that reserve, so without
#     this fixture the priority number could regress to anything low and
#     every other check above would still pass (confirmed by hand: mutating
#     git_head_priority to 0 does not fail case (a) above, only this one).
p1b="$(mk_repo)" || exit 1
cleanup_on_exit "$p1b"
long_subj="Really long commit subject line to inflate the git-state head past the trim reserve threshold, number"
for n in 1 2 3; do
  echo "change$n" >> "$p1b/seed.txt"
  must git -C "$p1b" add seed.txt
  must git -C "$p1b" commit -qm "$long_subj $n"
done
head_short_b="$(git -C "$p1b" rev-parse --short HEAD)"
first_commit_line_b="$(git -C "$p1b" log --oneline -1)"
must mk_current_placeholder "$p1b"
must mk_fallback_curated "$p1b" 300
out="$(run_ss "$p1b")"
check "fallback (large head) -> within 9000 bytes"     yes "$(le "$(bytes "$out")" 9000)"
check "fallback (large head) -> HEAD sha present"      yes "$(has "$out" "$head_short_b")"
check "fallback (large head) -> first recent commit present" yes "$(has "$out" "$first_commit_line_b")"
check "fallback (large head) -> fallback notes head survives" yes "$(has "$out" FALLBACK_NOTE_HEAD)"

# --- (b) Normal curated case: unchanged in substance — a small, fully
#     curated current doc loads whole, HEAD/branch/commits appear once (no
#     duplication from the new protected-head region), no trim notice. ------
p2="$(mk_repo)" || exit 1
cleanup_on_exit "$p2"
head_short2="$(git -C "$p2" rev-parse --short HEAD)"
mkdir -p "$p2/.claude" || exit 1
must bash -c "cat > '$p2/.claude/handoff_current.md'" <<EOF
# handoff: session handoff (auto-generated)

**Generated:** 2026-09-22 12:00 UTC

---

## Repo: fixture

**HEAD:** \`$head_short2\` — $(git -C "$p2" log -1 --pretty=%s)

**Branch:** \`$(git -C "$p2" rev-parse --abbrev-ref HEAD)\` (main)

### Recent commits

\`\`\`
$(git -C "$p2" log --oneline -10)
\`\`\`

### Working tree

_clean_

## Notes from this session

CURATED_NOTE_HEAD curated prose starts here.
CURATED_NOTE_TAIL curated prose ends here.
EOF
out="$(run_ss "$p2")"
check "curated -> no trim notice"          no  "$(has "$out" 'trimmed')"
check "curated -> notes survive"           yes "$(has "$out" CURATED_NOTE_TAIL)"
check "curated -> HEAD present"            yes "$(has "$out" "$head_short2")"
check "curated -> HEAD line printed once"  1   "$(count_of "$out" '**HEAD:**')"
check "curated -> Branch line printed once" 1  "$(count_of "$out" '**Branch:**')"

# --- (c) Tiny budget: no crash, and either within budget or the documented
#     over-budget notice is shown. --------------------------------------
p3="$(mk_repo)" || exit 1
cleanup_on_exit "$p3"
must mk_current_placeholder "$p3"
must mk_fallback_curated "$p3" 300
out="$(run_ss "$p3" HANDOFF_SS_MAX_BYTES=1500)"
rc=$?
check "tiny budget -> loader exits 0"      0   "$rc"
tiny_ok=no
[ "$(le "$(bytes "$out")" 1500)" = yes ] && tiny_ok=yes
[ "$(has "$out" 'still over the')" = yes ] && tiny_ok=yes
check "tiny budget -> within budget or documented over-budget notice" yes "$tiny_ok"
check "tiny budget -> produced some output" yes "$([ -n "$out" ] && echo yes || echo no)"

# --- (d) UNVERIFIED path (emit_untrusted), review finding F3: a "## Repo:"
#     line pasted inside Notes (e.g. quoted troubleshooting output) must not
#     hijack the git-head strip's extraction state machine. emit_untrusted
#     used to run its `strip_git_head` filter AFTER hoist_notes, i.e. on a
#     stream where Notes (containing the pasted block) had already been moved
#     to the FRONT, so strip_git_head's "first ## Repo: line wins" scan hit
#     the pasted block first instead of the doc's real snapshot section:
#       - the pasted block, shaped exactly like a real snapshot (## Repo: /
#         **HEAD:** / **Branch:** / ### Recent commits / fenced commits),
#         fully matched and was SILENTLY DELETED (strip mode never prints a
#         completed match).
#       - the doc's OWN real snapshot section, now positioned after Notes in
#         the hoisted stream, was never reached (the state machine only
#         starts looking from state 0, and abandons/succeeds exactly once),
#         so it survived unstripped in the narrative, duplicating the
#         protected head's own copy of the real HEAD line.
#     Fix: the filter now runs on the RAW file before hoist_notes, matching
#     the verified path's own order, so it only ever sees the doc's real
#     top-of-file snapshot section, never text quoted inside Notes.
p4="$(mk_repo)" || exit 1
cleanup_on_exit "$p4"
real_sha="$(git -C "$p4" rev-parse --short HEAD)"
real_subj="$(git -C "$p4" log -1 --pretty=%s)"
real_branch="$(git -C "$p4" rev-parse --abbrev-ref HEAD)"
mkdir -p "$p4/.claude" || exit 1
must bash -c "cat > '$p4/.claude/handoff_current.md'" <<EOF
# handoff: session handoff (auto-generated)

**Generated:** 2026-09-22 12:00 UTC

---

## Repo: fixture

**HEAD:** \`$real_sha\` - $real_subj

**Branch:** \`$real_branch\` (main)

### Recent commits

\`\`\`
$(git -C "$p4" log --oneline -10)
\`\`\`

### Working tree

_clean_

## Notes from this session

PASTED_MARKER_BEFORE quoted troubleshooting output follows:

## Repo: fake

**HEAD:** \`deadbee\` - fake pasted subject

**Branch:** \`main\` (nothing)

### Recent commits

\`\`\`
fake commit line
\`\`\`

PASTED_MARKER_AFTER end of quoted output. CURATED_TAIL_D real curated prose.
EOF
out="$(run_ss "$p4")"
check "unverified pasted-head -> no trim notice"        no  "$(has "$out" 'trimmed')"
check "unverified pasted-head -> real HEAD sha present" yes "$(has "$out" "$real_sha")"
# A raw "**HEAD:**" marker count is not distinguishing here: the pasted
# block is SUPPOSED to survive (contributing its own "**HEAD:** `deadbee`"
# line), and the real sha also legitimately appears a second time inside the
# protected head's OWN "### Recent commits" fenced log (git log --oneline
# echoes the same abbreviated HEAD sha there). So check the exact rendered
# lines instead: the REAL "**HEAD:** `<sha>`" line must appear exactly once
# (only from the protected head; a narrative duplicate would make it 2),
# and the PASTED fake "**HEAD:** `deadbee`" line must also appear exactly
# once (preserved, not silently deleted, not duplicated either).
real_head_line_count="$(printf '%s\n' "$out" | grep -cF -- "**HEAD:** \`$real_sha\`")"
# shellcheck disable=SC2016  # backticks are a literal markdown code span here, not command substitution
fake_head_line_count="$(printf '%s\n' "$out" | grep -cF -- '**HEAD:** `deadbee`')"
check "unverified pasted-head -> real HEAD line printed exactly once (F3, no narrative duplicate)" 1 \
  "$real_head_line_count"
check "unverified pasted-head -> pasted fake HEAD line printed exactly once (F3, preserved not deleted/duplicated)" 1 \
  "$fake_head_line_count"
check "unverified pasted-head -> pasted marker before block survives (F3, not silently deleted)" yes \
  "$(has "$out" 'PASTED_MARKER_BEFORE')"
check "unverified pasted-head -> pasted marker after block survives (F3, not silently deleted)" yes \
  "$(has "$out" 'PASTED_MARKER_AFTER')"
check "unverified pasted-head -> pasted fake sha survives (F3, not silently deleted)" yes \
  "$(has "$out" 'deadbee')"
check "unverified pasted-head -> curated tail survives" yes "$(has "$out" 'CURATED_TAIL_D')"

finish
