#!/usr/bin/env bash
# Pruning must only ever delete files THIS TOOL generated (#46).
#
# Both prune loops used a loose glob and deleted everything past the keep-N
# cutoff, so a file the user put in one of these directories — hand-preserving
# a snapshot as `handoff_2026-01-05_IMPORTANT.md`, or archiving a dump — was
# silently deleted once it fell outside the retention window. No warning, no
# backup, unrecoverable.
#
# The negative controls (a foreign file that WOULD have been caught by the old
# glob and sorts/dates into the prune tail) are the point of this file. The
# positive controls matter too: retention must still work on our own files, and
# foreign files must not consume retention slots.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WH="$REPO_ROOT/bin/write_handoff.sh"
TA="$REPO_ROOT/bin/handoff_turn_append.sh"

echo "prune ownership — only our generated files are ever deleted (#46)"

# --- history: prune_history ---------------------------------------------------
proj="$(mk_repo)" || exit 1
must mkdir -p "$proj/.claude/handoff_history"
hist="$proj/.claude/handoff_history"

# Foreign files. The first matches the old `handoff_*.md` glob AND sorts before
# any real 2026 stamp, so under the old code it landed in the prune tail first.
must printf 'MY IRREPLACEABLE NOTES\n' > "$hist/handoff_2019-01-01_my_own_notes.md"
must printf 'notes\n'                  > "$hist/handoff_important.md"
must printf 'research\n'               > "$hist/my_research.md"
must printf 'archive\n'                > "$hist/notes.txt"

# Six curated handoffs so rotation actually archives (placeholders are dropped).
i=0
while [ "$i" -lt 6 ]; do
  ( cd "$proj" && env HANDOFF_SECRET_FILE="$proj/.secret" bash "$WH" </dev/null >/dev/null 2>&1 )
  sed 's/<!-- HANDOFF_PLACEHOLDER: keep until \/handoff replaces this block -->/Curated notes/' \
      "$proj/.claude/handoff_current.md" > "$proj/.claude/t" \
    && mv "$proj/.claude/t" "$proj/.claude/handoff_current.md"
  sleep 1
  i=$((i + 1))
done
( cd "$proj" && env HANDOFF_HISTORY_KEEP=2 HANDOFF_SECRET_FILE="$proj/.secret" bash "$WH" </dev/null >/dev/null 2>&1 )

check "history: foreign handoff_<olddate> survives" yes "$([ -f "$hist/handoff_2019-01-01_my_own_notes.md" ] && echo yes || echo no)"
check "history: foreign content intact"             yes "$(grep -qF 'MY IRREPLACEABLE NOTES' "$hist/handoff_2019-01-01_my_own_notes.md" 2>/dev/null && echo yes || echo no)"
check "history: foreign handoff_important survives" yes "$([ -f "$hist/handoff_important.md" ] && echo yes || echo no)"
check "history: non-matching files survive"         yes "$([ -f "$hist/my_research.md" ] && [ -f "$hist/notes.txt" ] && echo yes || echo no)"
# Retention still applies to OUR files, and foreign files didn't eat slots.
# Count only the EXACT generated shape — a looser pattern also matches the
# foreign handoff_2019-01-01_my_own_notes.md fixture and inflates the tally.
check "history: our files pruned to KEEP=2"         2   "$(find "$hist" -maxdepth 1 -name 'handoff_*.md' -type f 2>/dev/null | LC_ALL=C grep -cE '/handoff_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}(_[0-9]+)?\.md$' | tr -d ' ')"
rm -rf "$proj"

# --- backups: the Stop-hook prune --------------------------------------------
# Ownership here can't come from the filename: a user's
# `handoff_raw_my_own_archive.md` has an "id" satisfying the same charset a real
# session id does. The proof is the companion `.handoff_raw_<id>.cursor` this
# hook writes next to every dump it creates.
if ! command -v jq >/dev/null 2>&1; then
  skip "jq not installed — the Stop hook exits before pruning"
  finish
  exit
fi

proj="$(mk_repo)" || exit 1
must mkdir -p "$proj/.claude/handoff_backups"
bdir="$proj/.claude/handoff_backups"
tp="$proj/t.jsonl"
must printf '{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":5}},"model":"claude-x"}\n' > "$tp"

fire() {  # <session_id>
  ( cd "$proj" && printf '{"session_id":"%s","transcript_path":"%s"}' "$1" "$tp" \
      | env CLAUDE_PROJECT_DIR="$proj" bash "$TA" >/dev/null 2>&1 )
}

# Foreign files: one matching the old glob (no cursor -> not ours), one not.
must printf 'MY ARCHIVED DUMP\n' > "$bdir/handoff_raw_my_own_archive.md"
must printf 'plain notes\n'      > "$bdir/my_notes.md"

n=1
while [ "$n" -le 5 ]; do fire "sess$n"; sleep 1; n=$((n + 1)); done
# Make the foreign file the OLDEST so the old code would prune it first.
touch -t 202001010000 "$bdir/handoff_raw_my_own_archive.md"
fire "sessNEW"

check "backups: foreign dump survives"          yes "$([ -f "$bdir/handoff_raw_my_own_archive.md" ] && echo yes || echo no)"
check "backups: foreign content intact"         yes "$(grep -qF 'MY ARCHIVED DUMP' "$bdir/handoff_raw_my_own_archive.md" 2>/dev/null && echo yes || echo no)"
check "backups: non-matching file survives"     yes "$([ -f "$bdir/my_notes.md" ] && echo yes || echo no)"
# Retention still applies to OUR dumps (3 newest), and the foreign file did not
# consume a slot — filtering happens before the keep-3 cut.
check "backups: our dumps pruned to 3"          3   "$(find "$bdir" -maxdepth 1 -name 'handoff_raw_sess*.md' -type f 2>/dev/null | grep -c . | tr -d ' ')"
# A cursor-less file is never a prune candidate even when it is the only one.
check "backups: foreign has no cursor"          no  "$([ -f "$bdir/.handoff_raw_my_own_archive.cursor" ] && echo yes || echo no)"
rm -rf "$proj"

finish
