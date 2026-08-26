#!/usr/bin/env bash
# Coverage for the jq runtime-dependency checks (audit 2026-07-17): jq going
# missing used to disable the Stop hook, the ctx nudge, and the recover-tail
# rescue SILENTLY (every call site is wired '|| true'), while install.sh still
# printed "done" and --doctor reported all-healthy. Now:
#   - install.sh (install mode) refuses up front with a clear error;
#   - install.sh --doctor reports jq as BROKEN and exits non-zero;
#   - handoff_session_start.sh warns visibly (it needs no jq itself);
#   - handoff_recover_tail.sh errors instead of printing an empty "recovery".
#
# Issue #68 closed the two remaining holdouts. The installer gate above only
# ever protected the BARE-SCRIPTS channel — a plugin install wires
# hooks/hooks.json and never runs install.sh — so the Stop hook and the ctx
# nudge still failed silently on that path. Both now preflight jq and say so
# on STDOUT (stderr is what the `2>/dev/null || true` hook wiring discards),
# once per session via a shared .ctx_nojq_<sid> marker.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "jq-missing behavior — install / doctor / session_start / recover_tail"

# The positive-control setups below need a real jq (mirrors the suite's
# convention of skipping jq-dependent files outright when it's absent).
if ! command -v jq >/dev/null 2>&1; then
  skip "jq not installed — cannot build the with-jq controls"
  finish
  exit
fi

has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

nojq="$(path_without jq)"
check "jq really absent on shim PATH" absent \
  "$(PATH="$nojq" command -v jq >/dev/null 2>&1 && echo present || echo absent)"

# --- install.sh refuses to install without jq --------------------------------
home="$(mktemp -d)"
out="$(PATH="$nojq" CLAUDE_HOME="$home" bash "$REPO_ROOT/install.sh" 2>&1)"; rc=$?
check "install w/o jq: nonzero exit"      nonzero "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)"
check "install w/o jq: names jq"          yes     "$(has "$out" "jq not found")"
check "install w/o jq: does not say done" no      "$(has "$out" "/handoff is available now")"
check "install w/o jq: nothing installed" no      "$([[ -e "$home/bin/handoff_session_start.sh" ]] && echo yes || echo no)"
rm -rf "$home"

# --- install.sh --doctor flags a healthy-looking install as broken -----------
home="$(mktemp -d)"
CLAUDE_HOME="$home" bash "$REPO_ROOT/install.sh" --copy >/dev/null 2>&1
out="$(CLAUDE_HOME="$home" bash "$REPO_ROOT/install.sh" --doctor 2>&1)"; rc=$?
check "doctor with jq: exit 0"            0       "$rc"
check "doctor with jq: no jq complaint"   no      "$(has "$out" "jq not found")"
out="$(PATH="$nojq" CLAUDE_HOME="$home" bash "$REPO_ROOT/install.sh" --doctor 2>&1)"; rc=$?
check "doctor w/o jq: nonzero exit"       nonzero "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)"
check "doctor w/o jq: reports jq BROKEN"  yes     "$(has "$out" "jq not found")"
rm -rf "$home"

# --- handoff_session_start.sh warns, but still loads the handoff -------------
proj="$(mktemp -d)"; must mkdir -p "$proj/.claude"
must cat > "$proj/.claude/handoff_current.md" <<'EOF'
# handoff
## Notes from this session
Curated notes. JQLESS_MARKER
EOF
out="$( cd "$proj" && PATH="$nojq" CLAUDE_PROJECT_DIR="$proj" \
    bash "$REPO_ROOT/bin/handoff_session_start.sh" 2>&1 )"; rc=$?
check "session_start w/o jq: exit 0 (non-fatal)"  0   "$rc"
check "session_start w/o jq: warns about jq"      yes "$(has "$out" "jq not found")"
check "session_start w/o jq: handoff still loads" yes "$(has "$out" "JQLESS_MARKER")"
out="$( cd "$proj" && CLAUDE_PROJECT_DIR="$proj" \
    bash "$REPO_ROOT/bin/handoff_session_start.sh" 2>&1 )"
