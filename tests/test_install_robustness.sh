#!/usr/bin/env bash
# install.sh robustness (audit-tail LOW items):
#   settings#3 — a valid-JSON-but-non-object settings.json ([], 42, "x") is
#                refused cleanly up front, not crashed-into mid-patch.
#   settings#2 — a symlinked settings.json (dotfiles pattern) is patched at its
#                TARGET, leaving the symlink intact (was: mv replaced the link).
#   install#1  — uninstall removes a dangling "ours" symlink at the canonical
#                path (was: reported "already absent" and left behind).
#   install#3  — the .bak.<ts> name carries a PID component so two installs in
#                the same clock second can't clobber each other's backup.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "install.sh robustness"
if ! command -v jq >/dev/null 2>&1; then skip "jq missing — install patching is a no-op"; finish; exit; fi

prep_src() {  # echoes a temp dir holding install.sh + bin + skills
  local src; src="$(mktemp -d)"
  cp "$REPO_ROOT/install.sh" "$src/" \
    && cp -r "$REPO_ROOT/bin" "$REPO_ROOT/skills" "$src/" || return 1
  printf '%s\n' "$src"
}

# --- settings#3: non-object settings.json is refused cleanly --------------------
src="$(prep_src)"; home="$(mktemp -d)"
printf '%s' '[]' > "$home/settings.json"
# install.sh prints its progress + ERROR/refusal text to STDOUT (not stderr).
out="$( CLAUDE_HOME="$home" bash "$src/install.sh" 2>/dev/null )"; rc=$?
check "non-object: nonzero exit"             yes "$([[ $rc -ne 0 ]] && echo yes || echo no)"
check "non-object: file left untouched ([])" "[]" "$(cat "$home/settings.json")"
check "non-object: error names 'not a JSON object'" yes \
  "$(case "$out" in (*'not a JSON object'*) echo yes ;; (*) echo no ;; esac)"
check "non-object: no stray .tmp"            no  "$([[ -e "$home/settings.json.tmp" ]] && echo yes || echo no)"
rm -rf "$src" "$home"

# --- settings#2: symlinked settings.json is patched at the target --------------
src="$(prep_src)"; home="$(mktemp -d)"; ext="$(mktemp -d)"
printf '%s' '{"existingUserKey":42}' > "$ext/real_settings.json"
ln -s "$ext/real_settings.json" "$home/settings.json"
CLAUDE_HOME="$home" bash "$src/install.sh" >/dev/null 2>&1; rc=$?
check "symlinked settings: exit 0"                    0 "$rc"
check "symlinked settings: symlink left intact"       yes "$([[ -L "$home/settings.json" ]] && echo yes || echo no)"
check "symlinked settings: link still -> target"      "$ext/real_settings.json" "$(readlink "$home/settings.json")"
check "symlinked settings: TARGET got the hooks"      present \
  "$(jq -e '.hooks.SessionStart' "$ext/real_settings.json" >/dev/null 2>&1 && echo present || echo absent)"
check "symlinked settings: user key preserved"        42 "$(jq -r '.existingUserKey' "$ext/real_settings.json" 2>/dev/null)"
rm -rf "$src" "$home" "$ext"

# --- install#1: uninstall removes a dangling "ours" symlink --------------------
src="$(prep_src)"; home="$(mktemp -d)"; mkdir -p "$home/bin"
ln -s "/a/removed/clone/bin/write_handoff.sh" "$home/bin/write_handoff.sh"
check "precondition: dangling symlink planted" yes \
  "$([[ -L "$home/bin/write_handoff.sh" && ! -e "$home/bin/write_handoff.sh" ]] && echo yes || echo no)"
out="$( CLAUDE_HOME="$home" bash "$src/install.sh" --uninstall 2>&1 )"; rc=$?
check "uninstall dangling: exit 0"             0 "$rc"
check "uninstall dangling: symlink removed"    yes "$([[ ! -L "$home/bin/write_handoff.sh" ]] && echo yes || echo no)"
check "uninstall dangling: reported as stale"  yes \
  "$(case "$out" in (*'stale dangling link'*) echo yes ;; (*) echo no ;; esac)"
rm -rf "$src" "$home"

# --- install#3: backup name carries a PID component ----------------------------
src="$(prep_src)"; home="$(mktemp -d)"
printf '%s' '{"userKey":1}' > "$home/settings.json"
CLAUDE_HOME="$home" bash "$src/install.sh" >/dev/null 2>&1
bak="$(find "$home" -maxdepth 1 -name 'settings.json.bak.*' 2>/dev/null | sort | head -n 1)"
check "install#3: a pre-patch backup was kept"        yes "$([[ -n "$bak" ]] && echo yes || echo no)"
# ts is YYYYMMDD_HHMMSS_PID -> three digit groups, i.e. two underscores.
check "install#3: backup ts carries a pid component"  yes \
  "$(case "$(basename "${bak:-x}")" in (*.bak.[0-9]*_[0-9]*_[0-9]*) echo yes ;; (*) echo no ;; esac)"
check "install#3: user key preserved through patch"   1 "$(jq -r '.userKey' "$home/settings.json" 2>/dev/null)"
rm -rf "$src" "$home"

finish
