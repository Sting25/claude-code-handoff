#!/usr/bin/env bash
# Session-sticky handoff writes: a SECOND write from the SAME session
# (matched via the `<!-- HANDOFF_SESSION: ID -->` marker write_handoff.sh
# embeds inside the signed body) must update handoff_current.md IN PLACE —
# no rotation into handoff_history/, curated Notes/Rules carried forward —
# instead of rotating its own earlier snapshot the way a different-session
# (or no-id) write still does today. Covers: same-id no-rotate + carry,
# different/legacy/absent-id -> unchanged legacy rotate, invalid-charset ids
# treated as absent (with per-candidate fall-through), CLI > payload > env
# precedence, --restamp marker/MAC behavior, and the placeholder-vs-curated
# same-session edge.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WH="$REPO_ROOT/bin/write_handoff.sh"
SENTINEL="<!-- HANDOFF_PLACEHOLDER: keep until /handoff replaces this block -->"
BIND_BEGIN='<!-- HANDOFF_BIND_BEGIN -->'
BIND_END='<!-- HANDOFF_BIND_END -->'
RULES_HDR="## Rules (fences — carried into the next session)"
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

mk_repo_gitignored() {
  local d; d="$(mk_repo)"
  printf '.claude/\n' > "$d/.gitignore"
  git -C "$d" add .gitignore
  git -C "$d" commit -qm "ignore .claude"
  printf '%s\n' "$d"
}

# Hand-build a CURATED handoff_current.md: a pinned BIND region (unrelated —
# proves the Rules carry can't grab the wrong BIND region), a curated Rules
# BIND region, and curated multi-line Notes. $2 is the session-marker id
# (empty -> no marker line at all, i.e. a legacy doc). $3/$4 are distinct
# tokens baked into the Rules / Notes bodies so a carry can be verified by
# content, not just by "not the placeholder".
seed_curated() {  # <repo> <session_id|""> <rules_token> <notes_token>
  local repo="$1" sid="$2" rtok="$3" ntok="$4"
  mkdir -p "$repo/.claude"
  {
    printf '# handoff\n\n'
    printf '%s\n' "$BIND_BEGIN"
    printf '## 📌 Pinned — carried forward every handoff\n\n'
    printf 'unrelated pinned line PIN_UNRELATED\n'
    printf '%s\n\n' "$BIND_END"
    printf '%s\n' "$BIND_BEGIN"
    printf '%s\n\n' "$RULES_HDR"
    printf -- '- Do NOT merge without CI green. %s\n' "$rtok"
    printf '%s\n\n' "$BIND_END"
    echo '---'
    echo
    printf '## Notes from this session\n\n'
    printf 'Curated decision one. %s_A\n' "$ntok"
    printf 'Curated decision two, indented:\n'
    printf '  - sub-point %s_B\n' "$ntok"
    printf '\n'
    printf 'Trailing paragraph %s_C.\n' "$ntok"
    if [[ -n "$sid" ]]; then
      printf '<!-- HANDOFF_SESSION: %s -->\n' "$sid"
    fi
  } > "$repo/.claude/handoff_current.md"
}

hist_count() { find "$1/.claude/handoff_history" -maxdepth 1 -name 'handoff_*.md' 2>/dev/null | wc -l | tr -d ' '; }
session_marker() {  # <file> -> the id from the LAST well-formed marker line, or empty
  LC_ALL=C grep -E '^<!-- HANDOFF_SESSION: [A-Za-z0-9_-]+ -->[[:space:]]*$' "$1" 2>/dev/null \
    | tail -n 1 | sed -E 's/^<!-- HANDOFF_SESSION: ([A-Za-z0-9_-]+) -->.*$/\1/'
}
marker_count() { LC_ALL=C grep -cE '^<!-- HANDOFF_SESSION: [A-Za-z0-9_-]+ -->[[:space:]]*$' "$1" 2>/dev/null || echo 0; }
extract_notes() {  # <file> -> Notes block, marker/HMAC lines stripped
  LC_ALL=C awk '$0 == "## Notes from this session" { f = 1 } f { print }' "$1" 2>/dev/null \
    | LC_ALL=C grep -Ev '^<!-- HANDOFF_SESSION: [A-Za-z0-9_-]+ -->[[:space:]]*$|^<!-- HANDOFF_HMAC: [0-9a-f]{64} -->[[:space:]]*$'
}
extract_rules() {  # <file> -> the BIND region carrying the Rules header, verbatim
  LC_ALL=C awk -v hdr="$RULES_HDR" '
    $0 == "<!-- HANDOFF_BIND_BEGIN -->" { buf = $0; inb = 1; isrules = 0; next }
    inb {
      buf = buf ORS $0
      if ($0 == hdr) isrules = 1
      if ($0 == "<!-- HANDOFF_BIND_END -->") {
        if (isrules) { print buf; exit }
        inb = 0
      }
    }
  ' "$1" 2>/dev/null
}