check "session_start with jq: no warning"         no  "$(has "$out" "jq not found")"
rm -rf "$proj"

# --- handoff_recover_tail.sh errors instead of an empty 'recovery' -----------
out="$(PATH="$nojq" HANDOFF_BACKUP_DIR="$(mktemp -d)" \
    bash "$REPO_ROOT/bin/handoff_recover_tail.sh" SOMESESSION 2>&1)"; rc=$?
check "recover_tail w/o jq: nonzero exit"         nonzero "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)"
check "recover_tail w/o jq: says why"             yes     "$(has "$out" "jq not found")"
check "recover_tail w/o jq: no fake tail header"  no      "$(has "$out" "Recovered tail")"

# --- handoff_turn_append.sh (Stop hook) warns instead of dying at 127 --------
# Before #68 this exited 127 with "jq: command not found" on stderr, which the
# hook wiring discards — no dump, no sidecars, no message, exit status hidden.
proj="$(mk_repo)"; cleanup_on_exit "$proj"
tp="$proj/transcript.jsonl"
must printf '%s\n' '{"type":"user","message":{"content":"hi"}}' > "$tp"
sid="JQSESSION"
pay="{\"session_id\":\"$sid\",\"cwd\":\"$proj\",\"transcript_path\":\"$tp\"}"
run_ta() { ( cd "$proj" && printf '%s' "$pay" \
    | PATH="$nojq" CLAUDE_PROJECT_DIR="$proj" bash "$REPO_ROOT/bin/handoff_turn_append.sh" 2>/dev/null ); }

out="$(run_ta)"; rc=$?
check "turn_append w/o jq: exit 0 (not 127)"      0   "$rc"
check "turn_append w/o jq: warns on stdout"       yes "$(has "$out" "jq not found")"
check "turn_append w/o jq: says what is disabled" yes "$(has "$out" "per-turn backup")"
check "turn_append w/o jq: no dump written"       no \
  "$([[ -f "$proj/.claude/handoff_backups/handoff_raw_$sid.md" ]] && echo yes || echo no)"
check "turn_append w/o jq: marker recorded"       yes \
  "$([[ -f "$proj/.claude/handoff_backups/.ctx_nojq_$sid" ]] && echo yes || echo no)"
# Once per session: a Stop hook fires every turn, so a per-turn repeat would nag.
out="$(run_ta)"
check "turn_append w/o jq: silent on re-fire"     no  "$(has "$out" "jq not found")"
# Positive control: with jq the preflight is invisible and the dump lands.
out="$( cd "$proj" && printf '%s' "$pay" \
    | CLAUDE_PROJECT_DIR="$proj" bash "$REPO_ROOT/bin/handoff_turn_append.sh" 2>/dev/null )"
check "turn_append with jq: no warning"           no  "$(has "$out" "jq not found")"
check "turn_append with jq: dump written"         yes \
  "$([[ -f "$proj/.claude/handoff_backups/handoff_raw_$sid.md" ]] && echo yes || echo no)"

