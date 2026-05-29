#!/usr/bin/env bash
# Coverage for handoff_session_start.sh's sibling self-check (issue #21, Bug B):
# when a sibling hook script next to it is a dangling symlink (the whole install
# was symlinked from a temp checkout that got cleaned up), the hooks silently
# no-op — so SessionStart must surface a visible warning. Silent when healthy.
#
# We run the hook from a synthetic bin/ dir (so BASH_SOURCE's dirname is that
# dir) holding a real copy of the script plus sibling symlinks we control.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

# Build a bin/ dir containing the real session_start script + sibling links.
# <sibling-state>: "ok" -> links resolve; "dangling" -> point at a missing file.
mk_bin() {
  local state="$1" bin; bin="$(mktemp -d)"
  cp "$REPO_ROOT/bin/handoff_session_start.sh" "$bin/handoff_session_start.sh"
  for sib in write_handoff.sh handoff_turn_append.sh handoff_ctx_check.sh; do
    if [ "$state" = ok ]; then
      ln -s "$REPO_ROOT/bin/$sib" "$bin/$sib"            # resolves
    else
      ln -s "/no/such/$sib" "$bin/$sib"                  # dangling
    fi
  done
  printf '%s\n' "$bin"
}

echo "handoff_session_start.sh — dangling-sibling self-check"

# --- Healthy siblings -> no warning -----------------------------------------
bin="$(mk_bin ok)"
proj="$(mktemp -d)"; mkdir -p "$proj/.claude"
printf '# handoff\n\nCurated. MARKER_OK\n' > "$proj/.claude/handoff_current.md"
out="$( cd "$proj" && CLAUDE_PROJECT_DIR="$proj" bash "$bin/handoff_session_start.sh" 2>&1 )"; rc=$?
check "healthy: exit 0"            0   "$rc"
check "healthy: no warning"        no  "$(has "$out" "dangling hook link")"
check "healthy: handoff emitted"   yes "$(has "$out" "MARKER_OK")"
rm -rf "$bin" "$proj"

# --- Dangling siblings -> visible warning, naming the broken hooks ----------
bin="$(mk_bin dangling)"
proj="$(mktemp -d)"; mkdir -p "$proj/.claude"
printf '# handoff\n\nCurated. MARKER_BAD\n' > "$proj/.claude/handoff_current.md"
out="$( cd "$proj" && CLAUDE_PROJECT_DIR="$proj" bash "$bin/handoff_session_start.sh" 2>&1 )"; rc=$?
check "dangling: exit 0 (non-fatal)" 0   "$rc"
check "dangling: warns"              yes "$(has "$out" "dangling hook link")"
check "dangling: names a hook"       yes "$(has "$out" "write_handoff.sh")"
check "dangling: points to --doctor" yes "$(has "$out" "--doctor")"
# Warning must not suppress the normal handoff output.
check "dangling: handoff still emitted" yes "$(has "$out" "MARKER_BAD")"
rm -rf "$bin" "$proj"

# --- Dangling siblings + no current handoff -> still warns -------------------
# The self-check runs before the no-handoff exit, so a fresh repo still warns.
bin="$(mk_bin dangling)"
proj="$(mktemp -d)"; mkdir -p "$proj/.claude"   # no handoff_current.md
out="$( cd "$proj" && CLAUDE_PROJECT_DIR="$proj" bash "$bin/handoff_session_start.sh" 2>&1 )"; rc=$?
check "dangling+fresh: exit 0"   0   "$rc"
check "dangling+fresh: warns"    yes "$(has "$out" "dangling hook link")"
rm -rf "$bin" "$proj"

finish
