#!/usr/bin/env bash
# Guard for #171: the Claude Code plugin distribution was removed and
# install.sh is the only install path. A plugin remnant (a manifest, the
# plugin hooks file, a CLAUDE_PLUGIN_ROOT lookup, a plugin-cache glob, a
# marketplace reference) would bring back a second, untested layout, so this
# fails if any of them reappears in the shipped tree.
#
# Scope: bin/, install.d/, install.sh, skills/, tests/ (except this file),
# README.md and docs/. CHANGELOG.md is out of scope on purpose: its history
# describes the plugin releases. README.md keeps exactly one allowed place,
# the "Migrating from the plugin" subsection, which has to name the
# `claude plugin ... marketplace` commands a user runs to leave the plugin.
#
# The scanner is proven against planted fixtures below (one per pattern, plus
# the README allowance in both directions), so a pattern that silently stops
# matching goes red here instead of passing vacuously.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "no plugin remnants (#171)"

SELF="tests/$(basename "${BASH_SOURCE[0]}")"
PATTERN='CLAUDE_PLUGIN_ROOT|plugins/cache|marketplace|\.claude-plugin|hooks/hooks\.json'

# README.md with the migration subsection removed: from its heading up to
# (not including) the next markdown heading of level 2 or 3.
readme_scannable() {
  awk '
    /^### Migrating from the plugin/ { skip = 1; next }
    skip && /^##+ / { skip = 0 }
    !skip { print }
  ' "$1"
}

# scan_tree <root>: prints one line per remnant found under <root>, nothing
# when clean.
scan_tree() {
  local root="$1" d
  [[ -d "$root/.claude-plugin" ]] && echo "$root/.claude-plugin/ exists"
  [[ -e "$root/hooks/hooks.json" ]] && echo "$root/hooks/hooks.json exists"
  for d in bin install.d skills tests docs; do
    [[ -d "$root/$d" ]] || continue
    LC_ALL=C grep -rn -i -E "$PATTERN" "$root/$d" 2>/dev/null \
      | LC_ALL=C grep -v -F "$root/$SELF:" || true
  done
  if [[ -f "$root/install.sh" ]]; then
    LC_ALL=C grep -n -i -E "$PATTERN" "$root/install.sh" 2>/dev/null \
      | sed "s|^|$root/install.sh:|" || true
  fi
  if [[ -f "$root/README.md" ]]; then
    readme_scannable "$root/README.md" | LC_ALL=C grep -n -i -E "$PATTERN" \
      | sed "s|^|$root/README.md (outside the migration subsection):|" || true
  fi
}

# --- the shipped tree is clean ----------------------------------------------
hits="$(scan_tree "$REPO_ROOT")"
if [[ -n "$hits" ]]; then
  printf '%s\n' "$hits" | head -n 20 | sed 's/^/        /'
fi
check "repo tree has no plugin remnants" "" "$hits"

# --- the scanner catches each planted remnant (negative controls) -----------
fixture() {  # -> echoes a fresh clean fixture root
  local f
  f="$(mktemp -d)" || return 1
  mkdir -p "$f/bin" "$f/install.d" "$f/skills/handoff" "$f/tests" "$f/docs"
  printf '#!/usr/bin/env bash\necho ok\n' > "$f/bin/a.sh"
  printf '# Title\n\n## Installation\n\ntext\n\n### Migrating from the plugin (0.19 and earlier)\n\n    claude plugin marketplace remove claude-code-handoff\n\n## Requirements\n\nmore text\n' > "$f/README.md"
  printf '%s\n' "$f"
}

f="$(fixture)" || { echo "mktemp failed" >&2; exit 1; }
cleanup_on_exit "$f"
check "control: clean fixture (README migration subsection allowed)" "" "$(scan_tree "$f")"

plant() {  # <description> <relative file> <line>
  local g
  g="$(fixture)" || { echo "mktemp failed" >&2; exit 1; }
  cleanup_on_exit "$g"
  mkdir -p "$(dirname "$g/$2")"
  printf '%s\n' "$3" >> "$g/$2"
  check "planted: $1 -> caught" yes "$([[ -n "$(scan_tree "$g")" ]] && echo yes || echo no)"
}
plant "CLAUDE_PLUGIN_ROOT in bin/"          bin/a.sh                'hb=CLAUDE_PLUGIN_ROOT/bin'
plant "plugins/cache glob in skills/"       skills/handoff/SKILL.md 'for d in ~/.claude/plugins/cache/*/x; do :; done'
plant "Marketplace word in docs/"           docs/reference.md       'Add the Marketplace first.'
plant ".claude-plugin path in install.d/"   install.d/00-x.sh       '# see .claude-plugin/plugin.json'
plant "hooks/hooks.json in tests/"          tests/test_x.sh         '# wired in hooks/hooks.json'
plant "remnant in generated install.sh"     install.sh              '# plugins/cache'
plant "README outside migration subsection" README.md               'Run claude plugin marketplace add first.'

g="$(fixture)" || { echo "mktemp failed" >&2; exit 1; }
cleanup_on_exit "$g"
mkdir -p "$g/.claude-plugin"
check "planted: .claude-plugin/ directory -> caught" yes "$([[ -n "$(scan_tree "$g")" ]] && echo yes || echo no)"
g="$(fixture)" || { echo "mktemp failed" >&2; exit 1; }
cleanup_on_exit "$g"
mkdir -p "$g/hooks" && printf '{}\n' > "$g/hooks/hooks.json"
check "planted: hooks/hooks.json file -> caught" yes "$([[ -n "$(scan_tree "$g")" ]] && echo yes || echo no)"

finish
