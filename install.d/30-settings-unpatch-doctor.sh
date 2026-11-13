maybe_uninstall_hook() {
  local event="$1" marker="$2"
  if ! jq_probe "hook $event" --arg e "$event" --arg m "$marker" "$probe_hook" "$settings"; then
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
  if ! jq_probe "permission $perm" --arg p "$perm" "$probe_perm" "$settings"; then
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
  if ! jq_probe "hook SessionStart" --arg e SessionStart --arg m "$marker" "$probe_hook" "$settings"; then
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
  if settings_dir_unsearchable "$settings"; then
    # Hidden, not absent (#213): seeding {} would fail on the redirect, and
    # the old path then printed "new ... (created with {})" and a jq failure.
    echo
    echo "  ERROR   $settings cannot be read (check its permissions: a directory above it"
    echo "          cannot be searched); refusing to auto-patch (left untouched)."
    echo "          Fix the permissions and re-run, or patch settings.json by hand:"
    print_manual_snippet
    return 1
  fi
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
  # Say which of the failures it is (settings_usable, #187/#213): an
  # unreadable file, jq itself failing, and unparseable content are three
  # different causes, and a `null` root is valid JSON that is not an object.
  local usable_rc=0
  settings_usable "$settings" || usable_rc=$?
  if [[ $usable_rc -eq 2 ]]; then
    echo
    echo "  ERROR   jq failed (exit $settings_usable_rc) while reading $settings; refusing to auto-patch (left untouched)."
    echo "          Fix jq and re-run, or patch settings.json by hand:"
    print_manual_snippet
    return 1
  fi
  if [[ $usable_rc -eq 1 && ! -r "$settings" ]]; then
    echo
    echo "  ERROR   $settings cannot be read (check its permissions); refusing to auto-patch (left untouched)."
    echo "          Fix the file's permissions and re-run, or patch settings.json by hand:"
    print_manual_snippet
    return 1
  fi
  if ! jq empty "$settings" >/dev/null 2>&1; then
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
  if [[ $usable_rc -ne 0 ]]; then
    echo
    echo "  ERROR   $settings is valid JSON but not a JSON object (got: $(jq -rs 'if length == 1 then (.[0] | type) else "\(length) documents" end' "$settings" 2>/dev/null))."
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
    [[ "$mode" == install ]] && { project_key_claim || true; }
    settings_backup="$project_backup_dir/$settings_name.bak.$ts"
  else
    settings_backup="$settings.bak.$ts"
  fi
  cp "$settings" "$settings_backup"
  echo "  backup  $settings -> $settings_backup"
}

# Project scope (issue #178): remember that THIS installer created the
# project settings file, so a later --uninstall can remove it again once
# nothing but our own empty residue is left in it. The marker holds a
# fingerprint (cksum) of the file as the install left it, so it is bound to
# that file: a file the user deleted and rewrote, or a new project at the
# same path, never matches. Only a file that did not exist is recorded; a
# reinstall over an existing file keeps the marker only while the file is
# still byte-identical to what the marker was written for, and otherwise
# drops it. Writing the marker is best effort: failing to write it must not
# fail an install whose wiring is already in place.
# The backup directory is keyed by a cksum of the project path, and CRC
# collisions are constructible (two paths, one key). So the install writes the
# project's physical path into a `path` file there, and every marker is
# trusted only when that file names THIS project (#194). project_key_check
# sets project_key_state: own (path matches), foreign (another project's),
# legacy (directory exists without a path file: an install from before this
# check; trusted for the created-file marker it could have written), or none.
project_key_state=""
project_key_warned=0
project_key_check() {
  local f="$project_backup_dir/path"
  if [[ -L "$f" ]]; then
    project_key_state=foreign
  elif [[ -f "$f" ]]; then
    # same_content, not a bare cmp: without cmp on PATH every key used to
    # read as another project's (#208).
    if same_content <(printf '%s\n' "$project_dir") "$f"; then
      project_key_state=own
    else
      project_key_state=foreign
    fi
  elif [[ -d "$project_backup_dir" ]]; then
    project_key_state=legacy
  else
    project_key_state=none
  fi
}
project_key_warn_foreign() {
  (( project_key_warned )) && return 0
  project_key_warned=1
  echo "  WARN    $project_backup_dir is keyed to another project"
  echo "          ($(head -n 1 "$project_backup_dir/path" 2>/dev/null || true)); its markers are left alone and none are"
  echo "          recorded for $project_dir, so --uninstall will leave what this install created."
}
# Install only: make the key directory this project's. 0 = ours, 1 = another
# project's (WARN printed once), 2 = the path file could not be written (the
# caller's own marker write fails the same way and says so).
project_key_claim() {
  project_key_check
  case "$project_key_state" in
    own) return 0 ;;
    foreign) project_key_warn_foreign; return 1 ;;
  esac
  if ( mkdir -p "$project_backup_dir" && printf '%s\n' "$project_dir" > "$project_backup_dir/path" ) 2>/dev/null; then
    project_key_state=own
    return 0
  fi
  return 2
}
# Uninstall only (#212): drop this project's `path` record once nothing it
# guards is left. The record keeps one project's markers from acting on
# another's (two paths can share a cksum key); with no marker in the
# directory and no other settings file of this project still registered,
# it guards nothing. Backups (*.bak.*) and any file of the user's stay: they
# do not depend on it. A record naming another project is never touched.
project_key_release() {
  project_key_check
  [[ "$project_key_state" == own ]] || return 0
  local other
  for other in settings.json settings.local.json; do
    [[ "$other" == "$settings_name" ]] && continue
    registry_has "$project_dir" "$other" && return 0
  done
  [[ -z "$(find "$project_backup_dir" -maxdepth 1 -name '*.created' 2>/dev/null | head -n 1)" ]] || return 0
  rm -f "$project_backup_dir/path" 2>/dev/null || true
  rmdir "$project_backup_dir" 2>/dev/null || true
}
created_marker() { printf '%s\n' "$project_backup_dir/$settings_name.created"; }
settings_fp() {  # <file>: "<cksum> <bytes>" of the file, empty when unreadable
  # -r first: a failed `<` redirect is reported before 2>/dev/null applies
  # and, under pipefail, used to abort the run with a bare "Permission
  # denied" on a mode-000 file (#187).
  [[ -f "$1" && ! -L "$1" && -r "$1" ]] || return 0
  { cksum < "$1"; } 2>/dev/null | awk '{print $1 " " $2}'
}
# Fingerprint of the settings file before this run's patch touches it.
pre_patch_fp=""
record_created_settings() {
  [[ "$scope" == project ]] || return 0
  local m stored krc=0
  m="$(created_marker)"
  project_key_claim || krc=$?
  (( krc == 1 )) && return 0
  if [[ "$settings_seed_state" == absent ]]; then
    if ! ( mkdir -p "$project_backup_dir" && settings_fp "$settings" > "$m" ) 2>/dev/null; then
      echo "  WARN    cannot record the created-file marker in $project_backup_dir;"
      echo "          --uninstall will leave $settings as an empty skeleton"
    fi
    return 0
  fi
  [[ -f "$m" && ! -L "$m" ]] || return 0
  stored="$(cat "$m" 2>/dev/null || true)"
  if [[ -n "$pre_patch_fp" && "$pre_patch_fp" == "$stored" ]]; then
    settings_fp "$settings" > "$m" 2>/dev/null || true
  else
    rm -f "$m" 2>/dev/null || true
  fi
}

