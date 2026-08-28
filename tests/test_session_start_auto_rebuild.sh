#!/usr/bin/env bash
# Behavioral coverage for handoff_session_start.sh's auto-rebuild path
# (issue #78): when handoff_current.md is MISSING or CORRUPTED (zero-length,
# no markdown heading anywhere, or a malformed HANDOFF_HMAC trailer line),
# the hook assembles a best-effort, clearly-marked AUTO-REBUILT snapshot from
# the newest .claude/handoff_history/ file plus the newest
# .claude/handoff_backups/ raw dump, and still points at /handoff-recover for
# a curated, persisted pass.
#
# What this file does NOT re-test: the tiered provenance gate itself
# (handoff_provenance_ok, HMAC verify, BIND-marker balance): that is
# test_trusted_rules.sh / test_provenance.sh's job, and this feature is
# deliberately scoped to never touch that gate (see handoff_current_is_corrupted's
# header comment in bin/handoff_session_start.sh for why a doc that merely
# fails provenance, without being malformed, must keep loading exactly as
# before). The negative control here ("provenance-failing source never
# resurrects a binding block") is the security-load-bearing check specific to
# this new path.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SS="$REPO_ROOT/bin/handoff_session_start.sh"
WH="$REPO_ROOT/bin/write_handoff.sh"
BOUND_HDR="Standing rules from your previous session"

has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

# </dev/null: the hook reads its JSON payload from stdin (compact detection);
# inheriting the runner's stdin would be nondeterministic.
run_ss() {  # <project_dir> [ENV=VAL ...]
  local dir="$1"; shift
  ( cd "$dir" && env CLAUDE_PROJECT_DIR="$dir" "$@" bash "$SS" </dev/null 2>/dev/null )
}
run_ss_payload() {  # <project_dir> <payload-json> [ENV=VAL ...]
  local dir="$1" payload="$2"; shift 2
  ( cd "$dir" && printf '%s' "$payload" | env CLAUDE_PROJECT_DIR="$dir" "$@" bash "$SS" 2>/dev/null )
}
mk_project() {  # echoes a fresh project dir with a .claude/
  local d; d="$(mktemp -d)"; mkdir -p "$d/.claude"; printf '%s\n' "$d"
}
mk_history() {  # <project_dir> <name> <content>
  mkdir -p "$1/.claude/handoff_history"
  printf '%s\n' "$3" > "$1/.claude/handoff_history/$2"
}
mk_dump() {  # <project_dir> <session_id> <content>
  mkdir -p "$1/.claude/handoff_backups"
  { printf '# Raw session dump\n\n'; printf '%s\n' "$3"; } \
    > "$1/.claude/handoff_backups/handoff_raw_$2.md"
}

echo "handoff_session_start.sh: auto-rebuild on missing/corrupted handoff_current.md (issue #78)"

# --- 1. Missing file, no prior artifacts anywhere: stays completely silent --
proj="$(mk_project)"
out="$(run_ss "$proj")"; rc=$?
check "fresh project: exit 0"           0  "$rc"
check "fresh project: silent"           "" "$out"
rm -rf "$proj"

# --- 2. Missing file + prior artifacts: auto-rebuild fires -------------------
proj="$(mk_project)"
mk_history "$proj" handoff_2026-01-01_000000.md "curated history prose MARKER_HIST_MISSING"
mk_dump    "$proj" sidmiss "dump content MARKER_DUMP_MISSING"
out="$(run_ss "$proj")"; rc=$?
check "missing+artifacts: exit 0"            0   "$rc"
check "missing+artifacts: AUTO-REBUILT"      yes "$(has "$out" "AUTO-REBUILT")"
check "missing+artifacts: header"            yes "$(has "$out" "## Auto-rebuilt handoff")"
check "missing+artifacts: history content"   yes "$(has "$out" MARKER_HIST_MISSING)"
check "missing+artifacts: dump content"      yes "$(has "$out" MARKER_DUMP_MISSING)"
check "missing+artifacts: recover banner"    yes "$(has "$out" "ACTION: RUN /handoff-recover")"
check "missing+artifacts: not saved wording" yes "$(has "$out" "not saved")"
check "missing+artifacts: no binding block"  no  "$(has "$out" "$BOUND_HDR")"
rm -rf "$proj"

