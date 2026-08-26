#!/usr/bin/env bash
# Coverage for write_handoff.sh's cross-session overwrite guard (issue #63):
# refuses (exit 3) a curated write when the CURRENT handoff_current.md was
# authored by a DIFFERENT session whose stamped write time is LATER than this
# session's own recorded origin — i.e. this session is the stale one, and
# writing now would bury a fresher session's curation. Deterministic: session
# ids are injected via --session-id / env / payload, and origin epochs are
# planted directly into the sidecar rather than driven through real
# handoff_session_start.sh timing.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WH="$REPO_ROOT/bin/write_handoff.sh"
SENTINEL="<!-- HANDOFF_PLACEHOLDER: keep until /handoff replaces this block -->"
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

mk_repo_gitignored() {
  local d; d="$(mk_repo)"
  printf '.claude/\n' > "$d/.gitignore"
  git -C "$d" add .gitignore
  git -C "$d" commit -qm "ignore .claude"
  printf '%s\n' "$d"
}

# Hand-plant a handoff_current.md carrying a specific (possibly malformed)
# HANDOFF_WRITER marker line, so predicate inputs are exact and reproducible.
plant_doc() {  # <repo> <marker_line> <curated:yes|no> [unique_text]
  local repo="$1" marker="$2" curated="$3" uniq="${4:-}"
  mkdir -p "$repo/.claude"
  {
    printf '# handoff\n\n'
    printf '%s\n\n' "$marker"
    printf '## Notes from this session\n\n'
    if [[ "$curated" == yes ]]; then
      printf 'curated notes %s\n' "$uniq"
    else
      printf '%s\n' "$SENTINEL"
    fi
  } > "$repo/.claude/handoff_current.md"
}

writer_marker() { printf '<!-- HANDOFF_WRITER: sid=%s t=%s -->' "$1" "$2"; }

plant_origin() {  # <repo> <sid> <epoch>
  mkdir -p "$1/.claude/handoff_backups"
  printf '%s\n' "$3" > "$1/.claude/handoff_backups/.session_started_${2}"
}

hist_count() { find "$1/.claude/handoff_history" -maxdepth 1 -name 'handoff_*.md' -type f 2>/dev/null | wc -l | tr -d ' '; }

echo "write_handoff.sh — cross-session overwrite guard (issue #63)"

# --- 1: no id anywhere -> no marker stamped; a later write from another id
#        still exits 0 (nothing to compare against) -------------------------
repo="$(mk_repo_gitignored)"
( cd "$repo" && env -u CLAUDE_CODE_SESSION_ID bash "$WH" >/dev/null 2>&1 )
check "1: no id -> no HANDOFF_WRITER marker" no "$(has "$(cat "$repo/.claude/handoff_current.md")" "HANDOFF_WRITER")"
rc=0
out="$( cd "$repo" && bash "$WH" --session-id sidB 2>/dev/null )" || rc=$?
check "1: second write (id B, no marker on doc) -> exit 0" 0 "$rc"
check "1: exit 0 -> stdout is the path" yes "$(has "$out" "handoff_current.md")"
rm -rf "$repo"

# --- 2: same-session rewrite -> exit 0, no warning ---------------------------
repo="$(mk_repo_gitignored)"
plant_doc "$repo" "$(writer_marker sidA 1000)" no
rc=0
err="$( cd "$repo" && bash "$WH" --session-id sidA 2>&1 >/dev/null )"; rc=$?
check "2: same-session rewrite -> exit 0" 0 "$rc"
check "2: same-session rewrite -> no guard message" no "$(has "$err" "CROSS-SESSION OVERWRITE GUARD")"
rm -rf "$repo"

# --- 3: normal succession (doc by A@T1, B's origin T2>T1) -> exit 0, no
#        warning — the regression test for the identity-alone correction ----
repo="$(mk_repo_gitignored)"
plant_doc "$repo" "$(writer_marker sidA 1000)" yes MARKER3
plant_origin "$repo" sidB 2000
rc=0
err="$( cd "$repo" && bash "$WH" --session-id sidB 2>&1 >/dev/null )"; rc=$?
check "3: normal succession -> exit 0" 0 "$rc"
check "3: normal succession -> no guard message" no "$(has "$err" "CROSS-SESSION OVERWRITE GUARD")"
rm -rf "$repo"