# jq test: the file holds nothing but the empty hooks/permissions skeleton
# (exact: $1 = exact) or that skeleton plus nothing (loose, after a strip).
# Returns jq's own status: 0 skeleton, 1 not, 2 or more = jq failed.
settings_is_skeleton() {  # <file> <exact|loose>
  [[ -f "$1" && ! -L "$1" ]] && command -v jq >/dev/null 2>&1 || return 1
  if [[ "$2" == exact ]]; then
    jq -e '. == {"hooks":{},"permissions":{"allow":[]}}' "$1" >/dev/null 2>&1
  else
    jq -e '
      (if (.hooks // {}) == {} then del(.hooks) else . end)
      | (if (.permissions.allow // []) == [] then del(.permissions.allow) else . end)
      | (if (.permissions // {}) == {} then del(.permissions) else . end)
      | . == {}' "$1" >/dev/null 2>&1
  fi
}

# Project-scope --uninstall, step 1 (before the strip): decide whether this
# file is the one the marker was written for: byte-identical to what this
# installer last wrote. Nothing else qualifies (a hand-written skeleton does
# not). Sets created_pre_ok.
created_pre_ok=0
check_created_settings() {
  local m stored cur
  m="$(created_marker)"
  [[ -f "$m" && ! -L "$m" ]] || return 0
  project_key_check
  [[ "$project_key_state" == foreign ]] && return 0
  stored="$(cat "$m" 2>/dev/null || true)"
  cur="$(settings_fp "$settings")"
  if [[ -n "$cur" && "$cur" == "$stored" ]]; then
    created_pre_ok=1
  fi
}

# True when git tracks <file> in whatever repository holds it. Asked from the
# file's own directory (not the project's), so a .claude/ symlinked into a
# dotfiles repo, or a monorepo above the project, is seen too. A symlinked
# file is checked at its resolved target as well.
git_tracks_file() {
  local f="$1" t
  command -v git >/dev/null 2>&1 || return 1
  git -C "${f%/*}" ls-files --error-unmatch -- "${f##*/}" >/dev/null 2>&1 && return 0
  if [[ -L "$f" ]]; then
    # read_link_into and expansion, not $(readlink/dirname/basename), which
    # strip a trailing newline from the target (#226).
    read_link_into "$f" || LINK_TARGET=""
    t="$LINK_TARGET"
    case "$t" in /*) ;; *) t="${f%/*}/$t" ;; esac
    [[ -n "$t" && -d "${t%/*}" ]] \
      && git -C "${t%/*}" ls-files --error-unmatch -- "${t##*/}" >/dev/null 2>&1 && return 0
  fi
  return 1
}

# Step 2 (after the strip): delete the file only when the marker matched, the
# strip left nothing but the empty skeleton, and no git repository tracks it
# (a tracked file would show up as a deletion). The marker is consumed either way.
# A jq failure in the skeleton test is not "not a skeleton": the marker stays
# and uninstall_incomplete is set, so the caller keeps the registry line and
# exits non-zero, and a re-run can finish.
remove_created_settings_if_empty() {
  local m src=0
  m="$(created_marker)"
  [[ -f "$m" && ! -L "$m" ]] || return 0
  project_key_check
  if [[ "$project_key_state" == foreign ]]; then
    project_key_warn_foreign
    return 0
  fi
  if (( created_pre_ok )); then
    settings_is_skeleton "$settings" loose || src=$?
    if (( src > 1 )); then
      echo "  ERROR   jq failed (exit $src) while checking whether $settings is the empty skeleton;"
      echo "          $settings and its created-file marker were left in place."
      # The strip above was ours, so re-bind the marker to the stripped file:
      # a re-run then finds it unchanged and can finish the removal.
      settings_fp "$settings" > "$m" 2>/dev/null || true
      uninstall_incomplete=1
      return 0
    fi
    if (( src == 0 )); then
      if git_tracks_file "$settings"; then
        echo "  keep    $settings (tracked by git; left as the empty skeleton)"
      else
        rm -f "$settings"
        echo "  remove  $settings (this installer created it; nothing else was ever written to it)"
      fi
    fi
  fi
  rm -f "$m"
}

patch_settings() {
  if ! command -v jq >/dev/null 2>&1; then
    echo
    echo "jq not found — can't auto-patch $settings."
    print_manual_snippet
    return
  fi
  pre_patch_fp="$(settings_fp "$settings")"
  ensure_settings_json || return
  if [[ -n "$settings_seed_state" ]]; then
    # Neither scope backs up a file this run just seeded as {}: there is
    # nothing to keep, and cleanup() undoes the seed itself on abort.
    settings_backup=""
    if [[ "$settings_seed_state" == absent ]]; then
      echo "  ok      no backup needed ($settings was just created; an abort undoes that)"
    else
      echo "  ok      no backup needed ($settings was empty; an abort empties it again)"
    fi
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
  record_created_settings
  # If no change vs backup, drop the redundant backup.
  if [[ -n "$settings_backup" ]] && same_content "$settings" "$settings_backup"; then
    rm "$settings_backup"
    echo "  ok      no settings.json changes (backup removed)"
  fi
}

# Set when unpatch_settings (or a step after it) returned without finishing:
# the project-scope uninstall then keeps the markers and the registry line and
# exits non-zero, so a re-run can still clean up.
uninstall_incomplete=0
unpatch_settings() {
  if settings_dir_unsearchable "$settings"; then
    # Hidden, not absent (#213): the hooks may still be wired there. Stop
    # before anything is removed, as for the unreadable file below.
    echo "  ERROR   $settings cannot be read (check its permissions: a directory above it" >&2
    echo "          cannot be searched); refusing to edit (left untouched)." >&2
    echo "          Fix the permissions and re-run the same --uninstall command." >&2
    exit 1
  fi
  if [[ ! -f "$settings" ]]; then
    echo "  ok      $settings does not exist; nothing to strip"
    return
  fi
  if [[ ! -s "$settings" ]]; then
    echo "  ok      $settings is empty; nothing to strip"
    return
  fi
  # jq is needed only from here on: a file that is absent or empty has nothing
  # to strip, so a machine without jq still completes that uninstall.
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
    uninstall_incomplete=1
    return
  fi
  local usable_rc=0
  settings_usable "$settings" || usable_rc=$?
  if [[ $usable_rc -eq 2 ]]; then
    # jq failed before anything is known about the file (#187): not "nothing
    # to strip", which would exit 0 with the hooks still wired. Nothing has
    # been edited yet, so stop here; the bin/ links are still in place for
    # the re-run (settings are unpatched before the links are removed).
    echo "  ERROR   jq failed (exit $settings_usable_rc) while reading $settings; refusing to edit (left untouched)." >&2
    echo "          Fix jq and re-run the same --uninstall command." >&2
    exit 1
  fi
  if [[ $usable_rc -ne 0 ]]; then
    if [[ ! -r "$settings" ]]; then
      # Unknown content, so the hooks may still be wired: stop before the
      # bin/ links go, as for a jq failure (an ERROR followed by exit 0 and
      # removed links would leave every hook dangling).
      echo "  ERROR   $settings cannot be read (check its permissions); refusing to edit (left untouched)." >&2
      echo "          Fix the file and re-run the same --uninstall command." >&2
      exit 1
    elif jq empty "$settings" >/dev/null 2>&1; then
      # Whitespace only, a non-object root, or several documents: there is
      # no hooks object for this installer to have written, so nothing to strip.
      echo "  ok      $settings is empty or not a JSON object; nothing to strip"
    else
      echo "  ERROR   $settings is not valid JSON; refusing to edit (left untouched)."
      uninstall_incomplete=1
    fi
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
  if same_content "$settings" "$settings_backup"; then
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
# In user scope it consults the wiring: when the user file is unwired but
# the project (or, failing that, a registered project) carries our hooks, a
# bare ./install.sh would wire the wrong scope, so it prints that project's
# command instead (the new-machine or teammate-clone case, where a tracked
# project settings.json arrives without the scripts).
rerun_cmd() {
  local proj first rp rn
  if [[ "$scope" == project ]]; then
    if (( use_local )); then
      printf '%s\n' "./install.sh --scope project --project $(shq "$project_dir") --local"
    else
      printf '%s\n' "./install.sh --scope project --project $(shq "$project_dir")"
    fi
    return 0
  fi
  if ! settings_has_our_hooks "$user_settings"; then
    proj="$(wiring_project_root)"
    if settings_has_our_hooks "$proj/.claude/settings.json"; then
      printf '%s\n' "./install.sh --scope project --project $(shq "$proj")"
      return 0
    fi
    if settings_has_our_hooks "$proj/.claude/settings.local.json"; then
      printf '%s\n' "./install.sh --scope project --project $(shq "$proj") --local"
      return 0
    fi
    registry_collect wired
    first="${REGISTRY_OUT%%$'\n'*}"
    if [[ -n "$first" ]]; then
      rp="${first%%$'\t'*}"; rn="${first#*$'\t'}"
      if [[ "$rn" == settings.local.json ]]; then
        printf '%s\n' "./install.sh --scope project --project $(shq "$rp") --local"
      else
        printf '%s\n' "./install.sh --scope project --project $(shq "$rp")"
      fi
      return 0
    fi
  fi
  printf '%s\n' "./install.sh"
}

# The doctor's closing remedy. When the user file is unwired and the only
# wiring is in several registered projects it names one command (any of them
# restores the shared scripts) and lists the projects it repairs (#178, #194).
# Every other case keeps the one-line form.
rerun_remedy() {
  local list plist n rp rn flag proj tab nl line
  list=""
  if [[ "$scope" != project ]] && ! settings_has_our_hooks "$user_settings"; then
    proj="$(wiring_project_root)"
    registry_collect wired
    list="$REGISTRY_OUT"
    # The project the doctor runs in counts even when it is not registered.
    tab=$'\t'; nl=$'\n'
    for rn in settings.json settings.local.json; do
      line="$proj$tab$rn"
      if settings_has_our_hooks "$proj/.claude/$rn"; then
        if ! printf '%s\n' "$list" | grep -Fxq -- "$line"; then
          if [[ -n "$list" ]]; then list="$line$nl$list"; else list="$line"; fi
        fi
      fi
    done
  fi
  # One entry per project path: a project wired in both settings.json and
  # settings.local.json is still one project to repair.
  plist=""
  if [[ -n "$list" ]]; then
    plist="$(printf '%s\n' "$list" | awk -F'\t' '!seen[$1]++')"
  fi
  n=0
  if [[ -n "$plist" ]]; then n="$(printf '%s\n' "$plist" | wc -l | tr -d ' ')"; fi
  if (( n > 1 )); then
    # The scripts are shared under $claude_home/bin, so one re-run restores
    # them for every wired project: print one command, then list all n
    # projects (the first one is the one in the command) (#194).
    IFS=$'\t' read -r rp rn <<< "$(printf '%s\n' "$plist" | head -n 1)"
    flag=""; [[ "$rn" == settings.local.json ]] && flag=" --local"
    echo "        Re-run ./install.sh --scope project --project $(shq "$rp")$flag from a persistent clone (not a /tmp checkout)."
    echo "        The scripts are shared by every wired project, so that one run repairs all $n:"
    while IFS=$'\t' read -r rp rn; do
      [[ -n "$rp" ]] || continue
      echo "          $rp"
    done <<< "$plist"
  else
    echo "        Re-run $(rerun_cmd) from a persistent clone (not a /tmp checkout)."
  fi
}

# other_project_settings: leave in OTHER_SETTINGS / OTHER_SETTINGS_NAME the
# project settings file the flags did NOT name (settings.json under --local,
# settings.local.json without it). One definition for the doctor's switch
# (#190) and the uninstall refusal below (#209), so both look at the same file.
OTHER_SETTINGS=""; OTHER_SETTINGS_NAME=""
other_project_settings() {
  if (( use_local )); then
    OTHER_SETTINGS_NAME="settings.json"
  else
    OTHER_SETTINGS_NAME="settings.local.json"
  fi
  OTHER_SETTINGS="$project_dir/.claude/$OTHER_SETTINGS_NAME"
}

# The doctor's "statusLine unset" line. In user scope, when the user file
# carries no hooks and rerun_cmd points at a project install (the hooks are
# wired in a project file), re-running that command never writes the user
# file's statusLine, so the old "re-run <cmd> to wire it" remedy changed
# nothing and the next doctor run said the same (#209). Name the file that
# was read instead and point at the doctor that checks the wired file.
sl_unset_line() {
  local cmd
  cmd="$(rerun_cmd)"
  if [[ "$scope" != project && "$cmd" != "./install.sh" ]]; then
    echo "  info    statusLine unset in $settings (the user file). The hooks are"
    echo "          wired in project scope, which writes its statusLine to the project"
    echo "          file instead; to check that one run: ./install.sh --doctor ${cmd#./install.sh }"
  else
    echo "  info    statusLine unset (re-run $cmd to wire it)"
  fi
}

# Project-scope --uninstall whose flags name the project file that holds
# nothing of this installer's while the other project file carries the hooks
# (a --local install uninstalled without --local, or the reverse). Unpatching
# the named file printed "nothing to strip" and exited 0 with the hooks still
# wired (#209). In that case it refuses (exit 2, nothing changed) and prints
# the command for the wired file rather than switching to it: an uninstall
# edits a file the user may also edit by hand, so it edits only the file the
# user named. Detection of the wired file is the doctor's (#190,
# settings_has_our_hooks).
# "Nothing of this installer's" means nothing the uninstall would clean up:
# no matching hook (the legacy SessionStart form included), no statusLine or
# permission of ours, no registry line, no created-file marker, no model-pin
# record for the named file. When any of those is left (hooks deleted by
# hand, or the file deleted with its registry line and marker kept), the
# normal strip runs and other_wired_note names the other file at the end, so
# the doctor's stale-registry remedy still works. A named file that is
# unreadable, not valid JSON, or hits a jq failure is left to
# unpatch_settings, which refuses it as before. When the other file's wiring
# cannot be read (mode 000, a jq failure) and the named file holds nothing,
# it stops with exit 1 instead of "nothing to strip".
# shellcheck disable=SC2016  # jq variables, bound by --arg
probe_any_ours='
  [(.hooks? | objects | .[]?) // empty | .. | objects | .command? | strings] as $c
  | [$ss, $ssl, $se, $post, $wr, $st, $up] as $ms
  | [$p1, $p2, $p3, $p4, $p5, $p6, $p7] as $ps
  | (((.permissions? | objects | .allow?) // []) | if type == "array" then . else [] end) as $al
  | any($c[]; . as $x | any($ms[]; . as $m | $x | contains($m)))
    or (((.statusLine? | objects | .command?) // "") | type == "string" and contains($sl))
    or any($al[]; . as $a | any($ps[]; . == $a))'
other_wired_note=""
refuse_uninstall_if_other_file_wired() {
  local named="$settings" shown="$project_dir/.claude/$settings_name" why rc=0 flag cmd
  local leftovers=0 other_state
  # A named file hidden by an unsearchable directory is not "does not exist":
  # unpatch_settings refuses it (#213).
  settings_dir_unsearchable "$named" && return 0
  if [[ -L "$shown" && ! -e "$shown" ]]; then
    why="is a dangling symlink"
  elif [[ ! -e "$named" ]]; then
    why="does not exist"
  elif [[ ! -f "$named" ]]; then
    why="is not a regular file"
  elif [[ ! -s "$named" ]]; then
    why="is empty"
  else
    [[ -r "$named" ]] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    settings_usable "$named" || rc=$?
    if (( rc == 1 )); then
      jq empty "$named" >/dev/null 2>&1 || return 0   # invalid JSON: unpatch_settings refuses it
      why="is empty or not a JSON object"
    elif (( rc != 0 )); then
      return 0
    else
      rc=0
      jq -e --arg ss "$ss_marker" --arg ssl "$ss_legacy_marker" --arg se "$se_marker" \
        --arg post "$post_marker" --arg wr "$wr_marker" --arg st "$st_marker" --arg up "$up_marker" \
        --arg sl "$sl_marker" --arg p1 "$perm_write" --arg p2 "$perm_stop" --arg p3 "$perm_ctx" \
        --arg p4 "$perm_ss" --arg p5 "$perm_sl" --arg p6 "$perm_reset" --arg p7 "$perm_wr" \
        "$probe_any_ours" "$named" >/dev/null 2>&1 || rc=$?
      (( rc <= 1 )) || return 0   # jq failure: unpatch_settings reports it
      (( rc == 0 )) && leftovers=1
      why="carries no handoff hooks"
    fi
  fi
  if registry_has "$project_dir" "$settings_name" || [[ -e "$(created_marker)" || -f "$model_pin_record" ]]; then
    leftovers=1
  fi
  other_project_settings
  # settings.json linked to settings.local.json (or the reverse) is one file:
  # the strip below goes through the link, so the other name is no longer
  # wired afterwards. The note used to be computed here, before the strip,
  # and said the other file "still carries the handoff hooks" (#226).
  local named_phys
  settings_phys_into "$named"; named_phys="$SETTINGS_PHYS"
  settings_phys_into "$OTHER_SETTINGS"
  [[ -n "$named_phys" && "$named_phys" == "$SETTINGS_PHYS" ]] && return 0
  sh_jq_failed_file=""
  if settings_has_our_hooks "$OTHER_SETTINGS"; then
    other_state=wired
  elif [[ "$sh_jq_failed_file" == "$OTHER_SETTINGS" ]]; then
    other_state=unknown
  elif settings_invalid_json "$OTHER_SETTINGS"; then
    # Its wiring cannot be read, like a mode-000 file: unknown, not "not
    # wired" (#226). It used to be "nothing to strip", exit 0, no WARN.
    sh_warn_once "$OTHER_SETTINGS" "not valid JSON" "  WARN    $OTHER_SETTINGS is not valid JSON;" \
      "          treating its wiring as unknown. Fix the file and re-run."
    other_state=unknown
  else
    return 0
  fi
  if [[ "$OTHER_SETTINGS_NAME" == settings.local.json ]]; then flag=" --local"; else flag=""; fi
  cmd="./install.sh --uninstall --scope project --project $(shq "$project_dir")$flag"
  if (( leftovers )); then
    # Strip what is left of the named file's install as usual; say at the end
    # that the other file is still wired and how to remove it.
    if [[ "$other_state" == wired ]]; then
      other_wired_note="note: $OTHER_SETTINGS still carries the handoff hooks (this uninstall
      stripped $settings_name only). To remove them from $OTHER_SETTINGS_NAME too run:
        $cmd"
    fi
    return 0
  fi
  if [[ "$other_state" == unknown ]]; then
    echo "  ERROR   $shown $why, and whether $OTHER_SETTINGS" >&2
    echo "          carries the handoff hooks is unknown (see the WARN above). Nothing was changed." >&2
    echo "          Fix that file and re-run; if it is the wired one, the command for it is:" >&2
    echo "            $cmd" >&2
    exit 1
  fi
  echo "  ERROR   $shown $why;" >&2
  echo "          $OTHER_SETTINGS carries the handoff hooks." >&2
  echo "          Nothing was changed. To remove them from $OTHER_SETTINGS_NAME run:" >&2
  echo "            $cmd" >&2
  exit 2
}

# Single-quote a path for a printed, copy-pasteable command (a project path
# with a space must survive the paste). Embedded single quotes become '\''.
shq() {
  local q
  q="$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
  printf "'%s'" "$q"
}

# settings_usable <file>: 0 when <file> holds exactly one JSON document and
# that document is an object; 1 when it does not (0 bytes, whitespace only,
# invalid JSON, a non-object root such as [] 42 "x" null, two documents, a
# file this process cannot read); 2 when jq itself failed, so nothing is
# known about the file (settings_usable_rc then holds jq's exit code). Every
# outcome is an answer, so callers never read an unusable file as a jq
# failure, and never read a jq failure as an unusable file (#187). The
# filter cannot fail on the file's content: the file is read raw (-R -s, one
# string, so 0 bytes and whitespace are strings too, never "no valid
# result") and parsed inside try/catch, so a parse error is the answer
# `false` (exit 1), not an exit 2 that would look like a jq usage or system
# error. With content ruled out as a cause, any exit above 1 is jq's own
# failure, with no second probe needed to guess whose fault it was. The
# readability check runs first in bash so a mode-000 file is a plain "not
# usable" its callers can name, not a jq failure. Shared by
# settings_has_our_hooks, unpatch_settings and the doctor's settings gate.
# settings_invalid_json <file>: 0 when <file> is non-empty, readable and not
# valid JSON, the one unusable state whose wiring is unknown rather than a
# plain "no": the user may well fix it back into a wired file. Needs jq; 1
# without it. Shared by the registry scan (#208) and the wrong-file uninstall
# check (#226).
settings_invalid_json() {
  local urc=0
  [[ -s "$1" && -r "$1" ]] && command -v jq >/dev/null 2>&1 || return 1
  settings_usable "$1" || urc=$?
  [[ $urc -eq 1 ]] && ! jq empty "$1" >/dev/null 2>&1
}
settings_usable_rc=0
settings_usable() {
  local rc=0
  settings_usable_rc=0
  [[ -r "$1" ]] || return 1
  jq -Rse 'try (fromjson | type == "object") catch false' "$1" >/dev/null 2>&1 || rc=$?
  if [[ $rc -le 1 ]]; then return "$rc"; fi
  settings_usable_rc=$rc
  return 2
}

# settings_has_our_hooks <file>: 0 when <file> exists, parses, and wires at
# least one of this installer's hook commands (the markers the patcher
# writes). 1 otherwise, including when jq is missing.
# Set to 1 by settings_has_our_hooks (and doctor's own reads) on a jq failure;
# sh_jq_failed_file names the last file settings_has_our_hooks could not read.
# wired() is total like probe_hook: every level is guarded (`objects`,
# `strings`, `// empty`), so a string, number, boolean, null or array at
# .hooks, .hooks.<event> or deeper is a plain "no", never a jq error that
# would read as a jq failure (tests/test_install_jq_probes_187.sh, matrix).
sh_jq_failed=0
sh_jq_failed_file=""
# settings_dir_unsearchable <file>: 0 when <file> is hidden by a directory
# this process cannot search. `-f`, `-e` and `-r` are all false for a file
# under such a directory, exactly as for an absent one, so every "does not
# exist" branch must ask this first (#213). Walks up to the nearest ancestor
# that can be stat'ed: when the project directory, or any directory above it,
# cannot be searched, everything below it is hidden and the first stat-able
# one is the unsearchable one. Parameter expansion, not `$(dirname ...)`,
# which would strip a trailing newline from a component (#210).
settings_dir_unsearchable() {
  local d="$1"
  case "$d" in */*) d="${d%/*}" ;; *) d=. ;; esac
  [[ -n "$d" ]] || d=/
  while [[ ! -e "$d" && "$d" != / && "$d" != . ]]; do
    case "$d" in */*) d="${d%/*}" ;; *) d=. ;; esac
    [[ -n "$d" ]] || d=/
  done
  [[ -d "$d" && ! -x "$d" ]]
}
sh_jq_failed_why=""   # "jq failed" or "permission denied": what the WARN said
# sh_warn_once <file> <why> <line1> <line2>: print the two-line WARN to
# stderr unless this run already printed it for <file> with the same <why>
# (#214): one unreadable file is read by several checks (the doctor's
# pre-check, the wired-files listing) and must not be reported by each.
# sh_jq_failed is set by the callers either way, so the exit code is
# unchanged. Must run in the caller's shell, not a command substitution.
sh_warned=""
sh_warn_once() {
  local key="$2|$1"$'\n'
  case "$sh_warned" in *"$key"*) return 0 ;; esac
  sh_warned="$sh_warned$key"
  echo "$3" >&2
  echo "$4" >&2
}
settings_has_our_hooks() {
  local f="$1" rc=0
  command -v jq >/dev/null 2>&1 || return 1
  # A directory this process cannot search hides the file: `-f` is false for
  # it exactly as for an absent file. Unknown, not "does not exist" (#213);
  # same report as the unreadable file below.
  if settings_dir_unsearchable "$f"; then
    sh_warn_once "$f" "permission denied" "  WARN    $f cannot be read (check its permissions);" \
      "          treating its wiring as unknown. Fix the file and re-run."
    sh_jq_failed=1
    sh_jq_failed_file="$f"
    sh_jq_failed_why="permission denied"
    return 1
  fi
  [[ -f "$f" ]] || return 1
  # A file this process cannot read is unknown, not "not wired": this is the
  # read the user-scope --uninstall registry scan relies on before it deletes
  # the shared secret, and a mode-000 project file may well still be wired.
  # Reported through sh_jq_failed like a jq failure, so every caller that
  # acts on "not wired" stops the same way (the WARN names the real cause).
  if [[ ! -r "$f" ]]; then
    sh_warn_once "$f" "permission denied" "  WARN    $f cannot be read (check its permissions);" \
      "          treating its wiring as unknown. Fix the file and re-run."
    sh_jq_failed=1
    sh_jq_failed_file="$f"
    sh_jq_failed_why="permission denied"
    return 1
  fi
  # An unusable file (empty, unparseable, not an object) is a real "no"
  # (settings_usable), not a jq failure. jq failing inside that check (2) is
  # one, reported like a failure of the wiring read below, for the same
  # reason: "unknown" must never collapse into "not wired".
  settings_usable "$f" || rc=$?
  if [[ $rc -eq 2 ]]; then
    sh_warn_once "$f" "jq failed" "  WARN    jq failed (exit $settings_usable_rc) while checking whether $f is a JSON object;" \
      "          treating its wiring as unknown. Fix jq and re-run."
    sh_jq_failed=1
    sh_jq_failed_file="$f"
    sh_jq_failed_why="jq failed"
    return 1
  fi
  [[ $rc -eq 0 ]] || return 1
  # shellcheck disable=SC2016  # jq variables, bound by --arg
  jq -e --arg ss "$ss_marker" --arg se "$se_marker" --arg post "$post_marker" \
        --arg wr "$wr_marker" --arg st "$st_marker" --arg up "$up_marker" '
      def wired($k; $m): [(.hooks? | objects | .[$k]?) // empty | ..
        | objects | .command? | strings | select(contains($m))] | length > 0;
      type == "object" and (
        wired("SessionStart"; $ss) or wired("SessionEnd"; $se)
        or wired("PreCompact"; $se) or wired("PostCompact"; $post)
        or wired("WorktreeRemove"; $wr) or wired("Stop"; $st)
        or wired("UserPromptSubmit"; $up) )
    ' "$f" >/dev/null 2>&1 || rc=$?
  if [[ $rc -gt 1 ]]; then
    # A jq failure on parseable JSON is not "not wired" (#187). The callers
    # take 0/1, so say it loudly here and record it: doctor exits non-zero,
    # install aborts before registering.
    sh_warn_once "$f" "jq failed" "  WARN    jq failed (exit $rc) while checking whether $f wires handoff hooks;" \
      "          treating it as unknown. Fix jq and re-run."
    sh_jq_failed=1
    sh_jq_failed_file="$f"
    sh_jq_failed_why="jq failed"
    return 1
  fi
  return "$rc"
}

# Physical path of a settings file (symlinks resolved, directory made
# physical), so the wiring check below never counts one file twice: a
# project rooted at $HOME, or a dotfiles link, can make two spellings name
# the same file. Sets SETTINGS_PHYS, empty when the directory does not
# exist. A variable, not stdout: `$(...)` stripped a trailing newline from
# the target, so a link to `x<LF>` and the file `x` read as one file (#226).
SETTINGS_PHYS=""
settings_phys_into() {  # <file>; sets SETTINGS_PHYS
  local f d
  SETTINGS_PHYS=""
  resolve_symlink_into "$1"
  f="$RESOLVED"
  case "$f" in */*) d="${f%/*}" ;; *) d=. ;; esac
  [[ -n "$d" ]] || d=/
  phys_dir "$d" || return 0
  SETTINGS_PHYS="${PHYS_DIR%/}/${f##*/}"
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
  # Physical, like every project path this installer records or prints.
  [[ -n "$top" ]] || top="$(pwd -P)"
  printf '%s\n' "$top"
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
  settings_phys_into "$user_settings"; pu="$SETTINGS_PHYS"
  settings_phys_into "$proj/.claude/settings.json"; ps="$SETTINGS_PHYS"
  settings_phys_into "$proj/.claude/settings.local.json"; pl="$SETTINGS_PHYS"
  if [[ -n "$pu" ]] && settings_has_our_hooks "$pu"; then u=1; fi
  if [[ -n "$ps" && "$ps" != "$pu" ]] && settings_has_our_hooks "$ps"; then sw=1; fi
  if [[ -n "$pl" && "$pl" != "$pu" && "$pl" != "$ps" ]] && settings_has_our_hooks "$pl"; then lw=1; fi
  if (( u )) && { [[ "$scope" == project ]] || (( sw || lw )); }; then user_issue=1; fi
  if (( sw && lw )); then dup_issue=1; fi
  if [[ "$label" == NOTE ]]; then p1="NOTE: "; pc="      "; else p1="  WARN    "; pc="          "; fi
  if (( ! user_issue && ! dup_issue )); then
    # A clean layout. The install-time note stays quiet; --doctor still says
    # which file carries the hooks (#190), so a --local install is not left
    # looking like the settings.json it checked first.
    [[ "$label" == WARN ]] && (( u + sw + lw )) || return 0
    p1="  ok      "
  fi
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
    if (( sw )); then echo "${pc}  ./install.sh --scope project --project $(shq "$proj")"; fi
    if (( lw )); then echo "${pc}  ./install.sh --scope project --project $(shq "$proj") --local"; fi
    if (( ! sw && ! lw )); then echo "${pc}  $(rerun_cmd)"; fi
  fi
  if (( dup_issue )); then
    echo "${pc}Both project files carry the hooks. Claude Code runs them once, so this"
    echo "${pc}is redundant rather than broken; keep one. To remove the extra one run:"
    if [[ "$scope" == project ]] && (( use_local )); then
      echo "${pc}  ./install.sh --uninstall --scope project --project $(shq "$proj")"
    else
      echo "${pc}  ./install.sh --uninstall --scope project --project $(shq "$proj") --local"
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

registry_has() {  # <project dir> <settings file name>: 0 when that line is registered
  [[ -f "$project_registry" && ! -L "$project_registry" ]] || return 1
  grep -Fxq -- "$1"$'\t'"$2" "$project_registry"
}

registry_has_dir() {  # <project dir>: 0 when any line registers that directory
  [[ -f "$project_registry" && ! -L "$project_registry" ]] || return 1
  D="$1" awk -F'\t' '$1 == ENVIRON["D"] { found = 1 } END { exit !found }' "$project_registry"
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

# registry_collect <wired|stale>: leave in REGISTRY_OUT one "<dir><TAB><name>"
# line per registered project whose file does (wired) or does not (stale)
# carry our hooks. Callers run it in their own shell, never in a command
# substitution, so a jq failure it hits stays visible in sh_jq_failed (the
# doctor then exits non-zero); a caller that acts on the result (user-scope
# --uninstall deleting the shared secret) must check that. A file whose
# wiring read failed (jq failed, or the file cannot be read) is neither
# wired nor stale: it is left out of both lists, so the doctor never offers
# a removal command for a project it just called unknown. An empty or
# non-object file is a plain stale entry (settings_usable), not a failure.
REGISTRY_OUT=""
# Opt-in (#208): the user-scope --uninstall sets it, because it deletes the
# shared secret on the strength of this scan. With it set, a non-empty file
# that is not valid JSON counts as unknown (sh_jq_failed, like a jq failure),
# not stale: its wiring cannot be read, and it may well still be wired once
# the user fixes it. Left 0 for the doctor, which reports such a file stale.
registry_unparseable_unknown=0
registry_collect() {
  local want="$1" rp rn has nl=$'\n' before failed=0 uf
  REGISTRY_OUT=""
  [[ -f "$project_registry" && ! -L "$project_registry" ]] || return 0
  # The flag is cleared per entry and folded back after the loop, so a
  # second failing file after a first one is skipped too (a snapshot taken
  # once would read as "already failed" for every later entry).
  before=$sh_jq_failed
  while IFS=$'\t' read -r rp rn || [[ -n "$rp" ]]; do
    [[ -n "$rp" ]] || continue
    case "$rn" in settings.json|settings.local.json) ;; *) continue ;; esac
    has=stale
    sh_jq_failed=0
    if settings_has_our_hooks "$rp/.claude/$rn"; then has=wired; fi
    uf="$rp/.claude/$rn"
    if (( registry_unparseable_unknown && ! sh_jq_failed )) && settings_invalid_json "$uf"; then
      echo "  WARN    $uf is not valid JSON;" >&2
      echo "          treating its wiring as unknown. Fix the file and re-run." >&2
      sh_jq_failed=1
      sh_jq_failed_file="$uf"
      sh_jq_failed_why="not valid JSON"
    fi
    if (( sh_jq_failed )); then failed=1; continue; fi
    if [[ "$has" == "$want" ]]; then
      REGISTRY_OUT="${REGISTRY_OUT:+$REGISTRY_OUT$nl}$rp"$'\t'"$rn"
    fi
  done < "$project_registry"
  sh_jq_failed=$(( before || failed ))
  return 0
}

# registry_list_cmds <list>: one indented line per "<dir><TAB><name>" entry,
# the entry itself and the copy-pasteable project uninstall for it.
registry_list_cmds() {
  local rp rn flag
  while IFS=$'\t' read -r rp rn; do
    [[ -n "$rp" ]] || continue
    flag=""; [[ "$rn" == settings.local.json ]] && flag=" --local"
    echo "            $rp ($rn)"
    echo "              ./install.sh --uninstall --scope project --project $(shq "$rp")$flag"
  done <<< "$1"
}

# User-scope --uninstall: warn about every registered project still wired,
# since their hooks call the scripts this uninstall removes. <secret_note>
# says what happened to the shared HMAC secret.
report_registry_orphans() {
  local list="$1" secret_note="$2"
  [[ -n "$list" ]] || return 0
  echo "  WARN    project-scope installs still wired (from $project_registry):"
  registry_list_cmds "$list"
  echo "          Their hooks call the scripts this uninstall removes from"
  echo "          $claude_home/bin, so they will silently no-op until each project is"
  echo "          re-wired with ./install.sh --scope project --project <dir>, or"
  echo "          uninstalled with the command listed under it."
  echo "          $secret_note"
}

# User-scope doctor: name registered projects whose file no longer carries
# our hooks. Informational only.
report_registry_stale() {
  local list
  registry_collect stale
  list="$REGISTRY_OUT"
  [[ -n "$list" ]] || return 0
  echo "  note    stale project registry entries (the file no longer carries this"
  echo "          installer's hooks), from $project_registry; clear each with the"
  echo "          command under it (works for a directory that is gone, too):"
  registry_list_cmds "$list"
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
                 | .scope? // empty' "$reg" 2>/dev/null | sort -u | tr '\n' '|' | sed 's/|$//' || true)"
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
  local broken=0 dst tgt name mdl mdl_rc sl_rc secret smode sign_reason other hint parse_rc why usable_pre
  local flag_settings="" proj f pf pu ps sib_rc sib_check

  if [[ "$scope" == project ]]; then
    echo "doctor: project scope, checking $settings"
    sh_jq_failed_file=""   # set by the read below when it cannot know the answer
    if ! settings_has_our_hooks "$settings"; then
      # settings_has_our_hooks answers 1 for "no hooks" and for a file it
      # cannot use alike. Tell them apart before concluding the flag-named
      # file is merely unwired (#190), with the same total check as every
      # other read (settings_usable, #187):
      # - unknown (unreadable, or jq failed in any of its reads): already
      #   reported there (WARN, sh_jq_failed, non-zero exit), so only the
      #   note below names the cause; never "carries no handoff hooks";
      # - unusable (invalid JSON, empty, not an object, several documents):
      #   named and counted here only when the doctor switches away from it
      #   below; otherwise the statusLine check names it as BROKEN and counts
      #   it, so it is counted exactly once either way.
      parse_rc=0; usable_pre=0; why="carries no handoff hooks"
      if [[ -e "$settings" && ! -f "$settings" ]]; then
        # A directory (or other non-regular file) at the settings path is
        # not "absent" (#216): Claude Code cannot read settings from it, so
        # it is a fault, counted here once, switch or no switch.
        why="is not a regular file"
        echo "  BROKEN  $settings is not a regular file (a directory or special file);"
        echo "          Claude Code cannot read settings from it. Remove it and re-run the installer."
        broken=$((broken + 1))
      elif [[ ! -f "$settings" ]]; then
        why="does not exist"
      elif [[ "$sh_jq_failed_file" == "$settings" ]]; then
        if [[ "$sh_jq_failed_why" == "permission denied" ]]; then
          why="cannot be read"
        else
          why="could not be checked (jq failed)"
        fi
      elif command -v jq >/dev/null 2>&1; then
        settings_usable "$settings" || usable_pre=$?
        if (( usable_pre == 1 )); then
          jq empty "$settings" >/dev/null 2>&1 || parse_rc=$?
          if (( parse_rc )); then why="could not be parsed"; else why="is empty or not a JSON object"; fi
        fi
      fi
      # The other project file may be the one that carries the wiring (a
      # --local install checked without --local, or the reverse): say so
      # instead of leaving the line above as the only file named (#190).
      other_project_settings
      other="$OTHER_SETTINGS"; hint="$OTHER_SETTINGS_NAME"
      if settings_has_our_hooks "$other"; then
        # Switch to the detected file BEFORE the statusLine, model and remedy
        # checks run, so they read it and rerun_cmd carries --local exactly
        # when the wired file is settings.local.json (D1/D2 of the #190 review).
        if (( parse_rc )); then
          echo "  WARN    $settings could not be parsed (jq exit $parse_rc)"
          broken=$((broken + 1))
        elif (( usable_pre == 1 )); then
          echo "  WARN    $settings is empty or not a JSON object"
          broken=$((broken + 1))
        fi
        echo "  note    $settings $why; $other carries the handoff hooks,"
        echo "          so this doctor run checks $hint instead (the flag named the other file)."
        flag_settings="$settings"
        settings="$other"; settings_name="$hint"
        if [[ "$hint" == settings.local.json ]]; then use_local=1; else use_local=0; fi
      fi
    fi
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
        read_link_into "$dst" || LINK_TARGET=""
        echo "  ok      $dst -> $(shown_path "$LINK_TARGET")"
      else
        echo "  ok      $dst (copy)"
      fi
    elif [[ -L "$dst" ]]; then
      read_link_into "$dst" || LINK_TARGET=""
      tgt="$(shown_path "$LINK_TARGET")"
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
  local usable_rc=0
  if command -v jq >/dev/null 2>&1 && [[ -f "$settings" ]]; then
    settings_usable "$settings" || usable_rc=$?
  fi
  if command -v jq >/dev/null 2>&1 && [[ ! -f "$settings" ]]; then
    sl_unset_line
    echo
  elif command -v jq >/dev/null 2>&1 && [[ -f "$settings" ]] && [[ $usable_rc -eq 2 ]]; then
    # jq failed in the usability check itself (#187): nothing is known about
    # the file, which is a jq failure (WARN, exit non-zero below), not a
    # BROKEN file (re-running the installer cannot fix jq).
    echo "  WARN    jq failed (exit $settings_usable_rc) while reading $settings;"
    echo "          its state is unknown. Fix jq and re-run ./install.sh --doctor."
    sh_jq_failed=1
    echo
  elif command -v jq >/dev/null 2>&1 && [[ -f "$settings" ]] && [[ $usable_rc -ne 0 ]]; then
    # Unusable file: the reads below would only report jq failures, and
    # re-running doctor cannot fix the file, so name it once as broken,
    # saying which of the three it is (settings_usable).
    if [[ ! -r "$settings" ]]; then
      echo "  BROKEN  $settings cannot be read (check its permissions)"
    elif jq empty "$settings" >/dev/null 2>&1; then
      echo "  BROKEN  $settings is empty or not a JSON object"
    else
      echo "  BROKEN  $settings is not valid JSON"
    fi
    broken=$((broken + 1))
    echo
  elif command -v jq >/dev/null 2>&1 && [[ -f "$settings" ]]; then
    # Read-only, so a jq failure (exit 2 or more, #187) is a WARN naming the
    # unknown state rather than an abort, and not counted toward `broken`
    # (re-running the installer cannot fix jq). Never a quiet "user's own".
    sl_rc=0
    jq -e --arg m "$sl_marker" "$probe_sl_ours" "$settings" >/dev/null 2>&1 || sl_rc=$?
    if [[ $sl_rc -eq 0 ]]; then
      echo "  ok      statusLine wired (ours)"
    elif [[ $sl_rc -eq 1 ]]; then
      sl_rc=0
      jq -e "$probe_sl_present" "$settings" >/dev/null 2>&1 || sl_rc=$?
      if [[ $sl_rc -eq 1 ]]; then
        sl_unset_line
      elif [[ $sl_rc -eq 0 ]]; then
        echo "  info    statusLine present (user's own; manual wiring documented in README)"
      fi
    fi
    if [[ $sl_rc -gt 1 ]]; then
      echo "  WARN    jq failed (exit $sl_rc) while probing statusLine in $settings;"
      echo "          its state is unknown. Fix jq and re-run ./install.sh --doctor."
      sh_jq_failed=1
    fi
    # Model context-window check: advisory only, never counts toward broken.
    # Only an id whose window depends on the variant picked is worth a WARN:
    # Opus 4.6 and Sonnet 4.6 run at 200k unless the [1m] variant is chosen,
    # which the bare id does not record. Only these two ids are detected.
    # Opus 4.7 and later default to 1M (bin/handoff_ctx_check.sh's model
    # table), so those ids stay quiet. A bare alias (`opus`, `sonnet`) is not
    # detected: on some providers it resolves to a 4.6 model (Microsoft
    # Foundry for `opus`, the Claude Platform on AWS for `sonnet`), which this
    # check cannot see. Any other value (including absent) is a legitimate
    # choice we stay quiet about.
    mdl=""
    mdl_rc=0
    mdl="$(jq -r "$probe_model_read" "$settings" 2>/dev/null)" || mdl_rc=$?
    if [[ $mdl_rc -ne 0 ]]; then
      mdl=""
      echo "  WARN    jq failed (exit $mdl_rc) while reading model from $settings;"
      echo "          its state is unknown. Fix jq and re-run ./install.sh --doctor."
      sh_jq_failed=1
    fi
    case "$mdl" in
      claude-opus-4-6|claude-sonnet-4-6)
        echo "  WARN    model '$mdl' in $settings_name may run at a 200k context window"
        echo "          (the id does not say which variant is picked); for the 1M window"
        echo "          set \"model\": \"${mdl}[1m]\" (edit $settings_name or run"
        echo "          /model ${mdl}[1m] in a session)."
        ;;
    esac
    echo
  fi
  # A project settings file the checks above did not probe is otherwise
  # never parsed by the doctor: report_wiring's read treats unparseable as
  # "not wired", so a corrupt settings.json beside a --local install (or
  # either project file under a user-scope doctor) was silent (#209). Skipped:
  # the file probed above (the statusLine check names it), the flag-named
  # file the doctor switched away from (named before the switch), and the
  # user file. Counted like the flag-named case (#190 H), so the same files
  # give the same exit code whichever flag the doctor was run with.
  # A user-scope doctor checks only a project with a handoff install (a
  # registry line, or a project file carrying the hooks): run from any other
  # directory, a broken settings file there is not this installer's concern
  # and must not fail the doctor.
  sib_check=0
  if command -v jq >/dev/null 2>&1; then
    proj="$(wiring_project_root)"
    if [[ "$scope" == project ]] || registry_has_dir "$proj" \
       || settings_has_our_hooks "$proj/.claude/settings.json" \
       || settings_has_our_hooks "$proj/.claude/settings.local.json"; then
      sib_check=1
    fi
  fi
  if (( sib_check )); then
    settings_phys_into "$user_settings"; pu="$SETTINGS_PHYS"
    settings_phys_into "$settings"; ps="$SETTINGS_PHYS"
    pfl=""
    if [[ -n "$flag_settings" ]]; then settings_phys_into "$flag_settings"; pfl="$SETTINGS_PHYS"; fi
    for f in "$proj/.claude/settings.json" "$proj/.claude/settings.local.json"; do
      settings_phys_into "$f"; pf="$SETTINGS_PHYS"
      [[ -n "$pf" && "$pf" != "$pu" && "$pf" != "$ps" ]] || continue
      [[ -n "$flag_settings" && "$pf" == "$pfl" ]] && continue
      # Only a parse failure is new here: an unreadable file is already
      # reported by report_wiring's read, and an empty file is not an error.
      [[ -f "$pf" && -r "$pf" && -s "$pf" ]] || continue
      sib_rc=0
      settings_usable "$pf" || sib_rc=$?
      (( sib_rc == 1 )) || continue
      sib_rc=0
      jq empty "$pf" >/dev/null 2>&1 || sib_rc=$?
      (( sib_rc )) || continue
      echo "  WARN    $f could not be parsed (jq exit $sib_rc); whether it carries"
      echo "          handoff hooks is unknown. Fix or remove the file, then re-run this doctor."
      broken=$((broken + 1))
      echo
    done
  fi
  report_wiring WARN
  if [[ "$scope" == user ]]; then
    report_registry_stale
  fi
  report_plugin_leftover "  WARN"
  if (( broken )); then
    echo "doctor: $broken issue(s) found." >&2
    rerun_remedy >&2
    return 1
  fi
  if (( sh_jq_failed )); then
    # Exits non-zero (owner decision, see the PR for #187): a jq failure means
    # some state above is unknown, which a clean exit would hide from CI.
    echo "doctor: ${sh_jq_failed_why:-jq failed} while reading settings (see WARN above); fix it and re-run ./install.sh --doctor." >&2
    return 1
  fi
  echo "doctor: all hooks resolve."
}

