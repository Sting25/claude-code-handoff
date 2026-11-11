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
  if [[ "$scope" == project ]]; then
    # Refuse a .claude/ or settings link that points nowhere BEFORE anything
    # is copied: creating the missing target directory would put a directory
    # the user never asked for inside their dotfiles, and a marker naming
    # <project>/.claude for it would let a later --uninstall remove the
    # user's pre-existing .claude/ (#194).
    _pc="$project_dir/.claude"
    if [[ -L "$_pc" && ! -d "$_pc" ]]; then
      echo "ERROR: $_pc is a dangling symlink (-> $(readlink "$_pc" 2>/dev/null || true)); refusing to create its target." >&2
      echo "       Create the directory it points to, or remove the link, and re-run." >&2
      exit 2
    elif [[ -e "$_pc" && ! -d "$_pc" ]]; then
      echo "ERROR: $_pc exists but is not a directory; refusing." >&2
      exit 2
    elif [[ -n "$settings_link" && ! -d "$(dirname "$settings")" ]]; then
      echo "ERROR: $settings_link is a dangling symlink (-> $settings, whose directory does not exist); refusing to create it." >&2
      echo "       Create $(dirname "$settings")/, or remove the link, and re-run." >&2
      exit 2
    fi
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
    # Only <project>/.claude itself is ever created (the refusals above rule
    # out a dangling link). It is never removed again, not even by
    # --uninstall: a directory identity check (inode, birth time) cannot be
    # trusted on every filesystem (FAT32), so a recreated .claude/ could be
    # mistaken for ours.
    if [[ ! -e "$project_dir/.claude" && ! -L "$project_dir/.claude" ]]; then
      mkdir "$project_dir/.claude"
      echo "  new     $project_dir/.claude/"
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
  if (( sh_jq_failed )); then
    echo "  ERROR   jq failed while checking $settings for our hooks; the project was NOT registered." >&2
    echo "          fix jq and re-run $(rerun_cmd)." >&2
    exit 1
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
    # No file left for the markers to describe. Only this project's: a key
    # directory naming another project is left alone.
    project_key_check
    case "$project_key_state" in
      own|legacy) rm -f "$(created_marker)" 2>/dev/null || true ;;
      foreign) project_key_warn_foreign ;;
    esac
    project_key_release
    echo
    echo "done. the repo at $repo_root is untouched."
    exit 0
  fi
  echo "project settings ($project_dir):"
  check_created_settings
  unpatch_settings
  # A refused or unfinished strip (invalid JSON, no jq, a failed skeleton
  # check) consumes nothing: markers and the registry line stay, so the
  # hooks still wired there are still listed, and a re-run can finish.
  (( uninstall_incomplete )) || remove_created_settings_if_empty
  if (( uninstall_incomplete )); then
    echo
    echo "NOT done: $settings was not fully unpatched (see above). The registry"
    echo "      line and markers were kept; fix it and re-run $(rerun_cmd) --uninstall."
    exit 1
  fi
  registry_remove "$project_dir" "$settings_name"
  project_key_release
  echo
  echo "kept (project scope): $claude_home/bin scripts, $claude_home/skills, and the"
  echo "      HMAC secret are shared by every project on this machine and were not"
  echo "      removed. Run ./install.sh --uninstall (user scope) to remove them."
  echo
  echo "done. the repo at $repo_root is untouched."
else
  echo "uninstalling handoff skill from $claude_home"
  echo
  # Settings first, then files: a jq-probe abort inside unpatch_settings (#187)
  # restores settings.json and must leave the bin/ scripts the hooks call in
  # place, so a re-run of --uninstall finds everything it needs.
  echo "settings.json:"
  unpatch_settings
  # A refused or unfinished strip (invalid JSON, no jq, #215/#208) leaves the
  # hooks wired. Removing the bin/ links now would leave every one of them
  # dangling and the exit code would call that success: stop before anything
  # is removed, so a re-run after the fix can finish.
  if (( uninstall_incomplete )); then
    echo
    echo "NOT done: $settings was not fully unpatched (see above). The bin/ links,"
    echo "      skills and HMAC secret were kept so the hooks still wired there keep"
    echo "      working; fix it and re-run ./install.sh --uninstall."
    exit 1
  fi
  echo
  echo "symlinks:"
  uninstall_symlinks
  echo
  echo "local state:"
  # Registry first (issue #171 review): projects still wired sign their
  # handoffs with the same per-machine secret, so deleting it here would
  # silently downgrade every one of them. Keep it automatically while any
  # registered project is wired; --remove-secret deletes it anyway.
  # The scan runs in this shell (registry_collect), not a command
  # substitution, so a jq failure on a registered file is seen here. Every
  # unreadable file would read as stale, which would delete the secret those
  # projects still sign with: stop instead, before anything that depends on
  # the scan.
  scan_prev_failed=$sh_jq_failed
  sh_jq_failed=0
  registry_unparseable_unknown=1
  registry_collect wired
  registry_unparseable_unknown=0
  orphan_list="$REGISTRY_OUT"
  if (( sh_jq_failed )); then
    # The re-run repeats the secret flag the user passed, so it does the
    # same thing once jq (or the file) is fixed.
    rerun_flags=""
    if (( remove_secret )); then rerun_flags=" --remove-secret"; fi
    if (( keep_secret )); then rerun_flags=" --keep-secret"; fi
    echo "  ERROR   ${sh_jq_failed_why:-jq failed} while reading $sh_jq_failed_file from the project registry" >&2
    echo "          ($project_registry), so it is unknown which projects still sign" >&2
    echo "          with the HMAC secret; ${HANDOFF_SECRET_FILE:-$claude_home/handoff_secret}" >&2
    echo "          was kept and the registry left as it was. Settings and bin/ links" >&2
    echo "          were already removed above. Fix jq, or fix the file named above," >&2
    echo "          and re-run ./install.sh --uninstall$rerun_flags." >&2
    exit 1
  fi
  sh_jq_failed=$scan_prev_failed
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