JQ_OK=0; command -v jq >/dev/null 2>&1 && JQ_OK=1
OPENSSL_OK=0; command -v openssl >/dev/null 2>&1 && OPENSSL_OK=1

echo "write_handoff.sh — session-sticky writes (same-session carry / rotate fallback / precedence / restamp)"

# =============================================================================
# 1. Same-id rewrite: NO new history entry, and PRE-EXISTING (other-session)
#    history is left completely untouched — same-session churn must not prune
#    other sessions' snapshots either.
# =============================================================================
repo="$(mk_repo_gitignored)"
mkdir -p "$repo/.claude/handoff_history"
echo old1 > "$repo/.claude/handoff_history/handoff_2020-01-01_000000.md"
echo old2 > "$repo/.claude/handoff_history/handoff_2020-01-02_000000.md"
seed_curated "$repo" "SIDA" "RTOK1" "NTOK1"
doc="$repo/.claude/handoff_current.md"
before_notes="$(extract_notes "$doc")"
out="$( cd "$repo" && bash "$WH" --session-id SIDA 2>/dev/null )"
check "same-id: exit prints path"            yes "$(has "$out" ".claude/handoff_current.md")"
check "same-id: history count unchanged (2)" 2   "$(hist_count "$repo")"
check "same-id: other-session file 1 kept"   yes "$([[ -f "$repo/.claude/handoff_history/handoff_2020-01-01_000000.md" ]] && echo yes || echo no)"
check "same-id: other-session file 2 kept"   yes "$([[ -f "$repo/.claude/handoff_history/handoff_2020-01-02_000000.md" ]] && echo yes || echo no)"
check "same-id: no placeholder sentinel"     no  "$(has "$(cat "$doc")" "$SENTINEL")"
check "same-id: exactly one session marker"  1   "$(marker_count "$doc")"
check "same-id: marker still SIDA"           SIDA "$(session_marker "$doc")"
rm -rf "$repo"

# =============================================================================
# 2. Same-id rewrite carries curated Notes forward BYTE-FOR-BYTE.
# =============================================================================
repo="$(mk_repo_gitignored)"
seed_curated "$repo" "SIDB" "RTOK2" "NTOK2"
doc="$repo/.claude/handoff_current.md"
before_notes="$(extract_notes "$doc")"
( cd "$repo" && bash "$WH" --session-id SIDB >/dev/null 2>&1 )
after_notes="$(extract_notes "$doc")"
check "same-id: Notes carried byte-for-byte" "$before_notes" "$after_notes"
check "same-id: Notes token present"         yes "$(has "$after_notes" "NTOK2")"
rm -rf "$repo"

