#!/usr/bin/env bash
# write_handoff.sh must never block on an OPEN, SILENT stdin (issue #158).
#
# The Claude Code Bash tool runs the /handoff skill's `write_handoff.sh
# --restamp` with stdin attached to a unix socket that is not a tty and never
# sends EOF. The old guard was `[[ -t 0 ]] || payload="$(cat)"`: fine for a
# terminal (tty -> skip) and for a hook (Node writes the JSON and closes its
# end -> EOF), but a socket that stays open made `cat` wait forever and the
# skill hung for minutes until the process was killed by hand.
#
# The distinguishing property is NOT the fd type (hooks also get a socket pair
# from Node), it is whether anything ever arrives. So the read is bounded: wait
# up to HANDOFF_STDIN_TIMEOUT seconds (integer, default 2) for the first line;
# only once bytes or EOF arrived, drain to EOF. This file proves both halves:
# an open silent stdin returns promptly and behaves exactly like </dev/null;
# a real payload (with or without a trailing newline, multi-line, or written a
# moment after spawn) is still read in full.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WH="$REPO_ROOT/bin/write_handoff.sh"
SENTINEL="<!-- HANDOFF_PLACEHOLDER: keep until /handoff replaces this block -->"
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

# Wall-clock bound for the subject: macOS has no `timeout`, so run it in the
# background and poll. Echoes "done <rc>" or "hung" (and kills the subject).
# The 15 s ceiling is far above the 1 s HANDOFF_STDIN_TIMEOUT the tests set,
# so a pass cannot be a lucky race, and far below the minutes the bug cost.
# The subject's stdin is fd 3 (the open FIFO below), redirected ON the
# backgrounded command itself: without an explicit fd-0 redirect bash gives a
# `&` job /dev/null as stdin, which would silently turn this into the
# already-working </dev/null case (measured: the unfixed script passed).
run_bounded() {  # <max_seconds> <cmd...>
  local max="$1" i pid rc; shift
  "$@" <&3 &
  pid=$!
  for (( i = 0; i < max; i++ )); do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid"; rc=$?
      echo "done $rc"; return 0
    fi
    sleep 1
  done
  # A hung subject is bash -> $(...) subshell -> cat, all blocked on the FIFO.
  # Kill the whole tree, leaves first, or the orphans outlive the test run
  # (measured on the unfixed script: three bash+cat pairs survived a plain
  # kill of the top pid).
  kill_tree "$pid"
  wait "$pid" 2>/dev/null
  echo hung
}
kill_tree() {  # <pid>
  local c
  for c in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$c"; done
  kill "$1" 2>/dev/null || true
}

seed_placeholder() {  # <repo> <name>
  mkdir -p "$1/.claude"
  cat > "$1/.claude/handoff_current.md" <<EOT
# handoff
MARKER_$2

## Notes from this session

$SENTINEL

_auto placeholder prose_
EOT
}
outcome() {  # <repo> <name> -> write|skip
  if grep -qF "MARKER_$2" "$1/.claude/handoff_current.md" 2>/dev/null; then
    echo skip
  else
    echo write
  fi
}

# An open-for-read-and-write FIFO is the portable stand-in for the Bash tool's
# socket: not a tty, never EOF while fd 3 stays open in this shell.
fifo_dir="$(mktemp -d)"; cleanup_on_exit "$fifo_dir"
must mkfifo "$fifo_dir/open_stdin"
exec 3<>"$fifo_dir/open_stdin"

echo "write_handoff.sh — bounded stdin read (issue #158)"

# --- 1. plain write with an open, silent stdin returns and writes -----------
repo="$(mk_repo)"
res="$( cd "$repo" && HANDOFF_NO_GITIGNORE_BOOTSTRAP=1 HANDOFF_STDIN_TIMEOUT=1 \
    run_bounded 15 bash "$WH" 2>/dev/null | tail -n 1 )"
