#!/usr/bin/env bash
# Behavioral coverage for handoff_statusline.sh (the statusLine command that
# prints one status line and sideband-caches CC's own window/usage numbers
# into .claude/handoff_backups/.ctx_sl_<session_id> for ctx-check).
#
# Observable: stdout (the rendered line) + the .ctx_sl_* cache file.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SL="$REPO_ROOT/bin/handoff_statusline.sh"

# Run the statusline for a payload. Trailing args are ENV=VAL overrides.
run_sl() {  # <repo> <payload-json> [ENV=VAL ...]
  local repo="$1" payload="$2"; shift 2
  ( cd "$repo" && env "$@" bash "$SL" <<<"$payload" 2>/dev/null )
}

has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }


echo "handoff_statusline.sh — line rendering + sl cache"

# --- Empty stdin -> exit 0, no output ----------------------------------------
repo="$(mk_repo)"
out="$( cd "$repo" && bash "$SL" </dev/null 2>/dev/null )"; rc=$?
check "empty stdin -> exit 0"    0  "$rc"
check "empty stdin -> no output" "" "$out"
rm -rf "$repo"

# --- jq missing -> minimal static line, no cache, exit 0 ---------------------
if command -v jq >/dev/null 2>&1; then
  nojq="$(path_without jq)"
  repo="$(mk_repo)"
  out="$( cd "$repo" && PATH="$nojq" bash "$SL" <<<'{"session_id":"NOJQ"}' 2>/dev/null )"; rc=$?
  check "no jq -> exit 0"           0   "$rc"
  check "no jq -> minimal line"     yes "$(has "$out" "jq missing")"
  check "no jq -> no cache written" no  "$([[ -e "$repo/.claude/handoff_backups/.ctx_sl_NOJQ" ]] && echo yes || echo no)"
  rm -rf "$repo" "$nojq"
else
  skip "jq present-path tests need jq"
fi

# Everything below parses the payload with jq.
command -v jq >/dev/null 2>&1 || { finish; exit; }

# Full payload: 600k of 1M used, all cache keys, 0600 perms.
full_payload() {  # <sid>
  printf '{"session_id":"%s","model":{"display_name":"Fable"},"context_window":{"context_window_size":1000000,"used_percentage":60,"current_usage":{"input_tokens":100000,"cache_read_input_tokens":400000,"cache_creation_input_tokens":100000}}}' "$1"
}

# --- Full payload -> full line + cache with all keys, 0600 -------------------
repo="$(mk_repo)"
out="$(run_sl "$repo" "$(full_payload FULL)")"; rc=$?
sl="$repo/.claude/handoff_backups/.ctx_sl_FULL"
check "full: exit 0"              0   "$rc"
check "full: model in line"       yes "$(has "$out" "Fable")"
check "full: pct in line (60%)"   yes "$(has "$out" "ctx 60%")"
check "full: k/k meter in line"   yes "$(has "$out" "(600k/1000k)")"
check "full: handoff state none"  yes "$(has "$out" "handoff: none")"
check "full: cache file exists"   yes "$([[ -f "$sl" ]] && echo yes || echo no)"
check "full: cache is 0600"       600 "$(file_mode "$sl")"
check "full: cache window="       "window=1000000" "$(grep '^window=' "$sl")"
check "full: cache tokens="       "tokens=600000"  "$(grep '^tokens=' "$sl")"
check "full: cache pct="          "pct=60"         "$(grep '^pct=' "$sl")"
check "full: cache model="        "model=Fable"    "$(grep '^model=' "$sl")"

# --- Identical repeated payload -> no mktemp litter, single stable file ------
out="$(run_sl "$repo" "$(full_payload FULL)")"
litter="$(find "$repo/.claude/handoff_backups" -name '.ctx_sl_FULL.??????' 2>/dev/null | wc -l | tr -d ' ')"
check "repeat: line still rendered"  yes "$(has "$out" "ctx 60%")"
check "repeat: no tmp litter"        0   "$litter"
rm -rf "$repo"