# --- 4: headline stale case (doc by B@T3, A's origin T0<T3) -> exit 3 -------
repo="$(mk_repo_gitignored)"
plant_doc "$repo" "$(writer_marker sidB 3000)" yes MARKER4
plant_origin "$repo" sidA 500
before_cksum="$(cksum "$repo/.claude/handoff_current.md")"
before_hist="$(hist_count "$repo")"
errfile="$(mktemp)"
rc=0
out="$( cd "$repo" && bash "$WH" --session-id sidA 2>"$errfile" )"; rc=$?
err="$(cat "$errfile" 2>/dev/null)"; rm -f "$errfile"
check "4: stale write -> exit 3" 3 "$rc"
check "4: stale write -> nothing on stdout" "" "$out"
check "4: stderr names this session (A)" yes "$(has "$err" "sidA")"
check "4: stderr names the doc author (B)" yes "$(has "$err" "sidB")"
check "4: stderr shows a write time" yes "$(has "$err" "UTC")"
check "4: handoff_current.md byte-identical" "$before_cksum" "$(cksum "$repo/.claude/handoff_current.md")"
check "4: history count unchanged" "$before_hist" "$(hist_count "$repo")"
rm -rf "$repo"

# --- 5: case 4 with --takeover -> exit 0, stdout path, fresher doc archived -
repo="$(mk_repo_gitignored)"
plant_doc "$repo" "$(writer_marker sidB 3000)" yes MARKER5
plant_origin "$repo" sidA 500
rc=0
out="$( cd "$repo" && bash "$WH" --session-id sidA --takeover 2>/dev/null )"; rc=$?
check "5: --takeover -> exit 0" 0 "$rc"
check "5: --takeover -> stdout is the path" yes "$(has "$out" "handoff_current.md")"
check "5: --takeover -> fresher doc archived to history" yes \
  "$(grep -rq 'MARKER5' "$repo/.claude/handoff_history" 2>/dev/null && echo yes || echo no)"
rm -rf "$repo"

# --- 5b: --takeover over a PLACEHOLDER fresher doc -> discarded, not
#         archived (rotate_existing_handoff deletes an unedited placeholder
#         rather than archiving it — the stderr note must say so, not claim
#         an archive path that will never exist) -------------------------
repo="$(mk_repo_gitignored)"
plant_doc "$repo" "$(writer_marker sidB 3000)" no
plant_origin "$repo" sidA 500
rc=0
err="$( cd "$repo" && bash "$WH" --session-id sidA --takeover 2>&1 >/dev/null )"; rc=$?
check "5b: --takeover over placeholder -> exit 0" 0 "$rc"
check "5b: --takeover over placeholder -> 'discarded' note" yes "$(has "$err" "will be DISCARDED, not archived")"
check "5b: --takeover over placeholder -> no bogus archive-path claim" no "$(has "$err" "will be archived")"
check "5b: --takeover over placeholder -> nothing actually archived" 0 "$(hist_count "$repo")"
rm -rf "$repo"

# --- 6: --restamp on a cross-session doc: never fires, still verifies ------
repo="$(mk_repo_gitignored)"
( cd "$repo" && bash "$WH" --session-id sidX >/dev/null 2>&1 )   # real, signed write
errfile="$(mktemp)"
rc=0
out="$( cd "$repo" && env CLAUDE_CODE_SESSION_ID=sidY bash "$WH" --restamp 2>"$errfile" )"; rc=$?
err="$(cat "$errfile" 2>/dev/null)"; rm -f "$errfile"
check "6: restamp on cross-identity doc -> exit 0" 0 "$rc"
check "6: restamp -> guard never fires" no "$(has "$err" "CROSS-SESSION OVERWRITE GUARD")"
if command -v openssl >/dev/null 2>&1; then
  # shellcheck source=bin/handoff_provenance.sh
  . "$REPO_ROOT/bin/handoff_provenance.sh"
  check "6: restamp -> doc still verifies" yes \
    "$(handoff_mac_verify "$repo/.claude/handoff_current.md" && echo yes || echo no)"