check "1: plain write returns (not hung)"      yes "$(has "$res" "done")"
check "1: plain write exit 0"                  "done 0" "$res"
check "1: handoff_current.md written"          yes "$([[ -f "$repo/.claude/handoff_current.md" ]] && echo yes || echo no)"
rm -rf "$repo"

# --- 2. --restamp with an open, silent stdin (the exact /handoff step) ------
repo="$(mk_repo)"
( cd "$repo" && HANDOFF_NO_GITIGNORE_BOOTSTRAP=1 bash "$WH" </dev/null >/dev/null 2>&1 )
ref_rc=$( cd "$repo" && HANDOFF_NO_GITIGNORE_BOOTSTRAP=1 bash "$WH" --restamp </dev/null >/dev/null 2>&1; echo $? )
res="$( cd "$repo" && HANDOFF_NO_GITIGNORE_BOOTSTRAP=1 HANDOFF_STDIN_TIMEOUT=1 \
    run_bounded 15 bash "$WH" --restamp 2>/dev/null | tail -n 1 )"
check "2: --restamp returns (not hung)"        yes "$(has "$res" "done")"
check "2: --restamp exit matches </dev/null"   "done $ref_rc" "$res"
rm -rf "$repo"

# --- 3. --if-curated + open stdin: no payload -> degrades to WRITE ----------
repo="$(mk_repo)"; seed_placeholder "$repo" OPEN
res="$( cd "$repo" && HANDOFF_NO_GITIGNORE_BOOTSTRAP=1 HANDOFF_STDIN_TIMEOUT=1 \
    run_bounded 15 bash "$WH" --if-curated 2>/dev/null | tail -n 1 )"
check "3: --if-curated returns (not hung)"     "done 0" "$res"
check "3: no payload -> writes (safety net kept)" write "$(outcome "$repo" OPEN)"
rm -rf "$repo"

exec 3>&-

# --- 4. a real payload is still read in full -------------------------------
# 4a: no trailing newline (a single `read` sees EOF with partial data).
repo="$(mk_repo)"; seed_placeholder "$repo" NONL
( cd "$repo" && HANDOFF_NO_GITIGNORE_BOOTSTRAP=1 \
    printf '{"reason":"resume"}' | bash "$WH" --if-curated >/dev/null 2>&1 )
check "4a: payload without newline -> resume skip" skip "$(outcome "$repo" NONL)"
rm -rf "$repo"

# 4b: multi-line JSON, reason on the second line (first line read, rest drained).
repo="$(mk_repo)"; seed_placeholder "$repo" MULTI
( cd "$repo" && HANDOFF_NO_GITIGNORE_BOOTSTRAP=1 \
    printf '{\n  "cwd": "%s",\n  "reason": "resume"\n}\n' "$repo" | bash "$WH" --if-curated >/dev/null 2>&1 )
check "4b: multi-line payload -> resume skip"  skip "$(outcome "$repo" MULTI)"
rm -rf "$repo"

# 4c: writer that is slower than the spawn but inside the window.
repo="$(mk_repo)"; seed_placeholder "$repo" LATE
( cd "$repo" && HANDOFF_NO_GITIGNORE_BOOTSTRAP=1 HANDOFF_STDIN_TIMEOUT=3 \
    bash -c 'sleep 1; printf "{\"reason\":\"resume\"}"' | bash "$WH" --if-curated >/dev/null 2>&1 )
check "4c: payload arriving after 1 s -> resume skip" skip "$(outcome "$repo" LATE)"
rm -rf "$repo"

# 4d: a nonsense timeout value falls back to the default instead of breaking.
repo="$(mk_repo)"; seed_placeholder "$repo" BADT
( cd "$repo" && HANDOFF_NO_GITIGNORE_BOOTSTRAP=1 HANDOFF_STDIN_TIMEOUT=abc \
    bash "$WH" --if-curated <<<'{"reason":"resume"}' >/dev/null 2>&1 )
check "4d: bad HANDOFF_STDIN_TIMEOUT -> still reads payload" skip "$(outcome "$repo" BADT)"
rm -rf "$repo"

finish