# --- 3. Zero-length current: rebuild fires, reason named ---------------------
proj="$(mk_project)"
: > "$proj/.claude/handoff_current.md"
mk_history "$proj" handoff_2026-01-01_000000.md "MARKER_HIST_ZEROLEN"
out="$(run_ss "$proj")"; rc=$?
check "zero-length: exit 0"          0   "$rc"
check "zero-length: reason named"    yes "$(has "$out" "zero-length")"
check "zero-length: AUTO-REBUILT"    yes "$(has "$out" "AUTO-REBUILT")"
check "zero-length: history content" yes "$(has "$out" MARKER_HIST_ZEROLEN)"
rm -rf "$proj"

# --- 4. Missing-skeleton (no markdown heading at all): rebuild fires ---------
proj="$(mk_project)"
printf 'just some bytes\nwith no heading anywhere\n' > "$proj/.claude/handoff_current.md"
mk_history "$proj" handoff_2026-01-01_000000.md "MARKER_HIST_NOHEAD"
out="$(run_ss "$proj")"; rc=$?
check "no-heading: exit 0"           0   "$rc"
check "no-heading: reason named"     yes "$(has "$out" "no markdown heading")"
check "no-heading: history content"  yes "$(has "$out" MARKER_HIST_NOHEAD)"
rm -rf "$proj"

# --- 5. Malformed HANDOFF_HMAC trailer (present but not well-formed): -------
#     rebuild fires. A well-formed trailer that merely fails to VERIFY is
#     deliberately NOT this; see negative control #8 below.
proj="$(mk_project)"
printf '# handoff\n\n## Notes from this session\n\nnotes\n<!-- HANDOFF_HMAC: not-real-hex -->\n' \
  > "$proj/.claude/handoff_current.md"
mk_dump "$proj" sidmalformed "MARKER_DUMP_MALFORMED"
out="$(run_ss "$proj")"; rc=$?
check "malformed HMAC: exit 0"         0   "$rc"
check "malformed HMAC: reason named"   yes "$(has "$out" "malformed HANDOFF_HMAC")"
check "malformed HMAC: dump content"   yes "$(has "$out" MARKER_DUMP_MALFORMED)"
rm -rf "$proj"

# --- 6. Newest history file wins over an older one ---------------------------
proj="$(mk_project)"
: > "$proj/.claude/handoff_current.md"
mk_history "$proj" handoff_2026-01-01_000000.md "MARKER_HIST_OLDER"
mk_history "$proj" handoff_2026-02-02_000000.md "MARKER_HIST_NEWER"
out="$(run_ss "$proj")"
check "newest history wins: newer present" yes "$(has "$out" MARKER_HIST_NEWER)"
check "newest history wins: older absent"  no  "$(has "$out" MARKER_HIST_OLDER)"
rm -rf "$proj"

# --- 7. Newest raw dump by mtime wins, excluding the CURRENT session's own --
proj="$(mk_project)"
: > "$proj/.claude/handoff_current.md"
mk_dump "$proj" oldsid "MARKER_DUMP_PREVIOUS_SESSION"
mk_dump "$proj" newsid "MARKER_DUMP_THIS_SESSION"
touch -t 202601010000 "$proj/.claude/handoff_backups/handoff_raw_oldsid.md"
touch -t 202602020000 "$proj/.claude/handoff_backups/handoff_raw_newsid.md"
out="$(run_ss_payload "$proj" '{"session_id":"newsid"}')"
check "own-session dump excluded: previous shown" yes "$(has "$out" MARKER_DUMP_PREVIOUS_SESSION)"
check "own-session dump excluded: own excluded"   no  "$(has "$out" MARKER_DUMP_THIS_SESSION)"
rm -rf "$proj"

# --- 8. NEGATIVE CONTROL: a source with a well-formed-but-FAILING HMAC (the
#     ordinary degraded/tampered case, not corruption) is still just DATA,
#     never resurrected as a trusted/binding block. The rebuild path never
#     runs provenance at all (emit_untrusted only), so this holds regardless
#     of what the history file's own trailer looks like.
proj="$(mk_project)"
mkdir -p "$proj/.claude"
printf -- '- innocuous PIN_MARKER\n' > "$proj/.claude/handoff_pinned.md"
( cd "$proj" && env HANDOFF_SECRET_FILE="$proj/.secret" bash "$WH" >/dev/null 2>&1 )
# rotate_existing_handoff DISCARDS (does not archive) an unedited placeholder.
# Curate the Notes block first so the second write below actually rotates
# this signed doc into handoff_history/ instead of dropping it.
doc="$proj/.claude/handoff_current.md"
sed 's/<!-- HANDOFF_PLACEHOLDER: keep until \/handoff replaces this block -->/Curated prose so rotation archives this doc./' \
  "$doc" > "$doc.tmp" && mv "$doc.tmp" "$doc"