# --- current_usage null -> tokens derived from used_percentage ---------------
repo="$(mk_repo)"
out="$(run_sl "$repo" '{"session_id":"PCT","context_window":{"context_window_size":200000,"used_percentage":42.5,"current_usage":null}}')"
sl="$repo/.claude/handoff_backups/.ctx_sl_PCT"
# 42.5 integer-truncates to 42 -> 84000 tokens of 200k.
check "pct-derived: line shows 42%"     yes "$(has "$out" "ctx 42%")"
check "pct-derived: cache tokens=84000" "tokens=84000" "$(grep '^tokens=' "$sl")"
check "pct-derived: cache pct raw"      "pct=42.5"     "$(grep '^pct=' "$sl")"
rm -rf "$repo"

# --- NEGATIVE CONTROL (the CC 2.1.132 hazard): total_input_tokens is NEVER
#     read. current_usage null, no used_percentage, a huge cumulative
#     total_input_tokens -> tokens omitted entirely, not "measured" from the
#     wrong field. -----------------------------------------------------------
repo="$(mk_repo)"
out="$(run_sl "$repo" '{"session_id":"TOT","model":{"id":"m1"},"context_window":{"context_window_size":200000,"current_usage":null,"total_input_tokens":99999999}}')"
sl="$repo/.claude/handoff_backups/.ctx_sl_TOT"
check "total_* ignored: no ctx segment"    no  "$(has "$out" "ctx ")"
check "total_* ignored: no tokens= line"   ""  "$(grep '^tokens=' "$sl" 2>/dev/null)"
check "total_* ignored: window cached"     "window=200000" "$(grep '^window=' "$sl")"
rm -rf "$repo"

# --- No context_window at all (pre-2.1.6 CC) -> model-only line, exit 0 ------
repo="$(mk_repo)"
out="$(run_sl "$repo" '{"session_id":"OLD","model":{"display_name":"Old CC"}}')"; rc=$?
check "no context_window: exit 0"       0   "$rc"
check "no context_window: model shown"  yes "$(has "$out" "Old CC")"
check "no context_window: no ctx seg"   no  "$(has "$out" "ctx ")"
check "no context_window: handoff seg"  yes "$(has "$out" "handoff: none")"
rm -rf "$repo"

# --- session_id charset guard: line printed, NO file escapes backup_dir ------
# NEGATIVE CONTROL: for sid "../evil" the naive path would be
# .claude/handoff_backups/.ctx_sl_../evil -> .claude/evil (an escape).
repo="$(mk_repo)"
out="$(run_sl "$repo" '{"session_id":"../evil","context_window":{"context_window_size":200000,"used_percentage":10}}')"; rc=$?
check "bad sid: exit 0"          0   "$rc"
check "bad sid: line printed"    yes "$(has "$out" "ctx 10%")"
check "bad sid: no escape file"  no  "$([[ -e "$repo/.claude/evil" || -e "$repo/.claude/handoff_backups/evil" ]] && echo yes || echo no)"
check "bad sid: no cache at all" 0   "$(find "$repo/.claude/handoff_backups" -name '.ctx_sl_*' 2>/dev/null | wc -l | tr -d ' ')"
rm -rf "$repo"

# --- Planted symlink at the cache path -> replaced by a regular file, target
#     untouched (mv replaces the link NAME, never writes through it) ----------
repo="$(mk_repo)"; bd="$repo/.claude/handoff_backups"
must mkdir -p "$bd"
victim="$repo/victim.txt"
must cat > "$victim" <<'EOF'
PRISTINE
EOF
must ln -s "$victim" "$bd/.ctx_sl_LNK"
run_sl "$repo" "$(full_payload LNK)" >/dev/null
check "symlink: cache now regular file" no  "$([[ -L "$bd/.ctx_sl_LNK" ]] && echo yes || echo no)"
check "symlink: cache has real content" yes "$(has "$(cat "$bd/.ctx_sl_LNK")" "window=1000000")"
check "symlink: target untouched"       "PRISTINE" "$(cat "$victim")"
rm -rf "$repo"

