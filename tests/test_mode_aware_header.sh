#!/usr/bin/env bash
# Issue #66: the generated handoff header used to hardcode bare-scripts
# paths ("~/.claude/bin/write_handoff.sh", "~/.claude/settings.json")
# unconditionally, which misdescribes every plugin install (writer lives
# under the plugin cache, hooks come from the plugin's hooks/hooks.json) and
# a third shape besides: a git clone run directly, or a relocated/--copy
# install matching neither convention.
#
# Two things this file proves:
#
#   1. Mode detection: the header names the actual install shape, reusing
#      the same self_dir-based idiom handoff_session_start.sh already
#      established for issue #71 (`case "$self_dir" in */plugins/cache/*)`).
#
#   2. Backward compatibility, which is the load-bearing constraint here:
#      the header sits inside the skeleton-HMAC-signed preamble (everything
#      before the Notes/Rules bind regions), so the mode string MUST be
#      decided at build time, before signing, and --restamp MUST NEVER
#      regenerate it. Proven two ways below: (a) a doc carrying the
#      bare-scripts wording -- byte-identical to what pre-#66 code always
#      emitted, since that wording is intentionally left unchanged -- still
#      verifies as-is, and (b) restamping that same doc from a
#      PLUGIN-shaped location does not flip its header to plugin wording,
#      which it would if restamp ever re-ran the header-generation code
#      path instead of only re-signing.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Signing needs openssl; the provenance-verification assertions below are the
# whole point of this file (see test_restamp_skeleton_guard.sh for the same
# gate on the same grounds).
command -v openssl >/dev/null 2>&1 || { echo "  SKIP  openssl not available"; finish; exit 0; }

has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