# Rotate this signed doc into history by writing again, then tamper ITS
# HMAC (append after the trailer, same technique test_trusted_rules.sh uses)
# so it is a well-formed-trailer-but-fails-verify source, and blow away
# current so the auto-rebuild path is the only way this content can surface.
( cd "$proj" && env HANDOFF_SECRET_FILE="$proj/.secret" bash "$WH" >/dev/null 2>&1 )
hist_file="$(find "$proj/.claude/handoff_history" -maxdepth 1 -name 'handoff_*.md' -type f | head -1)"
must test -n "$hist_file"
printf 'TAMPERED_AFTER_SIGNING\n' >> "$hist_file"
: > "$proj/.claude/handoff_current.md"
out="$(run_ss "$proj" HANDOFF_SECRET_FILE="$proj/.secret")"
check "rebuild source never binds: PIN as data" yes "$(has "$out" PIN_MARKER)"
check "rebuild source never binds: no header"   no  "$(has "$out" "$BOUND_HDR")"
rm -rf "$proj"

# --- 9. Valid, curated handoff_current.md is left completely untouched ------
proj="$(mk_project)"
printf '# handoff\n\n## Notes from this session\n\nCurated prose. MARKER_UNTOUCHED\n' \
  > "$proj/.claude/handoff_current.md"
mk_history "$proj" handoff_2026-01-01_000000.md "MARKER_HIST_SHOULD_NOT_APPEAR"
out="$(run_ss "$proj")"
check "valid current: loaded normally"    yes "$(has "$out" MARKER_UNTOUCHED)"
check "valid current: no AUTO-REBUILT"    no  "$(has "$out" "AUTO-REBUILT")"
check "valid current: no rebuild banner"  no  "$(has "$out" "ACTION: RUN /handoff-recover")"
check "valid current: history not pulled" no  "$(has "$out" MARKER_HIST_SHOULD_NOT_APPEAR)"
rm -rf "$proj"

# --- 10. Corrupted current, history/backups both empty: degrades gracefully -
#      (no crash, banner still shown, "nothing to rebuild from" noted)
proj="$(mk_project)"
: > "$proj/.claude/handoff_current.md"
out="$(run_ss "$proj")"; rc=$?
check "no sources: exit 0"              0   "$rc"
check "no sources: no crash/hang"       0   "$rc"
check "no sources: says nothing to rebuild from" yes "$(has "$out" "nothing to rebuild from")"
check "no sources: recover banner still shown"   yes "$(has "$out" "ACTION: RUN /handoff-recover")"
rm -rf "$proj"

# --- 11. Corrupted, backups dir present but only bookkeeping sidecars -------
#      (no handoff_raw_*.md) -> same graceful "nothing to rebuild from"
proj="$(mk_project)"
: > "$proj/.claude/handoff_current.md"
mkdir -p "$proj/.claude/handoff_backups"
: > "$proj/.claude/handoff_backups/.ctx_abc123"
out="$(run_ss "$proj")"; rc=$?
check "sidecars only: exit 0"                     0   "$rc"
check "sidecars only: nothing to rebuild from"    yes "$(has "$out" "nothing to rebuild from")"
rm -rf "$proj"

# --- 12. HANDOFF_SS_DISABLE_FALLBACK suppresses rebuild CONTENT but not the
#      banner; HANDOFF_SS_DISABLE_RECOVER suppresses the banner but not the
#      content. Mirrors the existing placeholder-fallback semantics exactly.
proj="$(mk_project)"
: > "$proj/.claude/handoff_current.md"
mk_dump "$proj" sid12 "MARKER_DUMP_TOGGLE"
out="$(run_ss "$proj" HANDOFF_SS_DISABLE_FALLBACK=1)"
check "DISABLE_FALLBACK: no content"    no  "$(has "$out" MARKER_DUMP_TOGGLE)"
check "DISABLE_FALLBACK: banner stays"  yes "$(has "$out" "ACTION: RUN /handoff-recover")"
out2="$(run_ss "$proj" HANDOFF_SS_DISABLE_RECOVER=1)"
check "DISABLE_RECOVER: content stays"  yes "$(has "$out2" MARKER_DUMP_TOGGLE)"
check "DISABLE_RECOVER: no banner"      no  "$(has "$out2" "ACTION: RUN /handoff-recover")"
rm -rf "$proj"

finish