# --- Stale-cache janitor: a successful cache write reaps sibling .ctx_sl_*
#     files >7 days old — but ONLY files it can PROVE it generated (exact
#     .ctx_sl_<sid> name, regular file, cache-shaped key=value content), per
#     the retention rule that the tool never deletes by glob+mtime alone.
#     Sessions that render a statusline but never complete a turn get no
#     handoff_raw_ dump, so the Stop-hook prune never names them — without
#     this, their caches would accumulate forever. -------------
repo="$(mk_repo)"; bd="$repo/.claude/handoff_backups"
must mkdir -p "$bd"
# Orphaned cache from a long-dead session, real cache shape -> prune candidate.
must cat > "$bd/.ctx_sl_STALE" <<'EOF'
window=200000
tokens=50000
pct=25
model=Fable
EOF
# NEGATIVE CONTROLS — all aged >7d, all must SURVIVE the janitor:
#   a user's hand-dropped file: glob-matches, but the dot fails the sid
#   charset AND the content isn't cache-shaped;
must cat > "$bd/.ctx_sl_notes.backup" <<'EOF'
my precious notes, do not delete
EOF
#   an exact-name file whose CONTENT is not cache-shaped (not provably ours);
must cat > "$bd/.ctx_sl_USERDATA" <<'EOF'
window=200000
window dressing: this line is prose, not a cache entry
EOF
#   an orphaned mktemp temp — safe-direction trade-off: its suffix is
#   indistinguishable from a user's ".backup"-style name, so it now lingers;
: > "$bd/.ctx_sl_GONE.a1b2c3"
must touch -t 202001010000 "$bd/.ctx_sl_STALE" "$bd/.ctx_sl_notes.backup" \
  "$bd/.ctx_sl_USERDATA" "$bd/.ctx_sl_GONE.a1b2c3"
#   a symlink named like a cache, pointing at a real-shaped victim: -type f /
#   the -L re-check must exclude it (age the LINK itself where touch -h
#   exists; -type f excludes it regardless).
sym_victim="$repo/sym_victim.txt"
must cat > "$sym_victim" <<'EOF'
window=1000000
tokens=1
EOF
must ln -s "$sym_victim" "$bd/.ctx_sl_SYMOLD"
touch -h -t 202001010000 "$bd/.ctx_sl_SYMOLD" 2>/dev/null || true
: > "$bd/.ctx_sl_FRESH"          # recent sibling (another live session)
run_sl "$repo" "$(full_payload PRUNE)" >/dev/null; rc=$?
check "prune: exit 0"                     0   "$rc"
check "prune: new cache written"          yes "$([[ -f "$bd/.ctx_sl_PRUNE" ]] && echo yes || echo no)"
check "prune: stale owned cache removed"  no  "$([[ -e "$bd/.ctx_sl_STALE" ]] && echo yes || echo no)"
check "prune: user file survives"         yes "$([[ -f "$bd/.ctx_sl_notes.backup" ]] && echo yes || echo no)"
check "prune: user file content intact"   "my precious notes, do not delete" "$(cat "$bd/.ctx_sl_notes.backup")"
check "prune: non-cache-shaped survives"  yes "$([[ -f "$bd/.ctx_sl_USERDATA" ]] && echo yes || echo no)"
check "prune: tmp litter lingers (safe)"  yes "$([[ -e "$bd/.ctx_sl_GONE.a1b2c3" ]] && echo yes || echo no)"
check "prune: symlink survives as link"   yes "$([[ -L "$bd/.ctx_sl_SYMOLD" ]] && echo yes || echo no)"
check "prune: symlink victim intact"      yes "$(grep -q '^window=1000000$' "$sym_victim" && echo yes || echo no)"
check "prune: fresh sibling kept (ctrl)"  yes "$([[ -f "$bd/.ctx_sl_FRESH" ]] && echo yes || echo no)"
rm -rf "$repo"

# --- Handoff state segment: none / auto / curated ----------------------------
repo="$(mk_repo)"; must mkdir -p "$repo/.claude"
payload='{"session_id":"HS","context_window":{"context_window_size":200000,"used_percentage":10}}'
check "state: none (no handoff file)" yes "$(has "$(run_sl "$repo" "$payload")" "handoff: none")"
must cat > "$repo/.claude/handoff_current.md" <<'EOF'
# h

## Notes from this session

<!-- HANDOFF_PLACEHOLDER: keep until /handoff replaces this block -->
EOF
check "state: auto (sentinel present)" yes "$(has "$(run_sl "$repo" "$payload")" "handoff: auto")"
must cat > "$repo/.claude/handoff_current.md" <<'EOF'
# h

## Notes from this session

real notes
EOF
check "state: curated (sentinel gone)" yes "$(has "$(run_sl "$repo" "$payload")" "handoff: curated")"
rm -rf "$repo"

finish
