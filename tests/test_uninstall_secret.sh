#!/usr/bin/env bash
# `install.sh --uninstall` must be a true inverse: the per-machine HMAC secret
# that write_handoff.sh generates on first signed write (issue #42) is key
# material, and leaving it behind means a tool the user believes they removed
# still has a credential on disk.
#
# But this is the ONE path where uninstall deletes a file the installer never
# created itself, so the negative controls are the point of this file: a file
# that is NOT provably ours must survive untouched. Someone else's data at that
# path — a foreign secret, a symlink into their keychain, a directory, or a
# custom HANDOFF_SECRET_FILE location — must never be removed.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "install.sh --uninstall — removes OUR secret, never anyone else's file"

if ! command -v jq >/dev/null 2>&1; then
  skip "jq not installed — install.sh settings patching is a no-op without it"
  finish
  exit
fi

has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

# Build an installed home, seed the secret path with <content-producer>, then
# uninstall. Echoes nothing; sets HOME_DIR / OUT.
setup_home() {
  local src
  src="$(mktemp -d)"; HOME_DIR="$(mktemp -d)"
  cp "$REPO_ROOT/install.sh" "$src/"
  cp -r "$REPO_ROOT/bin" "$REPO_ROOT/skills" "$src/"
  CLAUDE_HOME="$HOME_DIR" bash "$src/install.sh" --copy >/dev/null 2>&1
  SRC_DIR="$src"
}
do_uninstall() {  # [ENV=VAL ...]
  # env -u strips the suite-wide HANDOFF_SECRET_FILE jail lib.sh exports
  # (issue #49): the default-path cases below need the override ABSENT —
  # install.sh --uninstall skips the secret entirely whenever it is set.
  # The explicit-override case still works: assignments in "$@" come after
  # -u and win.
  OUT="$(env -u HANDOFF_SECRET_FILE CLAUDE_HOME="$HOME_DIR" "$@" bash "$SRC_DIR/install.sh" --uninstall 2>&1)"
}
# Same as do_uninstall, but also passes --keep-secret (issue #65: switching
# from bare-scripts to the plugin must not silently unbind already-signed
# handoffs by deleting the per-machine HMAC secret out from under them).
do_uninstall_keep_secret() {
  OUT="$(env -u HANDOFF_SECRET_FILE CLAUDE_HOME="$HOME_DIR" bash "$SRC_DIR/install.sh" --uninstall --keep-secret 2>&1)"
}
cleanup() { rm -rf "$SRC_DIR" "$HOME_DIR"; }

# A real secret, exactly as handoff_ensure_secret writes it (64 lowercase hex).
OURS="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

# --- OURS: removed -----------------------------------------------------------
setup_home
must printf '%s\n' "$OURS" > "$HOME_DIR/handoff_secret"
do_uninstall
check "our secret -> removed"        no  "$([ -e "$HOME_DIR/handoff_secret" ] && echo yes || echo no)"
check "our secret -> reports it"     yes "$(has "$OUT" "per-machine HMAC secret")"
check "our secret -> never printed"  no  "$(has "$OUT" "$OURS")"
check "explains the consequence"     yes "$(has "$OUT" "re-signs")"
cleanup

# --- Our generator's no-trailing-newline form (od fallback) is still ours ----
setup_home
must printf '%s' "$OURS" > "$HOME_DIR/handoff_secret"
do_uninstall
check "no-newline secret -> removed"  no "$([ -e "$HOME_DIR/handoff_secret" ] && echo yes || echo no)"
cleanup

# === --keep-secret (issue #65): migration to the plugin must not silently ===
# === unbind already-signed handoffs by deleting the shared HMAC secret ======

# --- --keep-secret: OURS survives, with content and permissions intact ------
setup_home
must printf '%s\n' "$OURS" > "$HOME_DIR/handoff_secret"
must chmod 600 "$HOME_DIR/handoff_secret"
do_uninstall_keep_secret
check "keep-secret -> file survives"       yes "$([ -e "$HOME_DIR/handoff_secret" ] && echo yes || echo no)"
check "keep-secret -> content unchanged"   "$OURS" "$(cat "$HOME_DIR/handoff_secret")"
check "keep-secret -> reports skip"        yes "$(has "$OUT" "preserving the per-machine HMAC secret")"
check "keep-secret -> never printed"       no  "$(has "$OUT" "$OURS")"
check "keep-secret -> rest of uninstall ran" yes "$(has "$OUT" "uninstalling handoff skill")"
cleanup

# --- --keep-secret skips before the shape check: even a foreign file at -----
# --- that path is left alone and reported as kept, not as "not the shape" --
setup_home
FOREIGN_FOR_KEEP_TEST='# unrelated notes, not our secret shape'
must printf '%s\n' "$FOREIGN_FOR_KEEP_TEST" > "$HOME_DIR/handoff_secret"
do_uninstall_keep_secret
check "keep-secret -> foreign content survives" yes "$(has "$(cat "$HOME_DIR/handoff_secret")" "unrelated notes")"
check "keep-secret -> reports skip, not shape check" yes "$(has "$OUT" "preserving the per-machine HMAC secret")"
check "keep-secret -> does not say wrong shape"      no  "$(has "$OUT" "not the shape this tool generates")"
cleanup

