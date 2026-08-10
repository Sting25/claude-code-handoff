#!/usr/bin/env bash
# Portability guards for the macOS/BSD fixes:
#   - handoff_turn_append.sh: flock -> mkdir-lock fallback; tac -> grep|tail;
#     mapfile -> while-read over a process substitution.
#   - write_handoff.sh: date -u -r FILE -> portable stat+date mtime stamp.
# Behaviour is exercised on this (GNU) host for no-regression, plus the BSD
# branches are forced via tool shims / a flock-less PATH.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TA="$REPO_ROOT/bin/handoff_turn_append.sh"
WH="$REPO_ROOT/bin/write_handoff.sh"
command -v jq   >/dev/null 2>&1 || { echo "install.sh"; skip "jq missing";   finish; exit; }
command -v perl >/dev/null 2>&1 || { skip "perl missing — Stop hook needs it"; finish; exit; }

# A PATH that mirrors the real one but omits a single tool (to force a fallback).
path_without() {
  local drop="$1" shim d f b
  shim="$(mktemp -d)"
  for d in ${PATH//:/ }; do
    [[ -d "$d" ]] || continue
    for f in "$d"/*; do
      b="$(basename "$f")"
      [[ "$b" == "$drop" ]] && continue
      [[ -e "$shim/$b" ]] || ln -s "$f" "$shim/$b" 2>/dev/null || true
    done
  done
  printf '%s\n' "$shim"
}

run_turn() {  # <repo> <session_id> <transcript> [PATH override]
  local repo="$1" sid="$2" tx="$3" pathov="${4:-$PATH}"
  ( cd "$repo" && PATH="$pathov" printf '{"session_id":"%s","transcript_path":"%s"}' "$sid" "$tx" \
      | PATH="$pathov" bash "$TA" >/dev/null 2>&1 )
}

# ---------------------------------------------------------------------------
echo "handoff_turn_append.sh — token extraction + append (grep|tail)"
repo="$(mk_repo)"; bd="$repo/.claude/handoff_backups"
tx="$repo/tx.jsonl"
cat > "$tx" <<'JSONL'
{"type":"user","message":{"content":"hello there"}}
{"type":"assistant","message":{"model":"claude-old-model","content":[{"type":"text","text":"first reply"}],"usage":{"input_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
{"type":"assistant","message":{"model":"claude-fable-5","content":[{"type":"text","text":"second reply"}],"usage":{"input_tokens":200,"cache_read_input_tokens":50,"cache_creation_input_tokens":25}}}
JSONL
run_turn "$repo" S1 "$tx"
dump="$bd/handoff_raw_S1.md"
check "turn block appended"            yes "$([[ -f "$dump" ]] && grep -q 'first reply' "$dump" && echo yes || echo no)"
check "last-assistant tokens (275)"    275 "$(cat "$bd/.ctx_tokens_S1" 2>/dev/null)"
check "model from same last usage line" claude-fable-5 "$(cat "$bd/.ctx_model_S1" 2>/dev/null)"
rm -rf "$repo"

# ---------------------------------------------------------------------------
echo "handoff_turn_append.sh — prune keeps 3 newest (mapfile -> while)"
repo="$(mk_repo)"; bd="$repo/.claude/handoff_backups"; mkdir -p "$bd"
for i in 1 2 3 4 5; do
  echo x > "$bd/handoff_raw_OLD$i.md"
  echo 1 > "$bd/.handoff_raw_OLD$i.cursor"; echo 1 > "$bd/.ctx_OLD$i"
  echo m > "$bd/.ctx_model_OLD$i"
  touch -d "2026-01-0${i}T00:00:00Z" "$bd/handoff_raw_OLD$i.md"
done
tx="$repo/tx.jsonl"; printf '{"type":"user","message":{"content":"hi"}}\n' > "$tx"
run_turn "$repo" NEW "$tx"   # creates handoff_raw_NEW.md (newest) then prunes
present() { [[ -e "$bd/$1" ]] && echo yes || echo no; }
check "newest kept: NEW"      yes "$(present handoff_raw_NEW.md)"
check "kept: OLD5"            yes "$(present handoff_raw_OLD5.md)"
check "kept: OLD4"            yes "$(present handoff_raw_OLD4.md)"
check "pruned: OLD3"          no  "$(present handoff_raw_OLD3.md)"
check "pruned: OLD1"          no  "$(present handoff_raw_OLD1.md)"
check "pruned sidecar .ctx_OLD1" no "$(present .ctx_OLD1)"
check "pruned sidecar .ctx_model_OLD1" no "$(present .ctx_model_OLD1)"
rm -rf "$repo"

# ---------------------------------------------------------------------------
echo "handoff_turn_append.sh — flock-absent mkdir-lock fallback"
noflock="$(path_without flock)"
check "flock really absent on shim PATH" absent "$(PATH="$noflock" command -v flock >/dev/null 2>&1 && echo present || echo absent)"
repo="$(mk_repo)"; bd="$repo/.claude/handoff_backups"
tx="$repo/tx.jsonl"; printf '{"type":"user","message":{"content":"hi"}}\n' > "$tx"
run_turn "$repo" LK "$tx" "$noflock"
check "appends without flock"  yes "$([[ -f "$bd/handoff_raw_LK.md" ]] && echo yes || echo no)"
check "lock dir released"      no  "$([[ -d "$bd/.handoff_raw_LK.lock.d" ]] && echo yes || echo no)"
# A FRESH lock dir (holder presumed alive) blocks a fresh session: no append.
repo2="$(mk_repo)"; bd2="$repo2/.claude/handoff_backups"; mkdir -p "$bd2"
mkdir "$bd2/.handoff_raw_HELD.lock.d"
tx2="$repo2/tx.jsonl"; printf '{"type":"user","message":{"content":"hi"}}\n' > "$tx2"
run_turn "$repo2" HELD "$tx2" "$noflock"
check "fresh lock blocks append" no "$([[ -f "$bd2/handoff_raw_HELD.md" ]] && echo yes || echo no)"

# A STALE lock dir (holder killed before its EXIT trap, mtime older than the
# staleness window) must be reclaimed so the session keeps appending. Force a
# 1s window and backdate the dir so it qualifies without a real wait.
repo3="$(mk_repo)"; bd3="$repo3/.claude/handoff_backups"; mkdir -p "$bd3"
mkdir "$bd3/.handoff_raw_STALE.lock.d"
# POSIX `touch -t` (GNU + BSD); any mtime older than the forced 1s window works.
touch -t 202001010000 "$bd3/.handoff_raw_STALE.lock.d"
tx3="$repo3/tx.jsonl"; printf '{"type":"user","message":{"content":"hi"}}\n' > "$tx3"
( cd "$repo3" && PATH="$noflock" HANDOFF_LOCK_STALE_SECS=1 \
    printf '{"session_id":"STALE","transcript_path":"%s"}' "$tx3" \
    | PATH="$noflock" HANDOFF_LOCK_STALE_SECS=1 bash "$TA" >/dev/null 2>&1 )
check "stale lock reclaimed -> appends" yes "$([[ -f "$bd3/handoff_raw_STALE.md" ]] && echo yes || echo no)"
check "stale lock released after run"   no  "$([[ -d "$bd3/.handoff_raw_STALE.lock.d" ]] && echo yes || echo no)"

# DEFAULT staleness window (audit 2026-07-17): the old 60s default exactly
# equaled Claude Code's hook timeout, so a live first-fire backlog (which can
# legitimately run for minutes) could have its lock stolen by a concurrent
# fire. The default is now 300s and the holder re-touches the lock dir during
# long appends. A lock dir 120s old — stale under the OLD default, fresh under
# the new one — must NOT be reclaimed.
repo4="$(mk_repo)"; bd4="$repo4/.claude/handoff_backups"; mkdir -p "$bd4"
mkdir "$bd4/.handoff_raw_MIDAGE.lock.d"
perl -e 'utime time-120, time-120, $ARGV[0]' "$bd4/.handoff_raw_MIDAGE.lock.d"
tx4="$repo4/tx.jsonl"; printf '{"type":"user","message":{"content":"hi"}}\n' > "$tx4"
run_turn "$repo4" MIDAGE "$tx4" "$noflock"
check "120s-old lock NOT reclaimed (default now 300s)" no \
  "$([[ -f "$bd4/handoff_raw_MIDAGE.md" ]] && echo yes || echo no)"
check "120s-old lock left in place for its holder" yes \
  "$([[ -d "$bd4/.handoff_raw_MIDAGE.lock.d" ]] && echo yes || echo no)"

# PRE-LOOP REFRESH (audit 2026-08-10): the holder must refresh the lock dir's
# mtime OUTSIDE the append loop too — the loop's periodic touch only fires
# after 200 transcript lines, so a holder stalled before/after the loop (slow
# wc over a huge transcript, the whole-transcript usage scan) previously aged
# past the stale window and could be stolen mid-write. On this 1-line
# transcript the 200-line loop touch can never fire, so ANY touch of the lock
# dir must come from the new out-of-loop refreshes. Observe via a logging
# `touch` shim (delegates to the real touch) on the flock-less PATH.
noflock5="$(path_without flock)"
REAL_TOUCH="$(command -v touch)"
touch_log="$(mktemp)"
# path_without symlinked every tool (incl. touch) into the shim dir; replace
# the symlink with the logger (a `cat >` through it would hit the real binary).
rm -f "$noflock5/touch"
cat > "$noflock5/touch" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$touch_log"
exec "$REAL_TOUCH" "\$@"
EOF
chmod +x "$noflock5/touch"
repo5="$(mk_repo)"; bd5="$repo5/.claude/handoff_backups"
tx5="$repo5/tx.jsonl"; printf '{"type":"user","message":{"content":"hi"}}\n' > "$tx5"
run_turn "$repo5" RFRSH "$tx5" "$noflock5"
check "instrumented short run still appends" yes \
  "$([[ -f "$bd5/handoff_raw_RFRSH.md" ]] && echo yes || echo no)"
check "lock mtime refreshed outside the append loop" yes \
  "$(grep -q 'handoff_raw_RFRSH.lock.d' "$touch_log" && echo yes || echo no)"
rm -rf "$repo" "$repo2" "$repo3" "$repo4" "$repo5" "$noflock" "$noflock5"
rm -f "$touch_log"

# ---------------------------------------------------------------------------
echo "write_handoff.sh — rotation timestamp from file mtime (GNU + BSD)"
rotate_stamp() {  # <PATH override> -> echoes the rotated history filename
  local pathov="$1" repo
  repo="$(mk_repo)"; mkdir -p "$repo/.claude"
  echo "old handoff" > "$repo/.claude/handoff_current.md"
  touch -d "2020-03-04T05:06:07Z" "$repo/.claude/handoff_current.md"
  ( cd "$repo" && PATH="$pathov" HANDOFF_NO_GITIGNORE_BOOTSTRAP=1 bash "$WH" >/dev/null 2>&1 )
  find "$repo/.claude/handoff_history" -mindepth 1 -maxdepth 1 2>/dev/null | sed 's|.*/||' | sort | head -n 1
  rm -rf "$repo"
}
check "GNU: stamp reflects mtime" "handoff_2020-03-04_050607.md" "$(rotate_stamp "$PATH")"

# BSD shims: stat supports only -f %m, date supports only -r EPOCH. They reject
# the GNU spellings, then delegate to the real tool in whichever dialect it
# speaks (GNU translation first, BSD pass-through fallback) so the sim works on
# both GNU and BSD hosts.
# Two shim dirs, and BOTH must be registered for removal: the second
# path_without builds a FRESH directory, so assigning it back over `bsd` dropped
# the only reference to the first and leaked a ~1,600-entry directory per run.
bsd_stat_only="$(path_without stat)"
cleanup_on_exit "$bsd_stat_only"
bsd="$(PATH="$bsd_stat_only" path_without date)"  # drop both real tools
cleanup_on_exit "$bsd"
REAL_STAT="$(command -v stat)"; REAL_DATE="$(command -v date)"
cat > "$bsd/stat" <<EOF
#!/usr/bin/env bash
case " \$* " in
  *" -c "*) exit 1 ;;                                   # GNU form: unsupported
  *" -f "*) [[ "\$2" == "%m" ]] || exit 1
            "$REAL_STAT" -c %Y "\$3" 2>/dev/null && exit 0
            exec "$REAL_STAT" -f %m "\$3" ;;