# The exact pre-#66 header paragraph (bin/write_handoff.sh:1096-1098 before
# this fix) -- kept verbatim as the bare-scripts wording so an existing
# signed handoff from that era is byte-identical to what this branch emits
# for the same shape, and so a regression that reworded it is caught here.
OLD_HEADER_TEXT="Auto-written by \`~/.claude/bin/write_handoff.sh\` (called from the
\`/handoff\` skill + the \`SessionEnd\` hook in \`~/.claude/settings.json\`).
Auto-loaded into the next session by the \`SessionStart\` hook in the
same settings file."

# Build a scratch copy of bin/ rooted at $1 (a plugin-cache path) or plain
# bare-scripts $1/.claude/bin, so self_dir resolution differs by shape.
mk_plugin_bin() {  # <root> -> echoes the bin/ path
  local root="$1" d
  d="$root/.claude/plugins/cache/somemkt/claude-code-handoff/0.15.0/bin"
  must mkdir -p "$d"
  must cp -r "$REPO_ROOT/bin/." "$d/"
  printf '%s\n' "$d"
}
mk_bare_bin() {  # <root> -> echoes the bin/ path
  local root="$1" d
  d="$root/.claude/bin"
  must mkdir -p "$d"
  must cp -r "$REPO_ROOT/bin/." "$d/"
  printf '%s\n' "$d"
}

# A fresh build has no content inside the BIND-marked Rules region (just the
# HANDOFF_RULES_PLACEHOLDER comment), so handoff_bind_has_content is false and
# prov_ok never reaches 1 -- matching test_restamp_skeleton_guard.sh's build(),
# every provenance-verification assertion needs an actual rule injected (as
# /handoff would) before the doc is (re-)signed.
inject_rule() {  # <doc>
  LC_ALL=C sed 's|^<!-- HANDOFF_RULES_PLACEHOLDER:.*|- TEST_RULE placeholder rule so the bind region has content.|' \
    "$1" > "$1.n" && must mv "$1.n" "$1"
}

echo "mode-aware header: install-shape detection (issue #66)"

# --- Shape 1: plugin install -------------------------------------------------
plugin_home="$(mktemp -d)" || { echo "mktemp failed" >&2; exit 1; }
cleanup_on_exit "$plugin_home"
plugin_bin="$(mk_plugin_bin "$plugin_home")"
proj1="$(mk_repo)" || exit 1
cleanup_on_exit "$proj1"
sec1="$(mktemp -d)/secret"; cleanup_on_exit "$(dirname "$sec1")"
( cd "$proj1" && HOME="$plugin_home" CLAUDE_HOME="$plugin_home/.claude" \
    HANDOFF_SECRET_FILE="$sec1" CLAUDE_PROJECT_DIR="$proj1" \
    bash "$plugin_bin/write_handoff.sh" >/dev/null 2>&1 </dev/null )
doc1="$proj1/.claude/handoff_current.md"
must test -f "$doc1"
check "plugin shape -> names the plugin"          yes "$(has "$(cat "$doc1")" "claude-code-handoff plugin")"
check "plugin shape -> points at hooks/hooks.json" yes "$(has "$(cat "$doc1")" "hooks/hooks.json")"
check "plugin shape -> no bare-scripts wording"    no  "$(has "$(cat "$doc1")" "$OLD_HEADER_TEXT")"
check "plugin shape -> no 'matches neither' text"  no  "$(has "$(cat "$doc1")" "matches neither")"
# Requirement (a): a handoff written by the NEW (mode-aware) code signs and
# verifies -- proven here with genuinely new (plugin) wording in the signed
# preamble, not just the unchanged bare-scripts branch. inject_rule + restamp
# mirrors the real /handoff flow (edit Notes/Rules, then restamp) so the doc
# actually has bound content to verify.
inject_rule "$doc1"
( cd "$proj1" && HOME="$plugin_home" CLAUDE_HOME="$plugin_home/.claude" \
    HANDOFF_SECRET_FILE="$sec1" CLAUDE_PROJECT_DIR="$proj1" \
    bash "$plugin_bin/write_handoff.sh" --restamp >/dev/null 2>&1 </dev/null )
ss_out1="$( cd "$proj1" && HOME="$plugin_home" CLAUDE_HOME="$plugin_home/.claude" \
    HANDOFF_SECRET_FILE="$sec1" CLAUDE_PROJECT_DIR="$proj1" \
    bash "$plugin_bin/handoff_session_start.sh" </dev/null 2>/dev/null )"
check "plugin shape -> new doc signs and verifies" yes "$(has "$ss_out1" "(provenance verified)")"

# --- Shape 2: bare-scripts install ------------------------------------------
bare_home="$(mktemp -d)" || { echo "mktemp failed" >&2; exit 1; }
cleanup_on_exit "$bare_home"
bare_bin="$(mk_bare_bin "$bare_home")"
proj2="$(mk_repo)" || exit 1
cleanup_on_exit "$proj2"
sec2="$(mktemp -d)/secret"; cleanup_on_exit "$(dirname "$sec2")"
( cd "$proj2" && HOME="$bare_home" CLAUDE_HOME="$bare_home/.claude" \
    HANDOFF_SECRET_FILE="$sec2" CLAUDE_PROJECT_DIR="$proj2" \
    bash "$bare_bin/write_handoff.sh" >/dev/null 2>&1 </dev/null )
doc2="$proj2/.claude/handoff_current.md"
must test -f "$doc2"
check "bare-scripts shape -> exact pre-#66 wording" yes "$(has "$(cat "$doc2")" "$OLD_HEADER_TEXT")"
check "bare-scripts shape -> no plugin wording"     no  "$(has "$(cat "$doc2")" "claude-code-handoff plugin")"
check "bare-scripts shape -> no 'matches neither'"  no  "$(has "$(cat "$doc2")" "matches neither")"

# --- Shape 3: neither (git clone run directly / relocated bin) --------------
# This repo's own bin/, invoked with HOME pointed somewhere that is neither
# a plugins/cache path nor equal to $HOME/.claude/bin -- the exact "third
# state" the issue's follow-up comment called out (this repo dogfoods this
# shape, and tests/test_plugin_layout.sh's relocated-bin fixture is another
# instance of it).
other_home="$(mktemp -d)" || { echo "mktemp failed" >&2; exit 1; }
cleanup_on_exit "$other_home"
proj3="$(mk_repo)" || exit 1
cleanup_on_exit "$proj3"
sec3="$(mktemp -d)/secret"; cleanup_on_exit "$(dirname "$sec3")"
( cd "$proj3" && HOME="$other_home" CLAUDE_HOME="$other_home/.claude" \
    HANDOFF_SECRET_FILE="$sec3" CLAUDE_PROJECT_DIR="$proj3" \
    bash "$REPO_ROOT/bin/write_handoff.sh" >/dev/null 2>&1 </dev/null )
doc3="$proj3/.claude/handoff_current.md"
must test -f "$doc3"
check "neither shape -> names the resolved dir literally" yes \
  "$(has "$(cat "$doc3")" "$REPO_ROOT/bin/write_handoff.sh")"
check "neither shape -> 'matches neither' explanation"     yes \
  "$(has "$(cat "$doc3")" "matches neither")"
check "neither shape -> no plugin wording"                 no \
  "$(has "$(cat "$doc3")" "claude-code-handoff plugin")"
check "neither shape -> no bare-scripts wording"           no \
  "$(has "$(cat "$doc3")" "$OLD_HEADER_TEXT")"

echo "mode-aware header: backward compatibility (pre-#66 docs, --restamp)"

# --- Requirement (b): a pre-existing (bare-scripts-worded) handoff still ----
# verifies, and --restamp never rewrites its preamble -- even when invoked
# from a PLUGIN-shaped location, which would flip the wording if restamp
# ever re-ran the header-generation code path instead of only re-signing.
# doc2 above (built by THIS branch's bare-scripts path) is byte-identical to
# what pre-#66 code produced for the same shape, since that wording is
# deliberately left unchanged -- so it stands in for "a handoff written by
# the OLD code" without depending on git history (this repo's CI checks out
# a shallow clone, so pinning an old commit SHA here would not survive it).
# inject_rule + one restamp (from the SAME bare-scripts location, i.e. the
# "old code" resigning its own doc) mirrors the real /handoff flow and gives
# the doc actual bound content, matching what a genuinely pre-existing signed
# handoff looks like.
inject_rule "$doc2"
( cd "$proj2" && HOME="$bare_home" CLAUDE_HOME="$bare_home/.claude" \
    HANDOFF_SECRET_FILE="$sec2" CLAUDE_PROJECT_DIR="$proj2" \
    bash "$bare_bin/write_handoff.sh" --restamp >/dev/null 2>&1 </dev/null )
before_full="$(cat "$doc2")"
before_header_only="$(grep -F "$OLD_HEADER_TEXT" "$doc2" || true)"
must test -n "$before_header_only"

ss_out2_before="$( cd "$proj2" && HOME="$bare_home" CLAUDE_HOME="$bare_home/.claude" \
    HANDOFF_SECRET_FILE="$sec2" CLAUDE_PROJECT_DIR="$proj2" \
    bash "$bare_bin/handoff_session_start.sh" </dev/null 2>/dev/null )"
check "pre-existing (bare-scripts) doc verifies before restamp" yes \
  "$(has "$ss_out2_before" "(provenance verified)")"

# Restamp it from a PLUGIN-shaped self_dir, deliberately mismatched against
# the doc's own (bare-scripts) wording.
plugin_home2="$(mktemp -d)" || { echo "mktemp failed" >&2; exit 1; }
cleanup_on_exit "$plugin_home2"
plugin_bin2="$(mk_plugin_bin "$plugin_home2")"
restamp_rc=0
( cd "$proj2" && HOME="$plugin_home2" CLAUDE_HOME="$plugin_home2/.claude" \
    HANDOFF_SECRET_FILE="$sec2" CLAUDE_PROJECT_DIR="$proj2" \
    bash "$plugin_bin2/write_handoff.sh" --restamp >/dev/null 2>&1 </dev/null ) \
  || restamp_rc=$?
check "restamp from plugin-shaped location -> exit 0" 0 "$restamp_rc"

after_full="$(cat "$doc2")"
check "restamp -> header keeps ORIGINAL bare-scripts wording" yes \
  "$(has "$after_full" "$OLD_HEADER_TEXT")"
check "restamp -> header NOT flipped to plugin wording" no \
  "$(has "$after_full" "claude-code-handoff plugin")"
# Preamble (everything up to and including the header paragraph) is
# untouched by restamp -- only the trailing skeleton/HMAC lines may change.
before_preamble="$(printf '%s\n' "$before_full" | awk '{print} /^---$/{exit}')"
after_preamble="$(printf '%s\n' "$after_full" | awk '{print} /^---$/{exit}')"
check "restamp -> preamble bytes unchanged" "$before_preamble" "$after_preamble"

ss_out2_after="$( cd "$proj2" && HOME="$bare_home" CLAUDE_HOME="$bare_home/.claude" \
    HANDOFF_SECRET_FILE="$sec2" CLAUDE_PROJECT_DIR="$proj2" \
    bash "$bare_bin/handoff_session_start.sh" </dev/null 2>/dev/null )"
check "pre-existing doc still verifies after restamp" yes \
  "$(has "$ss_out2_after" "(provenance verified)")"

finish
