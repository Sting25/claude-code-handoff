# ------------------------------------------------------------------------ main

if [[ "$mode" == doctor ]]; then
  doctor
elif [[ "$mode" == install ]]; then
  # jq is a hard RUNTIME dependency, not just an install-time convenience:
  # without it the Stop hook exits before writing anything (no raw dumps, no
  # ctx measurements), the ctx nudge never fires, and /handoff-recover's tail
  # rescue can't parse the transcript — all silently, because the hooks are
  # wired '... || true'. Installing anyway would print "done" and ship a
  # system that never runs. Refuse up front instead. (--uninstall and --doctor
  # still work without jq.)
  if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq not found on PATH — refusing to install." >&2
    echo "  jq is required at runtime by the Stop hook (raw per-turn dumps)," >&2
    echo "  the context nudge, and /handoff-recover; without it they all no-op" >&2
    echo "  silently. Install jq (e.g. 'apt install jq' / 'brew install jq')" >&2
    echo "  and re-run ./install.sh." >&2
    exit 1
  fi
  echo "installing handoff skill from $repo_root into $claude_home"
  echo
  echo "symlinks:"
  install_symlinks
  echo
  echo "settings.json:"
  patch_settings
  echo
  if [[ -z "$model_pin" ]] && command -v jq >/dev/null 2>&1 && [[ -f "$settings" ]] \
     && jq -e 'type == "object" and ((.model // null) == null)' "$settings" >/dev/null 2>&1; then
    echo "NOTE: no model pinned in settings.json — a bare 'opus' selection runs at a"
    echo "      200k context window. Re-run  ./install.sh --model 'opus[1m]'  to pin one."
    echo
  fi
  # Plugin/script coexistence heads-up (v0.14.0+ ships a plugin form of this
  # tool) — see find_plugin_cache_dir's comment for why this checks $HOME and
  # not $claude_home. Informational only; the install itself proceeds exactly
  # as it always has.
  plugin_cache_dir=""
  if plugin_cache_dir="$(find_plugin_cache_dir)"; then
    echo "NOTE: a plugin install of this tool was detected ($plugin_cache_dir)."
    echo "      Installing the script mode too will double-fire every hook —"
    echo "      Claude Code runs both plugin and script hooks, no dedup."
    echo
  fi
  echo "done. start a new Claude Code session — /handoff is available now."
  if [[ "$COPIED_ANY" == "1" ]]; then
    echo
    echo "note: files were COPIED into $claude_home (copy mode or symlinks"
    echo "      unavailable). After a future 'git pull' in this repo, re-run"
    echo "      ./install.sh to refresh the copies — symlinked installs update"
    echo "      automatically, copies do not."
  fi
else
  echo "uninstalling handoff skill from $claude_home"
  echo
  echo "symlinks:"
  uninstall_symlinks
  echo
  echo "settings.json:"
  unpatch_settings
  echo
  echo "local state:"
  remove_secret_if_ours
  echo
  echo "done. the repo at $repo_root is untouched."
fi