# --- handoff_ctx_check.sh (UserPromptSubmit) warns instead of exiting mute ---
# Its jq calls were already `|| true`-guarded, so it exited 0 having emitted
# nothing — indistinguishable from "nothing to report" for every prompt.
proj2="$(mk_repo)"; cleanup_on_exit "$proj2"
run_cc_nojq() {  # <sid>
  ( cd "$proj2" && printf '{"session_id":"%s","cwd":"%s"}' "$1" "$proj2" \
      | PATH="$nojq" CLAUDE_PROJECT_DIR="$proj2" bash "$REPO_ROOT/bin/handoff_ctx_check.sh" 2>/dev/null )
}
out="$(run_cc_nojq CCSESSION)"; rc=$?
check "ctx_check w/o jq: exit 0"                  0   "$rc"
check "ctx_check w/o jq: warns"                   yes "$(has "$out" "jq not found")"
check "ctx_check w/o jq: names the nudge"         yes "$(has "$out" "context nudge")"
out="$(run_cc_nojq CCSESSION)"
check "ctx_check w/o jq: silent on re-fire"       no  "$(has "$out" "jq not found")"
# A DIFFERENT session warns again — the marker is per-session, not per-repo.
out="$(run_cc_nojq OTHERSESSION)"
check "ctx_check w/o jq: new session warns again" yes "$(has "$out" "jq not found")"
# The two hooks share the marker, so whichever speaks first silences the other.
out="$( cd "$proj2" && printf '{"session_id":"CCSESSION","cwd":"%s","transcript_path":"%s"}' "$proj2" "$tp" \
    | PATH="$nojq" CLAUDE_PROJECT_DIR="$proj2" bash "$REPO_ROOT/bin/handoff_turn_append.sh" 2>/dev/null )"
check "shared marker: Stop hook quiet after ctx"  no  "$(has "$out" "jq not found")"

# --- F6: an empty/invalid session id must still throttle -----------------
# Before the fix, an unparseable/invalid session_id left the once-per-session
# marker path empty, which the "warn anyway" branch treats identically to a
# genuinely-unwritable directory, so EVERY UserPromptSubmit re-emitted the
# ~330-char jq warning into context for a session whose id never parses. The
# fix falls back to a fixed `.ctx_nojq_unknown` marker so throttling still
# applies; only a truly unwritable backups dir keeps the warn-every-time path.
proj3="$(mk_repo)"; cleanup_on_exit "$proj3"
run_cc_nojq_badsid() {  # <session_id (raw, may be invalid/absent)>
  ( cd "$proj3" && printf '{"session_id":"%s","cwd":"%s"}' "$1" "$proj3" \
      | PATH="$nojq" CLAUDE_PROJECT_DIR="$proj3" bash "$REPO_ROOT/bin/handoff_ctx_check.sh" 2>/dev/null )
}
# A slash fails the [A-Za-z0-9_-]+ charset guard -> nojq_sid ends up empty.
out="$(run_cc_nojq_badsid "in/valid")"; rc=$?
check "invalid sid w/o jq: exit 0"            0   "$rc"
check "invalid sid w/o jq: warns first time"  yes "$(has "$out" "jq not found")"
check "invalid sid w/o jq: marker recorded"   yes \
  "$([[ -f "$proj3/.claude/handoff_backups/.ctx_nojq_unknown" ]] && echo yes || echo no)"
out="$(run_cc_nojq_badsid "another/invalid")"
check "invalid sid w/o jq: silent on re-fire" no  "$(has "$out" "jq not found")"
rm -rf "$proj3"

# Same fallback applies to handoff_turn_append.sh's identical preflight.
proj4="$(mk_repo)"; cleanup_on_exit "$proj4"
tp4="$proj4/transcript.jsonl"
must printf '%s\n' '{"type":"user","message":{"content":"hi"}}' > "$tp4"
run_ta_badsid() {
  ( cd "$proj4" && printf '{"session_id":"in/valid","cwd":"%s","transcript_path":"%s"}' "$proj4" "$tp4" \
      | PATH="$nojq" CLAUDE_PROJECT_DIR="$proj4" bash "$REPO_ROOT/bin/handoff_turn_append.sh" 2>/dev/null )
}
out="$(run_ta_badsid)"; rc=$?
check "turn_append invalid sid w/o jq: exit 0"           0   "$rc"
check "turn_append invalid sid w/o jq: warns first time" yes "$(has "$out" "jq not found")"
check "turn_append invalid sid w/o jq: marker recorded"  yes \
  "$([[ -f "$proj4/.claude/handoff_backups/.ctx_nojq_unknown" ]] && echo yes || echo no)"
out="$(run_ta_badsid)"
check "turn_append invalid sid w/o jq: silent on re-fire" no "$(has "$out" "jq not found")"
rm -rf "$proj4"

rm -rf "$nojq"
finish
