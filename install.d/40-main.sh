# ------------------------------------------------------------------------ main

# The dispatch lives in one brace group with the cleanup trap as its first
# statement. Bash must parse the entire group before executing any of it, so
# on a truncated `curl | bash` stream the trap is never armed and the parse
# error keeps its nonzero exit (armed earlier, bash 3.2 reports rc=0 — see
# the note above cleanup() in 00-preamble.sh). Residual gap, accepted: a
# stream that truncates exactly at a statement boundary before this group
# still exits 0 having installed nothing — no trap arrangement can catch
# that; only checksum verification of the fetched script would.
{
trap cleanup EXIT

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
  # No usable clone: piped (`curl ... | bash`, no source path), a source path
  # that cannot be entered, or a path that is not a checkout (`bash <(cat
  # install.sh)` gives /dev/fd, which used to install dangling links). An empty
  # root used to surface as `cp: /bin/write_handoff.sh` (#194).
  if [[ -z "$repo_root" ]]; then
    if [[ -n "$repo_root_err" ]]; then
      echo "ERROR: install.sh $repo_root_err, so there is no clone to install from." >&2
    else
      echo "ERROR: install.sh was read from a pipe, so there is no clone to install from." >&2
    fi
    echo "       Clone the repo and run ./install.sh from inside it (see the README)." >&2
    exit 2
  fi
  _rr_phys="$(cd "$repo_root" && pwd -P)"
  case "$_rr_phys/" in
    /dev/*|/proc/*)
      echo "ERROR: install.sh was read from $repo_root (a process-substitution or device path), so there is no clone to install from." >&2
      echo "       Clone the repo and run ./install.sh from inside it (see the README)." >&2
      exit 2 ;;
  esac
  # install.sh itself is self-contained (install.d/ is only its build input),
  # so the checkout test is the file the install links first, bin/write_handoff.sh.
  if [[ ! -f "$repo_root/bin/write_handoff.sh" ]]; then
    echo "ERROR: $repo_root is not a handoff checkout (no bin/write_handoff.sh), so there is no clone to install from." >&2
    echo "       Clone the repo and run ./install.sh from inside it (see the README)." >&2
    exit 2
  fi
  echo "installing handoff skill from $repo_root into $claude_home"
  echo
  echo "symlinks:"
  install_symlinks
  echo
  if [[ "$scope" == project ]]; then
    # Project scope (issue #171): the scripts above are shared from
    # $claude_home; only the wiring goes into the project. Create the
    # project's .claude/ on demand (install mode only: --doctor and
    # --uninstall never create anything).
    echo "project settings ($project_dir):"
    if [[ ! -d "$(dirname "$settings")" ]]; then
      mkdir -p "$(dirname "$settings")"
      claude_dir_made_this_run=1
      echo "  new     $(dirname "$settings")/"
      record_created_claude_dir
    fi
  else
    echo "settings.json:"
  fi
  patch_settings
  # Record the project once its file actually carries our hooks (a refused
  # patch, e.g. invalid JSON, wires nothing and registers nothing).
  if [[ "$scope" == project ]] && settings_has_our_hooks "$settings"; then
    registry_add "$project_dir" "$settings_name"
  fi
  echo
  if [[ -z "$model_pin" ]] && command -v jq >/dev/null 2>&1 && [[ -f "$settings" ]] \
     && jq -e 'type == "object" and ((.model // null) == null)' "$settings" >/dev/null 2>&1; then
    echo "NOTE: no model pinned in $settings."
    echo "      To pin one there, re-run  $(rerun_cmd) --model '<model>'  (for example 'opus[1m]')."
    echo
  fi
  if [[ "$scope" == project ]]; then
    # Checks all three files (user, project settings.json, project
    # settings.local.json): an extra wired file is reported with the
    # uninstall command that removes it.
    report_wiring NOTE
  fi
  report_plugin_leftover "NOTE:"
  if [[ "$scope" == project ]]; then
    echo "note: hooks are wired for $project_dir only ($settings)."
  fi
  echo "done. start a new Claude Code session — /handoff is available now."
  # First-run signing note — one line pointing at --doctor for the detailed
  # per-item report (secret-file hygiene, openssl presence). Uses the same
  # signing_status_reason() doctor() reports from, so the two can never drift.
  sign_reason="$(signing_status_reason)"
  case "$sign_reason" in
    active)
      echo "note: handoff signing is active — new handoffs are HMAC-signed (./install.sh --doctor for detail)."
      ;;
    pending:*)
      echo "note: handoff signing ${sign_reason#pending: } (./install.sh --doctor for detail)."
      ;;
    degraded:*)
      echo "note: handoff signing degraded (${sign_reason#degraded: }) (./install.sh --doctor for detail)."
      ;;
  esac
  if [[ "$COPIED_ANY" == "1" ]]; then
    echo
    echo "note: files were COPIED into $claude_home (copy mode or symlinks"
    echo "      unavailable). After a future 'git pull' in this repo, re-run"
    echo "      ./install.sh to refresh the copies — symlinked installs update"
    echo "      automatically, copies do not."
  fi
elif [[ "$scope" == project ]]; then
  # Project-scope uninstall (issue #171) strips only this project's wiring.
  # The scripts, skills, and HMAC secret under $claude_home are shared by
  # every project on this machine, so they stay; a user-scope --uninstall is
  # the way to remove them.
  echo "uninstalling handoff wiring from $project_dir (project scope)"
  echo
  if (( project_gone )); then
    # The directory is gone (a removed worktree, usually): nothing left to
    # unpatch, so clear its registry line and stop cleanly.
    echo "project settings ($project_dir):"
    echo "  ok      $project_dir no longer exists; nothing to unpatch"
    if ! registry_has "$project_dir" "$settings_name"; then
      echo "  WARN    no registry line '$project_dir<TAB>$settings_name' in $project_registry;"
      echo "          nothing was cleared there (was the project installed under another path?)"
    fi
    registry_remove "$project_dir" "$settings_name"
    rm -f "$(created_marker)" "$(claude_dir_marker)" 2>/dev/null || true   # no file or dir left for them to describe
    echo
    echo "done. the repo at $repo_root is untouched."
    exit 0
  fi
  echo "project settings ($project_dir):"
  check_created_settings
  unpatch_settings
  remove_created_settings_if_empty
  remove_created_claude_dir_if_empty
  registry_remove "$project_dir" "$settings_name"
  echo
  echo "kept (project scope): $claude_home/bin scripts, $claude_home/skills, and the"
  echo "      HMAC secret are shared by every project on this machine and were not"
  echo "      removed. Run ./install.sh --uninstall (user scope) to remove them."
  echo
  echo "done. the repo at $repo_root is untouched."
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
  # Registry first (issue #171 review): projects still wired sign their
  # handoffs with the same per-machine secret, so deleting it here would
  # silently downgrade every one of them. Keep it automatically while any
  # registered project is wired; --remove-secret deletes it anyway.
  orphan_list="$(registry_scan wired)"
  secret_path="${HANDOFF_SECRET_FILE:-$claude_home/handoff_secret}"
  if [[ -n "$orphan_list" ]] && (( ! remove_secret && ! keep_secret )); then
    orphan_n="$(printf '%s\n' "$orphan_list" | wc -l | tr -d ' ')"
    echo "  keep    $secret_path (kept: $orphan_n project-scope install(s) still sign with"
    echo "          it; pass --remove-secret to delete it anyway)"
    secret_note="The HMAC secret $secret_path was kept for them."
  else
    remove_secret_if_ours
    if [[ -e "$secret_path" ]]; then
      secret_note="The HMAC secret $secret_path is still in place."
    else
      secret_note="The HMAC secret $secret_path is gone, so their signed handoffs no longer verify as binding."
    fi
  fi
  report_registry_orphans "$orphan_list" "$secret_note"
  echo
  echo "done. the repo at $repo_root is untouched."
fi
}
