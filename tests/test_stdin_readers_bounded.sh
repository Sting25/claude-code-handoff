#!/usr/bin/env bash
# The six remaining hook-side stdin readers must never block on an OPEN,
# SILENT stdin (issue #160; same defect and fix as write_handoff.sh, #158):
#   handoff_session_start.sh, handoff_compact_reset.sh, handoff_ctx_check.sh,
#   handoff_worktree_remove.sh, handoff_statusline.sh, handoff_turn_append.sh
# Claude Code writes the JSON and closes stdin, so this only bites hand runs,
# the Bash tool and test runners (hardening, not a hook fix). Each reader now
# carries a copy of read_hook_payload() from write_handoff.sh (the canonical
# one): wait HANDOFF_STDIN_TIMEOUT whole seconds for a first byte, then drain.
#
# Proves, per reader: (a) an open FIFO that never delivers returns within
# HANDOFF_STDIN_TIMEOUT+1 s, (b) a real payload is still read with and without
# a trailing newline, (c) the statusline (300 ms cadence) does not wait on an
# empty CLOSED pipe, (d) the six copies have not drifted from the canonical.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BIN="$REPO_ROOT/bin"
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

# Same bounded-runner shape as test_write_handoff_stdin_open.sh: the subject's
# stdin is fd 3 (the open FIFO), redirected ON the backgrounded command, since
# a bare `&` job would get /dev/null and silently test the working case.
run_bounded() {  # <max_seconds> <cmd...> -> "done <rc>" or "hung"
  local max="$1" i pid rc; shift
  "$@" <&3 >/dev/null 2>&1 &
  pid=$!
  for (( i = 0; i < max * 5; i++ )); do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid"; rc=$?
      echo "done $rc"; return 0
    fi
    sleep 0.2
  done
  kill_tree "$pid"
  wait "$pid" 2>/dev/null
  echo hung
}
kill_tree() {  # <pid>
  local c
  for c in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$c"; done
  kill "$1" 2>/dev/null || true
}
now_ms() { perl -MTime::HiRes=time -e 'printf "%d", time()*1000'; }

fifo_dir="$(mktemp -d)"; cleanup_on_exit "$fifo_dir"
must mkfifo "$fifo_dir/open_stdin"
exec 3<>"$fifo_dir/open_stdin"

echo "stdin readers: bounded first read (issue #160)"

NAMES="session_start compact_reset ctx_check worktree_remove statusline turn_append"

# --- 1. open, silent stdin: returns within HANDOFF_STDIN_TIMEOUT+1 s ---------
# HANDOFF_STDIN_TIMEOUT=1, so the ceiling is 2 s; the unbounded cat never
# returns, so a pass cannot be a lucky race.
for n in $NAMES; do
  repo="$(mk_repo)"
  t0="$(now_ms)"
  res="$( cd "$repo" && HANDOFF_STDIN_TIMEOUT=1 run_bounded 2 bash "$BIN/handoff_$n.sh" )"
  t1="$(now_ms)"
  check "1 $n: open silent stdin returns, exit 0" "done 0" "$res"
  echo "  (info) $n open-FIFO return: $((t1-t0)) ms"
  rm -rf "$repo"
done
exec 3>&-

# --- 2. a real payload is still read, with and without trailing newline ------
# Per reader: how to feed it and what proves the payload was parsed.
# send <mode> prints the JSON for the reader; mode nl|nonl chooses the ending.
feed() {  # <mode> <json>
  if [[ "$1" == nl ]]; then printf '%s\n' "$2"; else printf '%s' "$2"; fi
}
for mode in nl nonl; do
  # session_start: payload "cwd" redirects root resolution to a repo that has a
  # handoff; the marker only appears if the payload was read.
  a="$(mk_repo)"; b="$(mk_repo)"; mkdir -p "$b/.claude"
  printf '# h\nMARKER_SS_%s\n' "$mode" > "$b/.claude/handoff_current.md"
  out="$( cd "$a" && feed "$mode" "{\"source\":\"startup\",\"cwd\":\"$b\"}" \
      | bash "$BIN/handoff_session_start.sh" 2>&1 )"
  check "2 session_start ($mode): payload read" yes "$(has "$out" "MARKER_SS_$mode")"
  rm -rf "$a" "$b"

  # compact_reset: deletes the session's sidecars only if session_id was parsed.
  repo="$(mk_repo)"; bd="$repo/.claude/handoff_backups"; mkdir -p "$bd"
  printf 4000 > "$bd/.ctx_CR"; printf 600 > "$bd/.ctx_tokens_CR"
  ( cd "$repo" && feed "$mode" '{"session_id":"CR"}' | bash "$BIN/handoff_compact_reset.sh" >/dev/null 2>&1 )
  check "2 compact_reset ($mode): payload read" no "$([[ -e "$bd/.ctx_CR" ]] && echo yes || echo no)"
  rm -rf "$repo"

  # ctx_check: over-threshold sidecars emit a nudge only if session_id parsed.
  repo="$(mk_repo)"; bd="$repo/.claude/handoff_backups"; mkdir -p "$bd"
  printf 4000 > "$bd/.ctx_CC"; printf 700 > "$bd/.ctx_tokens_CC"
  out="$( cd "$repo" && feed "$mode" '{"session_id":"CC"}' \
      | HANDOFF_CTX_WINDOW_TOKENS=1000 bash "$BIN/handoff_ctx_check.sh" 2>/dev/null )"
  check "2 ctx_check ($mode): payload read" yes "$(has "$out" "Context at")"
  rm -rf "$repo"

  # worktree_remove: reports the missing worktree_path only if it was parsed.
  repo="$(mk_repo)"
  out="$( cd "$repo" && feed "$mode" '{"worktree_path":"/nonexistent/wt160","cwd":"/nonexistent"}' \
      | bash "$BIN/handoff_worktree_remove.sh" 2>&1 )"
  check "2 worktree_remove ($mode): payload read" yes "$(has "$out" "wt160")"
  rm -rf "$repo"

  # turn_append: creates the per-session dump only if the payload was parsed.
  if command -v jq >/dev/null 2>&1; then
    repo="$(mk_repo)"; tx="$repo/tx.jsonl"
    printf '{"type":"user","message":{"content":"hello"}}\n' > "$tx"
    ( cd "$repo" && feed "$mode" "{\"session_id\":\"TA\",\"transcript_path\":\"$tx\"}" \
        | bash "$BIN/handoff_turn_append.sh" >/dev/null 2>&1 )
    check "2 turn_append ($mode): payload read" yes \
      "$([[ -f "$repo/.claude/handoff_backups/handoff_raw_TA.md" ]] && echo yes || echo no)"
    rm -rf "$repo"
  fi

  # statusline: renders a line only if a payload arrived.
  repo="$(mk_repo)"
  out="$( cd "$repo" && feed "$mode" '{"session_id":"SL"}' | bash "$BIN/handoff_statusline.sh" 2>/dev/null )"
  check "2 statusline ($mode): payload read" yes "$(has "$out" "handoff:")"
  rm -rf "$repo"