# =============================================================================
# 3. Same-id rewrite carries curated Rules BIND region forward, markers
#    included — and does NOT grab the preceding (unrelated) pinned region.
# =============================================================================
repo="$(mk_repo_gitignored)"
seed_curated "$repo" "SIDC" "RTOK3" "NTOK3"
doc="$repo/.claude/handoff_current.md"
before_rules="$(extract_rules "$doc")"
( cd "$repo" && bash "$WH" --session-id SIDC >/dev/null 2>&1 )
after_rules="$(extract_rules "$doc")"
check "same-id: Rules block carried verbatim" "$before_rules" "$after_rules"
check "same-id: Rules token present"          yes "$(has "$after_rules" "RTOK3")"
check "same-id: pinned region not the carry"  no  "$(has "$after_rules" "PIN_UNRELATED")"
check "same-id: RULES_PLACEHOLDER not reintroduced" no "$(has "$(cat "$doc")" "HANDOFF_RULES_PLACEHOLDER")"
rm -rf "$repo"

# =============================================================================
# 4. Different-id write: rotates exactly as before (curated doc archived).
# =============================================================================
repo="$(mk_repo_gitignored)"
seed_curated "$repo" "SIDD1" "RTOK4" "NTOK4"
( cd "$repo" && bash "$WH" --session-id SIDD2 >/dev/null 2>&1 )
doc="$repo/.claude/handoff_current.md"
check "diff-id: rotates (1 history entry)"    1   "$(hist_count "$repo")"
check "diff-id: old curated content archived" yes "$(grep -rq 'NTOK4' "$repo/.claude/handoff_history" && echo yes || echo no)"
check "diff-id: new doc is fresh placeholder" yes "$(has "$(cat "$doc")" "$SENTINEL")"
check "diff-id: new doc marker is SIDD2"      SIDD2 "$(session_marker "$doc")"
check "diff-id: old token not in new current" no  "$(has "$(cat "$doc")" "NTOK4")"
rm -rf "$repo"

# =============================================================================
# 5a. Legacy doc (no marker at all) + a known id on THIS write -> rotates
#     exactly as before (nothing to match against).
# =============================================================================
repo="$(mk_repo_gitignored)"
seed_curated "$repo" "" "RTOK5A" "NTOK5A"     # no session id -> legacy shape
( cd "$repo" && bash "$WH" --session-id SIDE >/dev/null 2>&1 )
doc="$repo/.claude/handoff_current.md"
check "legacy-doc: rotates (1 history entry)" 1 "$(hist_count "$repo")"
check "legacy-doc: new doc marker is SIDE"    SIDE "$(session_marker "$doc")"
check "legacy-doc: old token archived"        yes "$(grep -rq 'NTOK5A' "$repo/.claude/handoff_history" && echo yes || echo no)"
rm -rf "$repo"

# =============================================================================
# 5b. Existing doc HAS a marker, but THIS write has no id anywhere -> rotates
#     exactly as before; the fresh doc carries no marker at all.
# =============================================================================
repo="$(mk_repo_gitignored)"
seed_curated "$repo" "SIDF" "RTOK5B" "NTOK5B"
( cd "$repo" && env -u CLAUDE_CODE_SESSION_ID bash "$WH" </dev/null >/dev/null 2>&1 )
doc="$repo/.claude/handoff_current.md"
check "no-id-now: rotates (1 history entry)"  1  "$(hist_count "$repo")"
check "no-id-now: new doc has no marker"      "" "$(session_marker "$doc")"
check "no-id-now: old token archived"         yes "$(grep -rq 'NTOK5B' "$repo/.claude/handoff_history" && echo yes || echo no)"
rm -rf "$repo"

# =============================================================================
# 6. Invalid-charset session id is treated as absent: falls through to the
#    next candidate; when NOTHING valid remains, behaves exactly like an
#    absent id (legacy rotate).
# =============================================================================
repo="$(mk_repo_gitignored)"
seed_curated "$repo" "SIDG" "RTOK6" "NTOK6"
err="$( cd "$repo" && bash "$WH" --session-id 'bad id!' 2>&1 >/dev/null )"
doc="$repo/.claude/handoff_current.md"
check "invalid-id-only: no usage error"       no "$(has "$err" "unknown argument")"
check "invalid-id-only: rotates (1 entry)"    1  "$(hist_count "$repo")"
check "invalid-id-only: new doc has no marker" "" "$(session_marker "$doc")"
rm -rf "$repo"