else
  skip "6: restamp verify (openssl missing)"
fi
rm -rf "$repo"

# --- 7: --if-curated on a cross-session doc: byte-for-byte today's behavior
#        on BOTH the skip (curated) and placeholder-overwrite branches ------
repo="$(mk_repo_gitignored)"
plant_doc "$repo" "$(writer_marker sidB 3000)" yes MARKER7CURATED
plant_origin "$repo" sidA 500
before="$(cat "$repo/.claude/handoff_current.md")"
rc=0
out="$( cd "$repo" && bash "$WH" --if-curated --session-id sidA 2>/dev/null )"; rc=$?
check "7a: --if-curated + curated cross-session doc -> exit 0" 0 "$rc"
check "7a: --if-curated -> doc untouched (byte-for-byte)" "$before" "$(cat "$repo/.claude/handoff_current.md")"
rm -rf "$repo"

repo="$(mk_repo_gitignored)"
plant_doc "$repo" "$(writer_marker sidB 3000)" no
plant_origin "$repo" sidA 500
rc=0
out="$( cd "$repo" && bash "$WH" --if-curated --session-id sidA 2>/dev/null )"; rc=$?
check "7b: --if-curated + placeholder cross-session doc -> exit 0" 0 "$rc"
check "7b: --if-curated -> placeholder still overwritten (today's behavior)" no \
  "$(has "$(cat "$repo/.claude/handoff_current.md")" "sid=sidB")"
rm -rf "$repo"

# --- 8: missing origin sidecar -> exit 0 (fail open) ------------------------
repo="$(mk_repo_gitignored)"
plant_doc "$repo" "$(writer_marker sidB 3000)" yes MARKER8
rc=0
err="$( cd "$repo" && bash "$WH" --session-id sidA 2>&1 >/dev/null )"; rc=$?
check "8: missing origin -> exit 0" 0 "$rc"
check "8: missing origin -> no guard message" no "$(has "$err" "CROSS-SESSION OVERWRITE GUARD")"
rm -rf "$repo"

# --- 9: hostile marker content is treated as absent, never reaches stderr --
repo="$(mk_repo_gitignored)"
esc="$(printf '\033')"
for hostile in \
  "<!-- HANDOFF_WRITER: sid=PWNED;rm -rf t=100 -->" \
  "<!-- HANDOFF_WRITER: sid=${esc}[31mRED${esc}[0m t=100 -->" \
  "<!-- HANDOFF_WRITER: sid=validsid t=notanumber -->"
do
  plant_doc "$repo" "$hostile" yes MARKER9
  plant_origin "$repo" sidA 1
  rc=0
  err="$( cd "$repo" && bash "$WH" --session-id sidA 2>&1 >/dev/null )"; rc=$?
  check "9: hostile marker -> exit 0" 0 "$rc"
  check "9: hostile marker -> not treated as a valid marker (no guard fired)" no \
    "$(has "$err" "CROSS-SESSION OVERWRITE GUARD")"
  check "9: hostile bytes never echoed on stderr" no "$(has "$err" "PWNED")"
  check "9: ANSI escape never echoed on stderr" no "$(has "$err" "RED")"
done
rm -rf "$repo"

# --- 10: future-dated stamp (+3600) -> fail open, exit 0, skew note --------
repo="$(mk_repo_gitignored)"
now="$(date +%s)"
plant_doc "$repo" "$(writer_marker sidB $((now + 3600)))" yes MARKER10
plant_origin "$repo" sidA 1
rc=0
err="$( cd "$repo" && bash "$WH" --session-id sidA 2>&1 >/dev/null )"; rc=$?
check "10: future-dated stamp -> exit 0" 0 "$rc"
check "10: future-dated stamp -> skew note on stderr" yes "$(has "$err" "ahead of this machine's clock")"
check "10: future-dated stamp -> no guard-fired message" no "$(has "$err" "CROSS-SESSION OVERWRITE GUARD")"
rm -rf "$repo"