esac
exit 1
EOF
cat > "$bsd/date" <<EOF
#!/usr/bin/env bash
real="$REAL_DATE"; new=(); epoch=""; have_r=0; i=1
for ((; i<=\$#; i++)); do
  a="\${!i}"
  case "\$a" in
    -d) exit 1 ;;                                        # GNU form: unsupported
    -r) have_r=1; n=\$((i+1)); epoch="\${!n}"; i=\$n ;;   # BSD: epoch arg
    *)  new+=("\$a") ;;
  esac
done
if (( have_r )); then
  "\$real" -d "@\$epoch" "\${new[@]}" 2>/dev/null && exit 0   # GNU real tool
  exec "\$real" -r "\$epoch" "\${new[@]}"                     # BSD real tool
else
  exec "\$real" "\${new[@]}"
fi
EOF
chmod +x "$bsd/stat" "$bsd/date"
check "BSD-sim: stat -c rejected"  rejected "$(PATH="$bsd" stat -c %Y "$WH" >/dev/null 2>&1 && echo ok || echo rejected)"
check "BSD-sim: stat -f works"     works    "$(PATH="$bsd" stat -f %m "$WH" >/dev/null 2>&1 && echo works || echo no)"
check "BSD-sim: date -d rejected"  rejected "$(PATH="$bsd" date -d @100 >/dev/null 2>&1 && echo ok || echo rejected)"
check "BSD-sim: stamp reflects mtime" "handoff_2020-03-04_050607.md" "$(rotate_stamp "$bsd")"
rm -rf "$bsd"

finish