done

# multi-line payload (first line read, rest drained), via the statusline.
repo="$(mk_repo)"
out="$( cd "$repo" && printf '{\n  "session_id": "SLM"\n}\n' | bash "$BIN/handoff_statusline.sh" 2>/dev/null )"
check "2 statusline (multi-line): payload read" yes "$(has "$out" "handoff:")"
rm -rf "$repo"

# --- 3. statusline on an empty CLOSED pipe must not wait ---------------------
# A closed pipe is EOF at once; the default 2 s timeout must never be paid.
repo="$(mk_repo)"
t0="$(now_ms)"
out="$( cd "$repo" && : | bash "$BIN/handoff_statusline.sh" 2>/dev/null )"
t1="$(now_ms)"
ms=$((t1-t0))
echo "  (info) statusline empty closed pipe: ${ms} ms (default HANDOFF_STDIN_TIMEOUT)"
check "3 statusline: empty closed pipe -> no output" "" "$out"
check "3 statusline: empty closed pipe returns < 1000 ms" yes "$([[ $ms -lt 1000 ]] && echo yes || echo no)"
rm -rf "$repo"

# --- 3b. oversized HANDOFF_STDIN_TIMEOUT falls back to the default ----------
# 20 digits passes a bare digit test but `read -t` rejects it; the payload
# must still be read (statusline renders a line only when it was).
repo="$(mk_repo)"
out="$( cd "$repo" && printf '{"session_id":"BIGT"}\n' \
    | HANDOFF_STDIN_TIMEOUT=99999999999999999999 bash "$BIN/handoff_statusline.sh" 2>/dev/null )"
check "3b oversized HANDOFF_STDIN_TIMEOUT -> payload still read" yes "$(has "$out" "handoff:")"
rm -rf "$repo"

# --- 4. drift: each copy equals the canonical read_hook_payload() -----------
extract() {  # <file> -> the function body, from its opener to the closing brace
  awk '/^read_hook_payload\(\) \{/ {p=1} p {print} p && /^}$/ {exit}' "$1"
}
canon="$(extract "$BIN/write_handoff.sh" | cksum)"
check "4 canonical read_hook_payload found" yes "$([[ -n "$(extract "$BIN/write_handoff.sh")" ]] && echo yes || echo no)"
for n in $NAMES; do
  check "4 $n: copy matches write_handoff.sh" "$canon" "$(extract "$BIN/handoff_$n.sh" | cksum)"
done

# --- 5. a large single-line payload survives on bash 3.2 (issue #169) -------
# `read -t` bounded the WHOLE first line; bash 3.2 reads a pipe byte by byte,
# so an 8 MB one-line payload hit the 2 s timeout and came back empty. The
# timeout must cover the first byte only. Run the canonical function under the
# system /bin/bash (3.2 on macOS) and count the bytes it returns. Note: the
# path is hardcoded, so on Linux CI (bash 5) this section may be unable to
# fail; it only proves the regression on macOS bash 3.2.
extract_fn() { awk '/^read_hook_payload\(\) \{/ {p=1} p {print} p && /^}$/ {exit}' "$BIN/write_handoff.sh"; }
fn_src="$(extract_fn)"
got="$(perl -e 'print "x" x 8000000' | /bin/bash -c "$fn_src"$'\n''read_hook_payload | wc -c' | tr -d ' ')"
check "5 8 MB single-line payload fully read (/bin/bash)" 8000000 "$got"
got="$(printf '{"a":1}\nrest\n' | /bin/bash -c "$fn_src"$'\n''read_hook_payload' | cksum)"
check "5 multi-line payload unchanged (/bin/bash)" "$(printf '{"a":1}\nrest' | cksum)" "$got"

finish