# --- 11: marker placement + skeleton coverage + restamp stability ----------
if command -v openssl >/dev/null 2>&1; then
  repo="$(mk_repo_gitignored)"
  path="$( cd "$repo" && bash "$WH" --session-id sidPlace 2>/dev/null )"
  wline="$(grep -n '^<!-- HANDOFF_WRITER: ' "$path" | head -n1 | cut -d: -f1)"
  nline="$(grep -n '^## Notes from this session$' "$path" | head -n1 | cut -d: -f1)"
  check "11: marker present" yes "$([[ -n "$wline" ]] && echo yes || echo no)"
  check "11: marker sits above the Notes heading" yes \
    "$([[ -n "$wline" && -n "$nline" && "$wline" -lt "$nline" ]] && echo yes || echo no)"
  # shellcheck source=bin/handoff_provenance.sh
  . "$REPO_ROOT/bin/handoff_provenance.sh"
  check "11: fresh doc verifies" yes "$(handoff_mac_verify "$path" && echo yes || echo no)"
  rc=0
  out2="$( cd "$repo" && bash "$WH" --restamp 2>/dev/null )"; rc=$?
  check "11: restamp of unedited fresh doc -> exit 0" 0 "$rc"
  check "11: restamp of unedited fresh doc -> re-signed (path on stdout)" yes "$(has "$out2" "handoff_current.md")"
  rm -rf "$repo"
else
  skip "11: marker placement / verify / restamp (openssl missing)"
fi

# --- 12: precedence — --session-id beats payload beats env -----------------
repo="$(mk_repo_gitignored)"
if command -v jq >/dev/null 2>&1; then
  path="$( cd "$repo" && env CLAUDE_CODE_SESSION_ID=sidEnv bash "$WH" --session-id sidFlag \
    <<<'{"session_id":"sidPayload"}' 2>/dev/null )"
  check "12: --session-id beats payload and env" yes "$(has "$(cat "$path")" "sid=sidFlag")"
  rm -rf "$repo"; repo="$(mk_repo_gitignored)"

  path="$( cd "$repo" && env CLAUDE_CODE_SESSION_ID=sidEnv bash "$WH" \
    <<<'{"session_id":"sidPayload"}' 2>/dev/null )"
  check "12: payload beats env when no --session-id" yes "$(has "$(cat "$path")" "sid=sidPayload")"
else
  skip "12: payload precedence (jq missing)"
fi
rm -rf "$repo"; repo="$(mk_repo_gitignored)"
path="$( cd "$repo" && env CLAUDE_CODE_SESSION_ID=sidEnv bash "$WH" </dev/null 2>/dev/null )"
check "12: env used when no flag and no payload" yes "$(has "$(cat "$path")" "sid=sidEnv")"
rm -rf "$repo"

# --- 13: HANDOFF_OVERWRITE_GUARD=warn / =off -------------------------------
repo="$(mk_repo_gitignored)"
plant_doc "$repo" "$(writer_marker sidB 3000)" yes MARKER13WARN
plant_origin "$repo" sidA 500
rc=0
err="$( cd "$repo" && HANDOFF_OVERWRITE_GUARD=warn bash "$WH" --session-id sidA 2>&1 >/dev/null )"; rc=$?
check "13: mode=warn -> exit 0" 0 "$rc"
check "13: mode=warn -> warning printed" yes "$(has "$err" "CROSS-SESSION OVERWRITE GUARD")"
rm -rf "$repo"

repo="$(mk_repo_gitignored)"
plant_doc "$repo" "$(writer_marker sidB 3000)" yes MARKER13OFF
plant_origin "$repo" sidA 500
rc=0
err="$( cd "$repo" && HANDOFF_OVERWRITE_GUARD=off bash "$WH" --session-id sidA 2>&1 >/dev/null )"; rc=$?
check "13: mode=off -> exit 0" 0 "$rc"
check "13: mode=off -> silent (no guard message)" no "$(has "$err" "CROSS-SESSION OVERWRITE GUARD")"
rm -rf "$repo"

finish