# --- Without --keep-secret, the default (delete) behavior is unchanged ------
setup_home
must printf '%s\n' "$OURS" > "$HOME_DIR/handoff_secret"
do_uninstall
check "no flag -> still removed (default unchanged)" no "$([ -e "$HOME_DIR/handoff_secret" ] && echo yes || echo no)"
check "no flag -> does not mention keep-secret"       no "$(has "$OUT" "preserving the per-machine HMAC secret")"
cleanup

# === NEGATIVE CONTROLS: someone else's data must survive =====================

# --- A foreign file at that path (not our shape) -> untouched ----------------
setup_home
FOREIGN='# my own notes and an api key: sk-live-DO-NOT-DELETE'
must printf '%s\n' "$FOREIGN" > "$HOME_DIR/handoff_secret"
do_uninstall
check "foreign file -> survives"        yes "$([ -e "$HOME_DIR/handoff_secret" ] && echo yes || echo no)"
check "foreign file -> content intact"  yes "$(has "$(cat "$HOME_DIR/handoff_secret")" "DO-NOT-DELETE")"
check "foreign file -> says it skipped" yes "$(has "$OUT" "not the shape this tool generates")"
check "foreign file -> not printed"     no  "$(has "$OUT" "sk-live")"
cleanup

# --- A symlink at that path -> neither followed nor removed ------------------
setup_home
victim="$(mktemp -d)/precious_key"
must printf 'PRECIOUS_KEY_MATERIAL\n' > "$victim"
must ln -s "$victim" "$HOME_DIR/handoff_secret"
do_uninstall
check "symlink -> link survives"      yes "$([ -L "$HOME_DIR/handoff_secret" ] && echo yes || echo no)"
check "symlink -> target survives"    yes "$([ -f "$victim" ] && echo yes || echo no)"
check "symlink -> target intact"      yes "$(has "$(cat "$victim")" "PRECIOUS_KEY_MATERIAL")"
check "symlink -> says it skipped"    yes "$(has "$OUT" "symlink")"
rm -rf "$(dirname "$victim")"
cleanup

# --- A directory at that path -> untouched -----------------------------------
setup_home
must mkdir -p "$HOME_DIR/handoff_secret/their_stuff"
must printf 'data\n' > "$HOME_DIR/handoff_secret/their_stuff/file.txt"
do_uninstall
check "directory -> survives"         yes "$([ -d "$HOME_DIR/handoff_secret" ] && echo yes || echo no)"
check "directory -> contents intact"  yes "$([ -f "$HOME_DIR/handoff_secret/their_stuff/file.txt" ] && echo yes || echo no)"
check "directory -> says it skipped"  yes "$(has "$OUT" "not a regular file")"
cleanup

# --- HANDOFF_SECRET_FILE override -> we don't touch a path we don't own ------
setup_home
custom="$(mktemp -d)/team_secret"
must printf '%s\n' "$OURS" > "$custom"
# Even with OUR exact shape at the custom path, and a default-path secret too:
must printf '%s\n' "$OURS" > "$HOME_DIR/handoff_secret"
do_uninstall HANDOFF_SECRET_FILE="$custom"
check "override -> custom path survives"  yes "$([ -f "$custom" ] && echo yes || echo no)"
check "override -> default path survives" yes "$([ -f "$HOME_DIR/handoff_secret" ] && echo yes || echo no)"
check "override -> says it skipped"       yes "$(has "$OUT" "override set")"
rm -rf "$(dirname "$custom")"
cleanup

# --- Absent secret -> clean no-op --------------------------------------------
setup_home
rm -f "$HOME_DIR/handoff_secret"
do_uninstall
check "absent secret -> reports absent" yes "$(has "$OUT" "already absent")"
cleanup

# === The rest of uninstall still leaves a user's own config alone ============
setup_home
must cat > "$HOME_DIR/settings.json" <<'EOF'
{
  "statusLine": {"type": "command", "command": "their-own-statusline.sh"},
  "hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "echo THEIR_HOOK"}]}]},
  "permissions": {"allow": ["Bash(their-own-tool)"]},
  "env": {"THEIR_TOKEN": "keep-me"}
}
EOF
must printf '%s\n' "$OURS" > "$HOME_DIR/handoff_secret"
do_uninstall
settings="$(cat "$HOME_DIR/settings.json")"
check "their hook survives"        yes "$(has "$settings" "THEIR_HOOK")"
check "their permission survives"  yes "$(has "$settings" "their-own-tool")"
check "their statusLine survives"  yes "$(has "$settings" "their-own-statusline.sh")"
check "their env survives"         yes "$(has "$settings" "keep-me")"
check "our secret still removed"   no  "$([ -e "$HOME_DIR/handoff_secret" ] && echo yes || echo no)"
cleanup

finish
