#!/usr/bin/env bash
# Guard for #171: the Claude Code plugin distribution was removed and
# install.sh is the only install path. A plugin remnant (a manifest, the
# plugin hooks file, a plugin-root or plugin-data lookup, a plugin-cache
# glob, a marketplace reference, a plugin command, the cache self-prune)
# would bring back a second, untested layout, so this fails if any of them
# reappears in the shipped tree.
#
# Scope: bin/, install.d/, install.sh, skills/, tests/, docs/, .github/,
# tools/, README.md and PRIVACY.md. Allowed, and nothing else:
#   - CHANGELOG.md (not scanned): its history describes the plugin releases;
#   - README.md's "Migrating from the plugin" subsection, which has to name
#     the commands a user runs to leave the plugin;
#   - the PLUGIN_LEFTOVER_CHECK region in install.d/ and install.sh (the one
#     check that tells a user a plugin install is still present), and its
#     test, tests/test_install_plugin_leftover.sh;
#   - this file.
#
# The scanner is proven against planted fixtures below (one per pattern and
# one per scanned location, plus each allowance in both directions), so a
# pattern or location that silently stops matching goes red here instead of
# passing vacuously.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "no plugin remnants (#171)"

SELF="tests/$(basename "${BASH_SOURCE[0]}")"
LEFTOVER_TEST="tests/test_install_plugin_leftover.sh"
PATTERN='CLAUDE_PLUGIN_ROOT|CLAUDE_PLUGIN_DATA|plugins/cache|marketplace|\.claude-plugin|hooks/hooks\.json|/plugin install|claude plugin|cache_prune'

# filtered <root> <relpath>: the file's lines that are subject to the scan,
# as "relpath:lineno:text". Allowed regions print nothing; line numbers are
# the real ones.
filtered() {
  local root="$1" rel="$2" mode=plain
  case "$rel" in
    README.md) mode=readme ;;
    install.sh|install.d/*) mode=region ;;
  esac
  awk -v rel="$rel" -v mode="$mode" '
    mode == "readme" && /^### Migrating from the plugin/ { skip = 1; next }
    mode == "readme" && skip && /^##+ / { skip = 0 }
    mode == "region" && /^# >>> PLUGIN_LEFTOVER_CHECK/ { skip = 1; next }
    mode == "region" && /^# <<< PLUGIN_LEFTOVER_CHECK/ { skip = 0; next }
    !skip { print rel ":" NR ":" $0 }
  ' "$root/$rel"
}

# scan_tree <root>: prints one line per remnant found under <root>, nothing
# when clean.
scan_tree() {
  local root="$1" d rel
  [[ -d "$root/.claude-plugin" ]] && echo ".claude-plugin/ exists"
  [[ -e "$root/hooks/hooks.json" ]] && echo "hooks/hooks.json exists"
  {
    for d in bin install.d skills tests docs .github tools; do
      [[ -d "$root/$d" ]] || continue
      ( cd "$root" && find "$d" -type f )
    done
    for rel in install.sh README.md PRIVACY.md; do
      [[ -f "$root/$rel" ]] && echo "$rel"
    done
  } | while IFS= read -r rel; do
    case "$rel" in "$SELF"|"$LEFTOVER_TEST") continue ;; esac
    filtered "$root" "$rel" | LC_ALL=C grep -i -E "$PATTERN" || true
  done
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
  mkdir -p "$f/bin" "$f/install.d" "$f/skills/handoff" "$f/tests" "$f/docs" \
           "$f/.github/workflows" "$f/tools"
  printf '#!/usr/bin/env bash\necho ok\n' > "$f/bin/a.sh"
  printf '# Title\n\n## Installation\n\ntext\n\n### Migrating from the plugin (0.19 and earlier)\n\n    claude plugin marketplace remove claude-code-handoff\n\n## Requirements\n\nmore text\n' > "$f/README.md"
  printf '# >>> PLUGIN_LEFTOVER_CHECK\n# plugins/cache, claude plugin marketplace remove\n# <<< PLUGIN_LEFTOVER_CHECK\necho ok\n' > "$f/install.d/30-x.sh"
  cp "$f/install.d/30-x.sh" "$f/install.sh"
  printf '# claude plugin uninstall, plugins/cache\n' > "$f/$LEFTOVER_TEST"
  printf '# Privacy\n' > "$f/PRIVACY.md"
  printf '%s\n' "$f"
}

caught() { [[ -n "$(scan_tree "$1")" ]] && echo yes || echo no; }

f="$(fixture)" || { echo "mktemp failed" >&2; exit 1; }
cleanup_on_exit "$f"
check "control: clean fixture (every allowance honored)" "" "$(scan_tree "$f")"

n_plants=0
plant() {  # <description> <relative file> <line>
  local g
  g="$(fixture)" || { echo "mktemp failed" >&2; exit 1; }
  cleanup_on_exit "$g"
  mkdir -p "$(dirname "$g/$2")"
  printf '%s\n' "$3" >> "$g/$2"
  n_plants=$((n_plants + 1))
  check "planted: $1 -> caught" yes "$(caught "$g")"
}
# one per pattern
plant "CLAUDE_PLUGIN_ROOT in bin/"          bin/a.sh                  'hb=CLAUDE_PLUGIN_ROOT/bin'
plant "CLAUDE_PLUGIN_DATA in bin/"          bin/a.sh                  'd=CLAUDE_PLUGIN_DATA'
plant "plugins/cache glob in skills/"       skills/handoff/SKILL.md   'for d in ~/.claude/plugins/cache/*/x; do :; done'
plant "Marketplace word in docs/"           docs/reference.md         'Add the Marketplace first.'
plant ".claude-plugin path in install.d/"   install.d/00-x.sh         '# see .claude-plugin/plugin.json'
plant "hooks/hooks.json in tests/"          tests/test_x.sh           '# wired in hooks/hooks.json'
plant "/plugin install in docs/"            docs/x.md                 'Run /plugin install first.'
plant "claude plugin command in bin/"       bin/a.sh                  '# claude plugin update'
plant "cache_prune in bin/"                 bin/b.sh                  'bash handoff_cache_prune.sh'
# one per scanned location (newly covered and the allowance edges)
plant "remnant in .github/"                 .github/workflows/ci.yml  '  plugin-validate: npx claude plugin validate'
plant "remnant in tools/"                   tools/build-install.sh    '# plugins/cache'
plant "remnant in PRIVACY.md"               PRIVACY.md                'The marketplace copy lives in the cache.'
plant "remnant in generated install.sh"     install.sh                '# plugins/cache'
plant "install.d outside the region"        install.d/30-x.sh         '# claude plugin install'
plant "README outside migration subsection" README.md                 'Run claude plugin marketplace add first.'
plant "region marker outside install.d"     bin/c.sh                  '# >>> PLUGIN_LEFTOVER_CHECK
# plugins/cache'
plant "other test file (no allowance)"      tests/test_y.sh           '# CLAUDE_PLUGIN_ROOT'

g="$(fixture)" || { echo "mktemp failed" >&2; exit 1; }
cleanup_on_exit "$g"
mkdir -p "$g/.claude-plugin"
n_plants=$((n_plants + 1))
check "planted: .claude-plugin/ directory -> caught" yes "$(caught "$g")"
g="$(fixture)" || { echo "mktemp failed" >&2; exit 1; }
cleanup_on_exit "$g"
mkdir -p "$g/hooks" && printf '{}\n' > "$g/hooks/hooks.json"
n_plants=$((n_plants + 1))
check "planted: hooks/hooks.json file -> caught" yes "$(caught "$g")"
echo "  ($n_plants plants)"

finish