# 6b. Invalid CLI id falls through to a VALID lower-precedence id (env) that
#     matches the existing marker -> same-session carry still fires.
repo="$(mk_repo_gitignored)"
seed_curated "$repo" "SIDG2" "RTOK6B" "NTOK6B"
doc="$repo/.claude/handoff_current.md"
( cd "$repo" && env CLAUDE_CODE_SESSION_ID=SIDG2 bash "$WH" --session-id 'bad id!' </dev/null >/dev/null 2>&1 )
check "invalid-cli-falls-through: no rotation" 0    "$(hist_count "$repo")"
check "invalid-cli-falls-through: marker SIDG2" SIDG2 "$(session_marker "$doc")"
check "invalid-cli-falls-through: Notes carried" yes "$(has "$(cat "$doc")" "NTOK6B")"
rm -rf "$repo"

# =============================================================================
# 7. Precedence: --session-id flag beats stdin-payload .session_id beats
#    $CLAUDE_CODE_SESSION_ID. Fresh (no prior doc) so only the marker's value
#    is under test, not the carry logic.
# =============================================================================
if (( JQ_OK )); then
  repo="$(mk_repo_gitignored)"
  ( cd "$repo" && env CLAUDE_CODE_SESSION_ID=ENVID bash "$WH" </dev/null >/dev/null 2>&1 )
  check "precedence: env-only -> ENVID" ENVID "$(session_marker "$repo/.claude/handoff_current.md")"
  rm -rf "$repo"

  repo="$(mk_repo_gitignored)"
  ( cd "$repo" && bash "$WH" <<<'{"session_id":"PAYLOADID"}' >/dev/null 2>&1 )
  check "precedence: payload-only -> PAYLOADID" PAYLOADID "$(session_marker "$repo/.claude/handoff_current.md")"
  rm -rf "$repo"

  repo="$(mk_repo_gitignored)"
  ( cd "$repo" && env CLAUDE_CODE_SESSION_ID=ENVID2 bash "$WH" <<<'{"session_id":"PAYLOADID2"}' >/dev/null 2>&1 )
  check "precedence: payload beats env" PAYLOADID2 "$(session_marker "$repo/.claude/handoff_current.md")"
  rm -rf "$repo"

  repo="$(mk_repo_gitignored)"
  ( cd "$repo" && env CLAUDE_CODE_SESSION_ID=ENVID3 bash "$WH" --session-id CLIID <<<'{"session_id":"PAYLOADID3"}' >/dev/null 2>&1 )
  check "precedence: flag beats payload beats env" CLIID "$(session_marker "$repo/.claude/handoff_current.md")"
  rm -rf "$repo"
else
  skip "jq missing on host — payload-precedence cases unexercisable"
fi

# =============================================================================
# 8. --restamp preserves/refreshes the marker and the HMAC still verifies.
# =============================================================================
if (( OPENSSL_OK )); then
  . "$REPO_ROOT/bin/handoff_provenance.sh"
  repo="$(mk_repo_gitignored)"
  ( cd "$repo" && bash "$WH" --session-id SIDH >/dev/null 2>&1 )
  doc="$repo/.claude/handoff_current.md"
  check "restamp/write: MAC verifies"        0 "$(handoff_mac_verify "$doc"; echo $?)"
  check "restamp/write: marker is SIDH"      SIDH "$(session_marker "$doc")"

  # Same id on --restamp: marker preserved (refreshed to the same value),
  # exactly one marker line, MAC still verifies over the rebuilt body.
  ( cd "$repo" && bash "$WH" --restamp --session-id SIDH >/dev/null 2>&1 )
  check "restamp same-id: marker still SIDH" SIDH "$(session_marker "$doc")"
  check "restamp same-id: exactly one marker" 1   "$(marker_count "$doc")"
  check "restamp same-id: MAC verifies"      0 "$(handoff_mac_verify "$doc"; echo $?)"

  # Different id on --restamp: marker REFRESHES to the new id, MAC still
  # verifies (digest covers the rebuilt body, not the stale one).
  ( cd "$repo" && bash "$WH" --restamp --session-id SIDH2 >/dev/null 2>&1 )
  check "restamp diff-id: marker refreshed"  SIDH2 "$(session_marker "$doc")"
  check "restamp diff-id: exactly one marker" 1    "$(marker_count "$doc")"
  check "restamp diff-id: MAC verifies"      0 "$(handoff_mac_verify "$doc"; echo $?)"

  # No id on --restamp: existing marker preserved UNTOUCHED (degraded path),
  # MAC still verifies over the (marker-unchanged) rebuilt body.
  ( cd "$repo" && env -u CLAUDE_CODE_SESSION_ID bash "$WH" --restamp </dev/null >/dev/null 2>&1 )
  check "restamp no-id: marker untouched"    SIDH2 "$(session_marker "$doc")"
  check "restamp no-id: MAC verifies"        0 "$(handoff_mac_verify "$doc"; echo $?)"
  rm -rf "$repo"
