#!/usr/bin/env bash
# #171 removed the plugin distribution, including the plugin arm of the
# signed write_handoff.sh header. A handoff a plugin install signed before
# that carries the old header wording inside its HMAC-covered preamble, and
# it must keep loading as BINDING with the new scripts, and keep its wording
# through a --restamp.
#
# The plugin-era document is a fixture built in-test: the current writer
# produces a doc, its header paragraph is swapped for the exact v0.18.7
# plugin-arm wording (bin/write_handoff.sh at tag v0.18.7), a rule is
# injected, and the doc is signed with the current provenance helper, the
# same skeleton-then-HMAC sequence write_handoff.sh uses at write time.
# Running the v0.18.7 writer itself is not possible here: CI checks out a
# shallow clone with no tags.
#
# Also a negative control: one changed byte in that header and the doc no
# longer verifies, so the positive checks cannot pass vacuously.
#
# This file is allowlisted in tests/test_no_plugin_remnants.sh because the
# fixture must carry the old wording verbatim.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "plugin-era signed handoff still verifies (#171)"

command -v openssl >/dev/null 2>&1 || { echo "  SKIP  openssl not available"; finish; exit 0; }

has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
binding_has() {  # <output> <needle> -> yes|no (after the Standing rules header)
  case "$1" in
    *"Standing rules"*)
      case "${1#*Standing rules}" in *"$2"*) echo yes ;; *) echo no ;; esac ;;
    *) echo no ;;
  esac
}

# Exact header paragraphs: what this writer emits for ~/.claude/bin, and the
# v0.18.7 plugin arm (its self_dir line filled with a plugin-cache path).
BARE_HEADER="Auto-written by \`~/.claude/bin/write_handoff.sh\` (called from the
\`/handoff\` skill + the \`SessionEnd\` hook wired in the Claude Code settings
file the installer patched: \`~/.claude/settings.json\` for a user-scope
install; for \`--scope project\`, the project's \`.claude/settings.json\`
or \`.claude/settings.local.json\`). Auto-loaded into the next session by
the \`SessionStart\` hook in the same settings file."
PLUGIN_DIR="/Users/someone/.claude/plugins/cache/claude-code-handoff/claude-code-handoff/0.18.7/bin"
PLUGIN_HEADER="Auto-written by the claude-code-handoff plugin's \`bin/write_handoff.sh\`
(called from the \`/handoff\` skill + the \`SessionEnd\` hook wired in the
plugin's own \`hooks/hooks.json\`, not \`~/.claude/settings.json\`).
Auto-loaded into the next session by the \`SessionStart\` hook in that same
file. Running from \`$PLUGIN_DIR\`."
RULE="PLUGIN_ERA_RULE keep this rule binding"

H="$(mktemp -d)"; cleanup_on_exit "$H"
BIN="$H/.claude/bin"
must mkdir -p "$BIN"
must cp -r "$REPO_ROOT/bin/." "$BIN/"
SEC="$H/secret"
P="$(mk_repo)" || exit 1
cleanup_on_exit "$P"
DOC="$P/.claude/handoff_current.md"

hrun() {  # <script> [args...]: run a hook script in the sandbox
  local s="$1"; shift
  ( cd "$P" && HOME="$H" CLAUDE_HOME="$H/.claude" HANDOFF_SECRET_FILE="$SEC" \
      CLAUDE_PROJECT_DIR="$P" bash "$BIN/$s" "$@" </dev/null 2>/dev/null )
}

# --- build the plugin-era fixture --------------------------------------------
hrun write_handoff.sh >/dev/null
must test -f "$DOC"
check "precondition: writer emitted the ~/.claude/bin header" yes "$(has "$(cat "$DOC")" "$BARE_HEADER")"

# sign_as_plugin_era <in> <out>: swap the header, inject the rule, strip the
# trailers, then skeleton stamp and HMAC exactly as the writer appends them.
sign_as_plugin_era() {
  local in="$1" out="$2"
  BARE_HEADER="$BARE_HEADER" PLUGIN_HEADER="$PLUGIN_HEADER" RULE="$RULE" \
    perl -0pe '
      my ($b, $p, $r) = ($ENV{BARE_HEADER}, $ENV{PLUGIN_HEADER}, $ENV{RULE});
      s/\Q$b\E/$p/ or die "header not found\n";
      s/^<!-- HANDOFF_RULES_PLACEHOLDER:.*$/- $r/m or die "rules placeholder not found\n";
      s/^<!-- HANDOFF_(?:SKEL_)?HMAC: [0-9a-f]{64} -->\n//mg;
    ' "$in" > "$out" || return 1
  (
    export HANDOFF_SECRET_FILE="$SEC" CLAUDE_HOME="$H/.claude" HOME="$H"
    # shellcheck source=bin/handoff_provenance.sh
    . "$BIN/handoff_provenance.sh"
    skel="$(handoff_skel_compute "$out" ensure)" || exit 1
    printf '<!-- HANDOFF_SKEL_HMAC: %s -->\n' "$skel" >> "$out"
    mac="$(handoff_mac_compute "$out" ensure)" || exit 1
    printf '<!-- HANDOFF_HMAC: %s -->\n' "$mac" >> "$out"
  )
}
must sign_as_plugin_era "$DOC" "$H/era.md"
must cp "$H/era.md" "$DOC"
check "fixture carries the v0.18.7 plugin header" yes "$(has "$(cat "$DOC")" "$PLUGIN_HEADER")"
check "fixture no longer carries the new header" no "$(has "$(cat "$DOC")" "$BARE_HEADER")"

# --- the new loader verifies it as binding -----------------------------------
out="$(hrun handoff_session_start.sh)"
check "new loader: provenance verified" yes "$(has "$out" "Standing rules from your previous session (provenance verified)")"
check "new loader: rule is in the binding tier" yes "$(binding_has "$out" "$RULE")"
check "new loader: trusted preamble names the valid HMAC" yes "$(has "$out" "valid HMAC from the per-machine secret")"

# --- --restamp with the new writer keeps the wording and still binds ---------
rc=0; hrun write_handoff.sh --restamp >/dev/null || rc=$?
check "new --restamp: exit 0" 0 "$rc"
check "new --restamp: plugin header kept verbatim" yes "$(has "$(cat "$DOC")" "$PLUGIN_HEADER")"
check "new --restamp: header not rewritten to the new wording" no "$(has "$(cat "$DOC")" "$BARE_HEADER")"
out="$(hrun handoff_session_start.sh)"
check "after restamp: provenance verified" yes "$(has "$out" "Standing rules from your previous session (provenance verified)")"
check "after restamp: rule is in the binding tier" yes "$(binding_has "$out" "$RULE")"

# --- negative control: one changed header byte and it no longer binds --------
must cp "$H/era.md" "$DOC"
LC_ALL=C sed 's/hooks\/hooks\.json/hooks\/hooks.jsoN/' "$DOC" > "$DOC.t" && must mv "$DOC.t" "$DOC"
check "control: tampered copy differs from the fixture" yes "$(cmp -s "$DOC" "$H/era.md" && echo no || echo yes)"
out="$(hrun handoff_session_start.sh)"
check "control: tampered header -> not verified" no "$(has "$out" "(provenance verified)")"
check "control: tampered header -> rule not binding" no "$(binding_has "$out" "$RULE")"
check "control: tampered header -> no valid HMAC preamble" no "$(has "$out" "valid HMAC from the per-machine secret")"

finish
