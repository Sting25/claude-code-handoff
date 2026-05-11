#!/usr/bin/env bash
# install.sh — symlink this repo's handoff skill into ~/.claude/
#
# Idempotent. Existing files at the target paths are backed up to
# <path>.bak.<timestamp> before being replaced with a symlink. Re-runs
# only relink if the target isn't already pointing at this repo.
#
# Does NOT modify ~/.claude/settings.json. After install, paste the
# hooks + permission shown at the end into your settings.json (the
# README has the exact JSON).

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
claude_home="${CLAUDE_HOME:-$HOME/.claude}"
ts="$(date +%Y%m%d_%H%M%S)"

link() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  if [[ -L "$dst" ]]; then
    local current
    current="$(readlink "$dst")"
    if [[ "$current" == "$src" ]]; then
      echo "  ok      $dst -> $src"
      return
    fi
    echo "  relink  $dst (was -> $current)"
    rm "$dst"
  elif [[ -e "$dst" ]]; then
    echo "  backup  $dst -> $dst.bak.$ts"
    mv "$dst" "$dst.bak.$ts"
  else
    echo "  new     $dst"
  fi
  ln -s "$src" "$dst"
}

echo "installing handoff skill from $repo_root into $claude_home"
echo

link "$repo_root/bin/write_handoff.sh"        "$claude_home/bin/write_handoff.sh"
link "$repo_root/bin/handoff_turn_append.sh"  "$claude_home/bin/handoff_turn_append.sh"
link "$repo_root/skills/handoff/SKILL.md"     "$claude_home/skills/handoff/SKILL.md"
link "$repo_root/skills/handoff/README.md"    "$claude_home/skills/handoff/README.md"

chmod +x "$repo_root/bin/write_handoff.sh" "$repo_root/bin/handoff_turn_append.sh"

cat <<EOF

done.

Next step — add these to $claude_home/settings.json (under "hooks" and
"permissions"). The exact JSON to paste is in README.md.

  - SessionStart hook: auto-loads .claude/handoff_current.md
  - SessionEnd hook:   silently writes a snapshot on exit
  - Stop hook:         appends each turn to the running raw-dump backup
  - Permissions:       allow Bash($claude_home/bin/write_handoff.sh)
                       allow Bash($claude_home/bin/handoff_turn_append.sh)

Then in a new Claude Code session, /handoff should be available.
EOF