else
  skip "openssl not installed — cannot build the signed-handoff controls"
fi

# =============================================================================
# 9. Same-session rewrite while STILL a placeholder (e.g. two PreCompact/
#    SessionEnd safety-net fires in one session): still no history entry, and
#    the rebuilt doc is still a placeholder (nothing curated to carry).
# =============================================================================
repo="$(mk_repo_gitignored)"
( cd "$repo" && bash "$WH" --session-id SIDI >/dev/null 2>&1 )   # 1st placeholder write
( cd "$repo" && bash "$WH" --session-id SIDI >/dev/null 2>&1 )   # 2nd, same session
doc="$repo/.claude/handoff_current.md"
check "placeholder same-id: no history dir/entries" 0   "$(hist_count "$repo")"
check "placeholder same-id: still placeholder"       yes "$(has "$(cat "$doc")" "$SENTINEL")"
check "placeholder same-id: marker is SIDI"          SIDI "$(session_marker "$doc")"
check "placeholder same-id: exactly one marker"      1    "$(marker_count "$doc")"
rm -rf "$repo"

# =============================================================================
# 10. REGRESSION: the Rules carry gate must be scoped to the Rules BIND region,
#     NOT the whole file. When the placeholder TOKEN STRING ("HANDOFF_RULES_
#     PLACEHOLDER") appears OUTSIDE that region — in curated Notes prose or a
#     pinned body — a whole-file grep concluded "rules not curated", so the
#     curated fences were dropped AND (same_session=1 skips rotation) never even
#     archived. Especially likely when dogfooding this repo, whose sessions
#     naturally mention the token in notes. Seed exactly that shape and verify
#     the curated fence survives in place.
# =============================================================================
repo="$(mk_repo_gitignored)"
mkdir -p "$repo/.claude"
{
  printf '# handoff\n\n'
  printf '%s\n' "$BIND_BEGIN"
  printf '%s\n\n' "$RULES_HDR"
  printf -- '- Do NOT force-push. CURATED_RULE_XYZ\n'
  printf '%s\n\n' "$BIND_END"
  echo '---'
  echo
  printf '## Notes from this session\n\n'
  printf 'Working on the same-session carry logic around the '
  printf 'HANDOFF_RULES_PLACEHOLDER token today; the whole-file grep was wrong.\n'
  printf '<!-- HANDOFF_SESSION: METAID -->\n'
} > "$repo/.claude/handoff_current.md"
doc="$repo/.claude/handoff_current.md"
( cd "$repo" && bash "$WH" --session-id METAID </dev/null >/dev/null 2>&1 )
after_rules="$(extract_rules "$doc")"
check "token-in-notes: curated fence carried"       yes "$(has "$after_rules" "CURATED_RULE_XYZ")"
check "token-in-notes: Rules region not placeholder" no "$(has "$after_rules" "HANDOFF_RULES_PLACEHOLDER")"
check "token-in-notes: no rotation (0 history)"     0   "$(hist_count "$repo")"
check "token-in-notes: Notes prose still carried"   yes "$(has "$(cat "$doc")" "same-session carry logic")"
rm -rf "$repo"

finish
