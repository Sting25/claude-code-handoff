#!/usr/bin/env bash
# Replacing a pre-existing symlink must leave a durable, recoverable record of
# where it pointed (#45).
#
# A regular file in the install path gets a `.bak.<ts>`; a symlink was removed
# with the old target echoed to stdout only — gone once that scrolled past, or
# immediately when the installer ran with output redirected (hooks, CI). The
# user's own file was never destroyed, but the WIRING was unrecoverable.
#
# The log is append-only by contract: an existing file is added to, never
# rewritten or truncated, because it may hold records the user still needs.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "install.sh — replaced symlinks leave an append-only record (#45)"

if ! command -v jq >/dev/null 2>&1; then
  skip "jq not installed — install.sh refuses to install without it"
  finish
  exit
fi

has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

HOME_DIR=""; OTHER=""
# seed_foreign_link — a home whose write_handoff.sh is the user's own fork.
seed_foreign_link() {
  HOME_DIR="$(mktemp -d)"; OTHER="$(mktemp -d)"
  mkdir -p "$HOME_DIR/bin"
  printf '#!/usr/bin/env bash\necho MY_CUSTOM_FORK\n' > "$OTHER/write_handoff.sh"
  ln -s "$OTHER/write_handoff.sh" "$HOME_DIR/bin/write_handoff.sh"
}
# shellcheck disable=SC2120  # extra install args are optional; every call here uses the default
run_install() { OUT="$(CLAUDE_HOME="$HOME_DIR" bash "$REPO_ROOT/install.sh" "$@" 2>&1)"; }
LOG() { printf '%s' "$HOME_DIR/handoff-install.log"; }
cleanup() { rm -rf "$HOME_DIR" "$OTHER"; }

# --- Foreign symlink -> recorded ---------------------------------------------
seed_foreign_link
run_install
check "foreign link: log created"          yes "$([ -f "$(LOG)" ] && echo yes || echo no)"
check "foreign link: old target recorded"  yes "$(has "$(cat "$(LOG)" 2>/dev/null)" "$OTHER/write_handoff.sh")"
check "foreign link: names the dst"        yes "$(has "$(cat "$(LOG)" 2>/dev/null)" "bin/write_handoff.sh")"
check "foreign link: says so on stdout"    yes "$(has "$OUT" "recorded old target")"
check "log mode 600"                       600 "$(file_mode "$(LOG)")"
# Their fork file itself is never touched.
check "their fork file untouched"          yes "$(grep -qF 'MY_CUSTOM_FORK' "$OTHER/write_handoff.sh" 2>/dev/null && echo yes || echo no)"
cleanup

# --- Append-only: a pre-existing log is added to, never clobbered ------------
seed_foreign_link
must printf 'PRE-EXISTING LINE THE USER CARES ABOUT\n' > "$HOME_DIR/handoff-install.log"
run_install
check "existing log: their line preserved" yes "$(has "$(cat "$(LOG)")" "PRE-EXISTING LINE THE USER CARES ABOUT")"
check "existing log: ours appended"        yes "$(has "$(cat "$(LOG)")" "$OTHER/write_handoff.sh")"
first_line="$(head -1 "$(LOG)")"
check "existing log: their line is first"  yes "$(has "$first_line" "PRE-EXISTING LINE")"
cleanup

# --- Idempotent re-install (same target) records nothing new -----------------
seed_foreign_link
run_install                                   # first: records the foreign target
before="$(grep -c '' "$(LOG)" 2>/dev/null || echo 0)"
run_install                                   # second: our own link, same target
after="$(grep -c '' "$(LOG)" 2>/dev/null || echo 0)"
check "same-target relink records nothing"  "$before" "$after"
cleanup

# --- A symlinked log is not written through ----------------------------------
seed_foreign_link
victim="$(mktemp -d)/their_file"
must printf 'THEIR CONTENT\n' > "$victim"
must ln -s "$victim" "$HOME_DIR/handoff-install.log"
run_install
check "symlinked log: not followed"        yes "$(grep -qxF 'THEIR CONTENT' "$victim" && echo yes || echo no)"
check "symlinked log: victim unchanged"    1   "$(grep -c '' "$victim" | tr -d ' ')"
check "symlinked log: says why"            yes "$(has "$OUT" "is a symlink")"
check "old target still on stdout"         yes "$(has "$OUT" "$OTHER/write_handoff.sh")"
rm -rf "$(dirname "$victim")"
cleanup

# --- Uninstall leaves the record alone (it is history, not our wiring) -------
seed_foreign_link
run_install
lines_before="$(grep -c '' "$(LOG)" 2>/dev/null || echo 0)"
OUT="$(CLAUDE_HOME="$HOME_DIR" bash "$REPO_ROOT/install.sh" --uninstall 2>&1)"
check "uninstall: log survives"            yes "$([ -f "$(LOG)" ] && echo yes || echo no)"
check "uninstall: log unchanged"           "$lines_before" "$(grep -c '' "$(LOG)" 2>/dev/null || echo 0)"
cleanup

finish
