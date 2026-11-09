maybe_uninstall_hook() {
  local event="$1" marker="$2"
  if ! jq -e --arg e "$event" --arg m "$marker" \
         '(.hooks[$e] // []) | any(.. | .command? // "" | contains($m))' \
         "$settings" >/dev/null 2>&1; then
    echo "  ok      hook $event (not present)"
    return
  fi
  # Remove only the matching command(s), not the whole hook group: a group may
  # hold a user's own co-located command alongside ours. Strip matching commands
  # from each group's inner list, then drop groups that became empty, then drop
  # the event if no groups remain.
  jq --arg e "$event" --arg m "$marker" '
    .hooks[$e] |= (
        map(.hooks |= ((. // []) | map(select(((.command // "") | contains($m)) | not))))
      | map(select((.hooks // []) | length > 0))
    )
    | if ((.hooks[$e] // []) | length) == 0 then del(.hooks[$e]) else . end
  ' "$settings" > "$settings.tmp"
  commit_settings_tmp
  echo "  remove  hook $event"
}

maybe_uninstall_perm() {
  local perm="$1"
  if ! jq -e --arg p "$perm" '(.permissions.allow // []) | index($p)' \
         "$settings" >/dev/null 2>&1; then
    echo "  ok      permission not present: $perm"
    return
  fi
  jq --arg p "$perm" '
    .permissions.allow |= (map(select(. != $p)))
  ' "$settings" > "$settings.tmp"
  commit_settings_tmp
  echo "  remove  permission: $perm"
}

# Migration: pre-0.3.0 SessionStart was an inline bash one-liner that
# cat'd handoff_current.md directly. We detect that legacy form (by a
# substring unique to the inline command, not present in the new
# script-call form) and remove it so re-install replaces — not duplicates —
# the hook.
migrate_legacy_ss_hook() {
  local marker="$ss_legacy_marker"
  if ! jq -e --arg m "$marker" \
         '(.hooks.SessionStart // []) | any(.. | .command? // "" | contains($m))' \
         "$settings" >/dev/null 2>&1; then
    return
  fi
  jq --arg m "$marker" '
    .hooks.SessionStart |= (
        map(.hooks |= ((. // []) | map(select(((.command // "") | contains($m)) | not))))
      | map(select((.hooks // []) | length > 0))
    )
    | if ((.hooks.SessionStart // []) | length) == 0 then del(.hooks.SessionStart) else . end
  ' "$settings" > "$settings.tmp"
  commit_settings_tmp
  echo "  migrate legacy SessionStart inline command removed (pre-0.3.0)"
}

# (The former migrate_legacy_se_hook — pre-0.5.0 SessionEnd forms missing
# --if-curated — is gone: those commands contain the script-path marker, so
# maybe_install_hook's stale-command reconcile now rewrites them generically.
# migrate_legacy_ss_hook above must stay: the pre-0.3.0 inline form has no
# script path in it, so the marker can't find it.)

# Make settings.json safe to patch. Absent or empty -> seed `{}` (jq on empty
# input silently emits nothing, which would blank the file with a false-success
# exit 0). Non-empty but invalid JSON -> refuse to touch it rather than abort
# mid-run or clobber recoverable user config; print the manual snippet instead.
# Returns 0 when the file is valid JSON and safe to patch, 1 to skip patching.
ensure_settings_json() {
  if [[ ! -f "$settings" ]]; then
    echo '{}' > "$settings"
    settings_seed_state=absent
    echo "  new     $settings (created with {})"
    return 0
  fi
  if [[ ! -s "$settings" ]]; then
    echo '{}' > "$settings"
    settings_seed_state=empty
    echo "  init    $settings was empty; set to {}"
    return 0
  fi
  if ! jq -e . "$settings" >/dev/null 2>&1; then
    echo
    echo "  ERROR   $settings is not valid JSON — refusing to auto-patch (left untouched)."
    echo "          Fix or remove it and re-run, or patch settings.json by hand:"
    print_manual_snippet
    return 1
  fi
  # Valid JSON, but the patch jq programs index it as an object (.hooks //= {},
  # .permissions.allow, …). A valid non-object root ([], 42, "x", true) would
  # otherwise sail past the check above and hit a raw jq runtime error mid-patch
  # (caught by the rollback trap, but ugly and confusing). Refuse it cleanly up
  # front instead. (settings#3)
  if ! jq -e 'type == "object"' "$settings" >/dev/null 2>&1; then
    echo
    echo "  ERROR   $settings is valid JSON but not a JSON object (got: $(jq -r 'type' "$settings" 2>/dev/null))."
    echo "          settings.json must be an object — refusing to auto-patch (left untouched)."
    echo "          Fix or remove it and re-run, or patch settings.json by hand:"
    print_manual_snippet
    return 1
  fi
  return 0
}

# Back up $settings before the first edit and arm the path cleanup()
# restores from. User scope keeps the historical <file>.bak.<ts> next to the
# file. Project scope (issue #171) writes it under $project_backup_dir in
# $claude_home instead, so a backup never sits inside the project where a
# `git add .` would commit it.
take_settings_backup() {
  if [[ "$scope" == project ]]; then
    mkdir -p "$project_backup_dir"
    settings_backup="$project_backup_dir/$settings_name.bak.$ts"
  else
    settings_backup="$settings.bak.$ts"
  fi
  cp "$settings" "$settings_backup"
  echo "  backup  $settings -> $settings_backup"
}

patch_settings() {
  if ! command -v jq >/dev/null 2>&1; then
    echo
    echo "jq not found — can't auto-patch $settings."
    print_manual_snippet
    return
  fi
  ensure_settings_json || return
  if [[ "$scope" == project && -n "$settings_seed_state" ]]; then
    # Project scope never backs up a file this run just seeded as {}: there
    # is nothing to keep, and cleanup() undoes the seed itself on abort.
    settings_backup=""
    echo "  ok      no backup needed ($settings was just created; an abort undoes that)"
  else
    take_settings_backup
  fi
  # Arm restore-on-abort: from here until the sequence completes, any abort
  # rolls settings.json back to this backup (see cleanup() / the EXIT trap).
  patch_in_progress=1
  migrate_legacy_ss_hook
  maybe_install_hook SessionStart     "$ss_marker" "$ss_cmd"
  maybe_install_hook SessionEnd       "$se_marker" "$se_cmd"
  # Marker detection is event-scoped, so PreCompact can safely reuse the
  # SessionEnd marker: each event's hook list is checked independently.
  maybe_install_hook PreCompact       "$se_marker" "$pc_cmd"
  maybe_install_hook PostCompact      "$post_marker" "$post_cmd"
  maybe_install_hook WorktreeRemove   "$wr_marker" "$wr_cmd"
  maybe_install_hook Stop             "$st_marker" "$st_cmd"
  maybe_install_hook UserPromptSubmit "$up_marker" "$up_cmd"
  maybe_install_statusline
  maybe_install_perm "$perm_write"
  maybe_install_perm "$perm_stop"
  maybe_install_perm "$perm_ctx"
  maybe_install_perm "$perm_ss"
  maybe_install_perm "$perm_sl"
  maybe_install_perm "$perm_reset"
  maybe_install_perm "$perm_wr"
  maybe_install_model
  patch_in_progress=0   # full sequence succeeded; disarm restore-on-abort
  # If no change vs backup, drop the redundant backup.
  if [[ -n "$settings_backup" ]] && cmp -s "$settings" "$settings_backup"; then
    rm "$settings_backup"
    echo "  ok      no settings.json changes (backup removed)"
  fi
}

unpatch_settings() {
  if ! command -v jq >/dev/null 2>&1; then
    echo
    echo "jq not found — can't auto-strip entries from $settings."
    echo "Manually remove any hook commands containing:"
    echo "  - $ss_marker"
    echo "  - $se_marker  (both the SessionEnd and PreCompact entries)"
    echo "  - $post_marker"
    echo "  - $wr_marker"
    echo "  - $st_marker"
    echo "  - $up_marker"
    echo "the \"statusLine\" entry if its command contains:"
    echo "  - $sl_marker"
    echo "and the permission entries:"
    echo "  - $perm_write"
    echo "  - $perm_stop"
    echo "  - $perm_ctx"
    echo "  - $perm_ss"
    echo "  - $perm_sl"
    echo "  - $perm_reset"
    echo "  - $perm_wr"
    echo "and, if you used --model, the top-level \"model\" key (the value this"
    echo "installer wrote, if any, is recorded in $model_pin_record)."
    return
  fi
  if [[ ! -f "$settings" ]]; then
    echo "  ok      $settings does not exist; nothing to strip"
    return
  fi
  if [[ ! -s "$settings" ]]; then
    echo "  ok      $settings is empty; nothing to strip"
    return
  fi
  if ! jq -e . "$settings" >/dev/null 2>&1; then
    echo "  ERROR   $settings is not valid JSON — refusing to edit (left untouched)."
    return
  fi
  take_settings_backup
  patch_in_progress=1
  maybe_uninstall_hook SessionStart     "$ss_marker"
  maybe_uninstall_hook SessionStart     "$ss_legacy_marker"
  maybe_uninstall_hook SessionEnd       "$se_marker"
  maybe_uninstall_hook PreCompact       "$se_marker"
  maybe_uninstall_hook PostCompact      "$post_marker"
  maybe_uninstall_hook WorktreeRemove   "$wr_marker"
  maybe_uninstall_hook Stop             "$st_marker"
  maybe_uninstall_hook UserPromptSubmit "$up_marker"
  maybe_uninstall_statusline
  maybe_uninstall_perm "$perm_write"
  maybe_uninstall_perm "$perm_stop"
  maybe_uninstall_perm "$perm_ctx"
  maybe_uninstall_perm "$perm_ss"
  maybe_uninstall_perm "$perm_sl"
  maybe_uninstall_perm "$perm_reset"
  maybe_uninstall_perm "$perm_wr"
  maybe_uninstall_model
  patch_in_progress=0   # full sequence succeeded; disarm restore-on-abort
  if cmp -s "$settings" "$settings_backup"; then
    rm "$settings_backup"
    echo "  ok      no settings.json changes (backup removed)"
  fi
}

# Single source of truth for "will the next handoff be HMAC-signed" — reused
# by doctor() (detailed per-item report, below) and the installer's
# first-run summary (install.d/40-main.sh). Mirrors the EXACT preconditions
# bin/handoff_provenance.sh's handoff_mac_compute checks, in the same order
# it checks them:
#   1. openssl on PATH — handoff_mac_compute's very first line
#      (`command -v openssl >/dev/null 2>&1 || return 1`); required for every
#      call regardless of secret state, since HMAC-SHA256 is built from two
#      openssl digest passes. No openssl => degraded, full stop.
#   2. the secret file (handoff_secret_path: $HANDOFF_SECRET_FILE, else
#      $claude_home/handoff_secret) must be usable: not a symlink (the
#      signer refuses one outright — handoff_ensure_secret/handoff_mac_compute
#      both `return 1`), and — for an EXISTING path — a regular, non-empty
#      file (handoff_mac_compute's verify branch requires `-f` AND `-s`;
#      `key="$(cat "$sf")"` then `[ -n "$key" ]` guards the empty case again).
#      A path that exists but isn't a regular file can't be read as a key.
#   3. absent entirely is NOT degraded: handoff_ensure_secret mints one
#      lazily on the first signed write (openssl rand, or /dev/urandom via od
#      as fallback) — reported as its own distinct state, not lumped with
#      "active" or "degraded", since nothing has actually signed yet.
# Echoes one of: "active", "degraded: <reason>", or
# "pending: <reason>" (not yet signed, but will self-heal on first write).
# Never touches `broken` — callers decide what (if anything) that means.
signing_status_reason() {
  local secret="${HANDOFF_SECRET_FILE:-$claude_home/handoff_secret}"
  if ! command -v openssl >/dev/null 2>&1; then
    echo "degraded: openssl not found on PATH"
  elif [[ -L "$secret" ]]; then
    echo "degraded: secret file ($secret) is a symlink — the signer refuses it"
  elif [[ -f "$secret" ]]; then
    # Probe with the signer's own load, not -s: handoff_mac_compute requires
    # `cat` to succeed AND the key to be non-empty after $() strips trailing
    # newlines, so an unreadable or newline-only secret passed -f/-s here
    # ("active") while every write silently degraded to unsigned. The probe
    # runs in a subshell and prints nothing — key bytes never reach output
    # or this shell's state.
    if ( k="$(cat "$secret" 2>/dev/null)" && [ -n "$k" ] ); then
      echo "active"
    elif [[ ! -r "$secret" ]]; then
      echo "degraded: secret file ($secret) is not readable by this user"
    else
      echo "degraded: secret file ($secret) is empty"
    fi
  elif [[ -e "$secret" ]]; then
    echo "degraded: secret path ($secret) exists but is not a regular file"
  else
    echo "pending: no secret yet — one is generated on the first signed write"
  fi
}

# The install command that re-creates THIS run's wiring, for remedies doctor
# prints: a project-scope doctor must not tell the user to run a bare
# ./install.sh, which would wire the user-scope file instead (issue #171).
rerun_cmd() {
  if [[ "$scope" == project ]]; then
    if (( use_local )); then
      printf '%s\n' "./install.sh --scope project --project $project_dir --local"
    else
      printf '%s\n' "./install.sh --scope project --project $project_dir"
    fi
  else
    printf '%s\n' "./install.sh"
  fi
}

# settings_has_our_hooks <file>: 0 when <file> exists, parses, and wires at
# least one of this installer's hook commands (the markers the patcher
# writes). 1 otherwise, including when jq is missing.
settings_has_our_hooks() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -e --arg ss "$ss_marker" --arg se "$se_marker" --arg post "$post_marker" \
        --arg wr "$wr_marker" --arg st "$st_marker" --arg up "$up_marker" '
      type == "object" and (
      ( (.hooks.SessionStart // [])     | any(.. | .command? // "" | contains($ss)) ) or
      ( (.hooks.SessionEnd // [])       | any(.. | .command? // "" | contains($se)) ) or
      ( (.hooks.PreCompact // [])       | any(.. | .command? // "" | contains($se)) ) or
      ( (.hooks.PostCompact // [])      | any(.. | .command? // "" | contains($post)) ) or
      ( (.hooks.WorktreeRemove // [])   | any(.. | .command? // "" | contains($wr)) ) or
      ( (.hooks.Stop // [])             | any(.. | .command? // "" | contains($st)) ) or
      ( (.hooks.UserPromptSubmit // []) | any(.. | .command? // "" | contains($up)) ) )
    ' "$f" >/dev/null 2>&1
}

# Physical path of a settings file (symlinks resolved, directory made
# physical), so the wiring check below never counts one file twice: a
# project rooted at $HOME, or a dotfiles link, can make two spellings name
# the same file. Prints nothing when the directory does not exist.
settings_phys_path() {
  local f d
  f="$(resolve_symlink "$1")"
  d="$(cd "$(dirname "$f")" 2>/dev/null && pwd -P)" || return 0
  printf '%s/%s\n' "$d" "$(basename "$f")"
}

# Project root the wiring checks look at: --project in project scope; in
# user scope the git toplevel of $PWD (so a doctor run from a subdirectory
# still finds the project's .claude/), else $PWD itself.
wiring_project_root() {
  local top=""
  if [[ "$scope" == project ]]; then
    printf '%s\n' "$project_dir"
    return 0
  fi
  if command -v git >/dev/null 2>&1; then
    top="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)"
  fi
  printf '%s\n' "${top:-$PWD}"
}

# Wiring layout check (issue #171). Claude Code runs an identical handler
# defined in more than one settings file once, so several wired files do
# not double fire. What this reports instead:
#   (a) user-scope wiring present alongside a project-scope layout (or at all,
#     in project scope): the hooks then fire in EVERY project on the
#     machine, which the project-only layout exists to avoid;
#   (b) both project files wired: redundant, one can go.
# Lists exactly which of the three files carry our hooks and the uninstall
# command for each extra one. <label> is WARN (doctor) or NOTE (install).
# Advisory only, never counts toward `broken`.
report_wiring() {
  local label="$1" proj pu ps pl u=0 sw=0 lw=0 user_issue=0 dup_issue=0 p1 pc
  proj="$(wiring_project_root)"
  pu="$(settings_phys_path "$user_settings")"
  ps="$(settings_phys_path "$proj/.claude/settings.json")"
  pl="$(settings_phys_path "$proj/.claude/settings.local.json")"
  if [[ -n "$pu" ]] && settings_has_our_hooks "$pu"; then u=1; fi
  if [[ -n "$ps" && "$ps" != "$pu" ]] && settings_has_our_hooks "$ps"; then sw=1; fi
  if [[ -n "$pl" && "$pl" != "$pu" && "$pl" != "$ps" ]] && settings_has_our_hooks "$pl"; then lw=1; fi
  if (( u )) && { [[ "$scope" == project ]] || (( sw || lw )); }; then user_issue=1; fi
  if (( sw && lw )); then dup_issue=1; fi
  (( user_issue || dup_issue )) || return 0
  if [[ "$label" == NOTE ]]; then p1="NOTE: "; pc="      "; else p1="  WARN    "; pc="          "; fi
  echo "${p1}this installer's hooks are wired in these settings files for $proj:"
  if (( u ));  then echo "${pc}  $user_settings (user scope)"; fi
  if (( sw )); then echo "${pc}  $proj/.claude/settings.json (project)"; fi
  if (( lw )); then echo "${pc}  $proj/.claude/settings.local.json (project, local)"; fi
  if (( user_issue )); then
    echo "${pc}User-scope wiring present: these hooks fire in every project on this"
    echo "${pc}machine, which the project-only layout exists to avoid. To remove it run"
    echo "${pc}'./install.sh --uninstall --keep-secret'. Keep the secret: the per-machine"
    echo "${pc}HMAC secret is shared by project-scope installs, and dropping it would"
    echo "${pc}invalidate the signed handoffs in every wired project. A user-scope"
    echo "${pc}uninstall also removes the shared scripts in $claude_home/bin, so re-run"
    echo "${pc}the project install afterwards:"
    if (( sw )); then echo "${pc}  ./install.sh --scope project --project $proj"; fi
    if (( lw )); then echo "${pc}  ./install.sh --scope project --project $proj --local"; fi
    if (( ! sw && ! lw )); then echo "${pc}  $(rerun_cmd)"; fi
  fi
  if (( dup_issue )); then
    echo "${pc}Both project files carry the hooks. Claude Code runs them once, so this"
    echo "${pc}is redundant rather than broken; keep one. To remove the extra one run:"
    if [[ "$scope" == project ]] && (( use_local )); then
      echo "${pc}  ./install.sh --uninstall --scope project --project $proj"
    else
      echo "${pc}  ./install.sh --uninstall --scope project --project $proj --local"
    fi
    if [[ "$scope" != project ]]; then
      echo "${pc}  (or drop settings.json instead: the same command without --local)"
    fi
  fi
  echo
}

# --- project registry (issue #171) -------------------------------------------
# $project_registry holds one "<project dir><TAB><file name>" line per
# project-scope install. Never written through a symlink, like the other
# per-user state under $claude_home.
registry_add() {  # <project dir> <settings file name>
  local line="$1"$'\t'"$2"
  if [[ -L "$project_registry" ]]; then
    echo "  skip    registry ($project_registry is a symlink; not writing through it)"
    return 0
  fi
  if [[ -f "$project_registry" ]] && grep -Fxq -- "$line" "$project_registry"; then
    echo "  ok      registry entry present: $1 ($2)"
    return 0
  fi
  mkdir -p "$claude_home"
  printf '%s\n' "$line" >> "$project_registry"
  echo "  add     registry: $1 ($2) in $project_registry"
}

registry_remove() {  # <project dir> <settings file name>
  local line="$1"$'\t'"$2"
  [[ -f "$project_registry" && ! -L "$project_registry" ]] || return 0
  grep -Fxq -- "$line" "$project_registry" || return 0
  # grep -v exits 1 when no line survives; that is the empty-registry case.
  grep -Fxv -- "$line" "$project_registry" > "$project_registry.tmp" || true
  mv "$project_registry.tmp" "$project_registry"
  [[ -s "$project_registry" ]] || rm -f "$project_registry"
  echo "  remove  registry: $1 ($2)"
}

# registry_scan <wired|stale>: print "<dir> (<name>)" for each registered
# project whose file does (wired) or does not (stale) carry our hooks.
registry_scan() {
  local want="$1" rp rn has
  [[ -f "$project_registry" && ! -L "$project_registry" ]] || return 0
  while IFS=$'\t' read -r rp rn || [[ -n "$rp" ]]; do
    [[ -n "$rp" ]] || continue
    case "$rn" in settings.json|settings.local.json) ;; *) continue ;; esac
    has=stale
    if settings_has_our_hooks "$rp/.claude/$rn"; then has=wired; fi
    if [[ "$has" == "$want" ]]; then printf '%s (%s)\n' "$rp" "$rn"; fi
  done < "$project_registry"
  return 0
}

# User-scope --uninstall: warn about every registered project still wired,
# since their hooks call the scripts this uninstall removes.
report_registry_orphans() {
  local list _l
  list="$(registry_scan wired)"
  [[ -n "$list" ]] || return 0
  echo "  WARN    project-scope installs still wired (from $project_registry):"
  while IFS= read -r _l; do echo "            $_l"; done <<< "$list"
  echo "          Their hooks call the scripts this uninstall removes from"
  echo "          $claude_home/bin, so they will silently no-op until each project is"
  echo "          re-wired with './install.sh --scope project --project <dir>' or"
  echo "          uninstalled with './install.sh --uninstall --scope project --project <dir>'"
  echo "          (add --local for settings.local.json)."
}

# User-scope doctor: name registered projects whose file no longer carries
# our hooks. Informational only.
report_registry_stale() {
  local list _l
  list="$(registry_scan stale)"
  [[ -n "$list" ]] || return 0
  echo "  note    stale project registry entries (the file no longer carries this"
  echo "          installer's hooks), from $project_registry:"
  while IFS= read -r _l; do echo "            $_l"; done <<< "$list"
  echo "          Clear one with './install.sh --uninstall --scope project --project <dir>'"
  echo "          (add --local for settings.local.json), or delete its line from the file."
  echo
}

# >>> PLUGIN_LEFTOVER_CHECK (the one place the shipped tree may name the
# retired plugin layout; tests/test_no_plugin_remnants.sh skips this region)
# A plugin install of this tool left behind after the #171 migration runs its
# own hook commands (under the plugin's root) next to these scripts. Those
# commands differ from ours, so Claude Code's identical-handler dedupe does
# not apply and every hook runs twice. Read-only, jq optional.
#
# Signal: Claude Code's installed_plugins.json registry when it exists (a
# cache directory can outlive an uninstall, so a cache alone would be a
# false positive forever once the registry has dropped the entry); the cache
# glob alone only when there is no registry file at all.
# report_plugin_leftover <NOTE|WARN>: prints the message, or nothing.
report_plugin_leftover() {
  local tag="$1" base pd cache="" reg where scopes=""
  base="${CLAUDE_CONFIG_DIR:-$claude_home}"
  for pd in "$base"/plugins/cache/*/claude-code-handoff; do
    if [[ -d "$pd" ]]; then cache="$pd"; break; fi
  done
  reg="$base/plugins/installed_plugins.json"
  if [[ -f "$reg" ]]; then
    LC_ALL=C grep -q 'claude-code-handoff' "$reg" 2>/dev/null || return 0
    where="${cache:-$reg}"
    if command -v jq >/dev/null 2>&1; then
      scopes="$(jq -r '(.plugins // {}) | to_entries[]
                 | select(.key | startswith("claude-code-handoff@"))
                 | .value | if type == "array" then .[] else . end
                 | .scope? // empty' "$reg" 2>/dev/null | sort -u | paste -sd '|' - || true)"
    fi
  elif [[ -n "$cache" ]]; then
    where="$cache"
  else
    return 0
  fi
  [[ -n "$scopes" ]] || scopes="project|user"
  case "$scopes" in *"|"*) scopes="<$scopes>" ;; esac
  printf '%-8s%s\n' "$tag" "A plugin install of this tool is still present at $where;"
  echo "        its hooks run alongside these scripts. Finish the migration:"
  echo "        'claude plugin uninstall claude-code-handoff@claude-code-handoff --scope $scopes'"
  echo "        then 'claude plugin marketplace remove claude-code-handoff'."
  echo
}
# <<< PLUGIN_LEFTOVER_CHECK

# Self-check: verify each installed hook script under $claude_home/bin actually
# resolves. A dangling symlink (e.g. installed from a temp checkout that was
# later cleaned up) makes the corresponding hook no-op silently, so surface it
# loudly here. Exit non-zero if anything is broken so CI / a wrapper can detect
# it. (issue #21)

doctor() {
  local broken=0 dst tgt name mdl secret smode sign_reason

  if [[ "$scope" == project ]]; then
    echo "doctor: project scope, checking $settings"
    echo
  fi
  echo "doctor: checking runtime dependencies"
  # jq is a RUNTIME dependency of the Stop hook (payload parsing), the ctx
  # nudge, and the /handoff-recover tail rescue — a resolving script link is
  # not enough if the tool it needs is missing (they all no-op silently).
  if ! command -v jq >/dev/null 2>&1; then
    echo "  BROKEN  jq not found on PATH (Stop hook, ctx nudge, and /handoff-recover tail rescue are silently disabled)"
    broken=$((broken + 1))
  fi
  # openssl is an OPTIONAL runtime dependency (HMAC-signing the handoff so its
  # rules layer can load as binding — issue #42). Its absence is a designed
  # degradation, not breakage: everything still works, the rules just load as
  # reference data. Advisory note only; never counts toward broken.
  if ! command -v openssl >/dev/null 2>&1; then
    echo "  note    openssl not found on PATH (optional): handoffs won't be"
    echo "          HMAC-signed, so the rules/pinned layer loads as reference"
    echo "          data instead of binding rules. Install openssl to enable."
  fi
  echo

  echo "doctor: checking installed handoff hooks under $claude_home/bin"
  for name in write_handoff handoff_turn_append handoff_ctx_check handoff_session_start handoff_recover_tail handoff_statusline handoff_compact_reset handoff_worktree_remove handoff_provenance; do
    dst="$claude_home/bin/$name.sh"
    if [[ -e "$dst" ]]; then
      if [[ -L "$dst" ]]; then
        echo "  ok      $dst -> $(readlink "$dst")"
      else
        echo "  ok      $dst (copy)"
      fi
    elif [[ -L "$dst" ]]; then
      tgt="$(readlink "$dst" 2>/dev/null || true)"
      echo "  BROKEN  $dst -> $tgt (dangling symlink: hook is silently disabled)"
      broken=$((broken + 1))
    else
      echo "  MISSING $dst (not installed)"
      broken=$((broken + 1))
    fi
  done
  echo
  # Secret-file hygiene. The per-machine HMAC secret is what makes a
  # handoff's rules layer load as BINDING (issue #42): group/other-readable,
  # any local reader can forge the trailer; a symlink at the path could be
  # planted to point key generation somewhere attacker-readable (the signer
  # refuses it, silently degrading to unsigned). Same effective path as the
  # runtime and remove_secret_if_ours: the HANDOFF_SECRET_FILE override wins
  # over the default under $claude_home — doctor is read-only, so unlike
  # uninstall it can safely inspect an overridden location. Absent is NOT an
  # error: the secret is minted lazily on the first signed write.
  secret="${HANDOFF_SECRET_FILE:-$claude_home/handoff_secret}"
  if [[ -L "$secret" ]]; then
    echo "  BROKEN  $secret is a symlink (possibly planted) — the signer refuses it;"
    echo "          remove the link: rm '$secret' (a fresh secret is generated on the next signed write)"
    broken=$((broken + 1))
  elif [[ -f "$secret" ]]; then
    # Portable mode read: GNU stat -c %a with BSD stat -f %Lp fallback.
    smode="$(stat -c %a "$secret" 2>/dev/null || stat -f %Lp "$secret" 2>/dev/null)" || smode=""
    if [[ "$smode" =~ ^[0-7]+$ ]] && (( 8#$smode & 8#77 )); then
      echo "  BROKEN  $secret is group/other-readable (mode $smode) — the HMAC key is"
      echo "          exposed to other local users; run: chmod 600 '$secret'"
      broken=$((broken + 1))
    else
      echo "  ok      $secret (regular file, mode ${smode:-unreadable}, no group/other access)"
    fi
  elif [[ -e "$secret" ]]; then
    # Exists but is not a regular file (directory, fifo, ...): the signer
    # can't use it, so signing is silently disabled — that's breakage.
    echo "  BROKEN  $secret exists but is not a regular file — signing is silently disabled"
    broken=$((broken + 1))
  else
    echo "  note    $secret absent — generated on first signed write (not an error)"
  fi
  # Signing status — one-line summary answering "will the next handoff be
  # HMAC-signed", consolidating the openssl/secret checks above (which say
  # WHY per-artifact) into the single yes/no-and-why question a user actually
  # asks. Never counts toward `broken` itself — the checks above already
  # flip that for cases the signer can't recover from (a symlinked or
  # non-regular secret); this line would just double-count them.
  sign_reason="$(signing_status_reason)"
  case "$sign_reason" in
    active)
      echo "  ok      handoff signing: active"
      ;;
    degraded:*)
      echo "  note    handoff signing: ${sign_reason#degraded: }"
      ;;
    pending:*)
      echo "  note    handoff signing: ${sign_reason#pending: }"
      ;;
  esac
  echo
  # statusLine wiring report — informational only, never counts toward
  # `broken`: an unwired or user-owned statusLine is a legitimate state (we
  # never overwrite a user's own setting), not a fault. Only a dangling
  # SCRIPT (reported by the loop above) is real breakage.
  #
  # A missing settings file still gets a line rather than silence: the
  # status line is the context nudge's most accurate signal, so its absence
  # is worth naming even when there is no file to inspect.
  if command -v jq >/dev/null 2>&1 && [[ ! -f "$settings" ]]; then
    echo "  info    statusLine unset (re-run $(rerun_cmd) to wire it)"
    echo
  elif command -v jq >/dev/null 2>&1 && [[ -f "$settings" ]]; then
    if jq -e --arg m "$sl_marker" '(.statusLine.command // "") | contains($m)' \
         "$settings" >/dev/null 2>&1; then
      echo "  ok      statusLine wired (ours)"
    elif jq -e '(.statusLine // null) != null' "$settings" >/dev/null 2>&1; then
      echo "  info    statusLine present (user's own — manual wiring documented in README)"
    else
      echo "  info    statusLine unset (re-run $(rerun_cmd) to wire it)"
    fi
    # Model context-window check — advisory only, never counts toward broken:
    # a bare 'opus'/'claude-opus-4-8' pin silently runs at a 200k context
    # window; the 1M variant needs the [1m] suffix. Any other value (including
    # absent) is a legitimate choice we stay quiet about.
    mdl="$(jq -r '.model // ""' "$settings" 2>/dev/null)"
    case "$mdl" in
      opus|claude-opus-4-8)
        echo "  WARN    model '$mdl' in settings.json is the 200k-context variant —"
        echo "          for the 1M window set \"model\": \"${mdl}[1m]\" (edit settings.json"
        echo "          or run /model ${mdl}[1m] in a session)."
        ;;
    esac
    echo
  fi
  report_wiring WARN
  if [[ "$scope" == user ]]; then
    report_registry_stale
  fi
  report_plugin_leftover "  WARN"
  if (( broken )); then
    echo "doctor: $broken issue(s) found." >&2
    echo "        Re-run $(rerun_cmd) from a persistent clone (not a /tmp checkout)." >&2
    return 1
  fi
  echo "doctor: all hooks resolve."
}

