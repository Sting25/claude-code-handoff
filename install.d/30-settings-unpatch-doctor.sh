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
  local m stored
  m="$(created_marker)"
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
  git -C "$(dirname "$f")" ls-files --error-unmatch -- "$(basename "$f")" >/dev/null 2>&1 && return 0
  if [[ -L "$f" ]]; then
    t="$(readlink "$f" 2>/dev/null || true)"
    case "$t" in /*) ;; *) t="$(dirname "$f")/$t" ;; esac
    [[ -n "$t" && -d "$(dirname "$t")" ]] \
      && git -C "$(dirname "$t")" ls-files --error-unmatch -- "$(basename "$t")" >/dev/null 2>&1 && return 0
  fi
  return 1
}

# Step 2 (after the strip): delete the file only when the marker matched, the
# strip left nothing but the empty skeleton, and no git repository tracks it
# (a tracked file would show up as a deletion). The marker is consumed either way.
remove_created_settings_if_empty() {
  local m
  m="$(created_marker)"
  [[ -f "$m" && ! -L "$m" ]] || return 0
  if (( created_pre_ok )) && settings_is_skeleton "$settings" loose; then
    if git_tracks_file "$settings"; then
      echo "  keep    $settings (tracked by git; left as the empty skeleton)"
    else
      rm -f "$settings"
      echo "  remove  $settings (this installer created it; nothing else was ever written to it)"
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
  record_created_settings
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
# wiring is in several registered projects, a single command would leave the
# others broken, so it prints one command per wired project (issue #178).
# Every other case keeps the one-line form.
rerun_remedy() {
  local list n rp rn flag proj tab nl line
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
  n=0
  if [[ -n "$list" ]]; then n="$(printf '%s\n' "$list" | wc -l | tr -d ' ')"; fi
  if (( n > 1 )); then
    echo "        Re-run one command per wired project, from a persistent clone (not a /tmp checkout):"
    while IFS=$'\t' read -r rp rn; do
      [[ -n "$rp" ]] || continue
      flag=""; [[ "$rn" == settings.local.json ]] && flag=" --local"
      echo "          ./install.sh --scope project --project $(shq "$rp")$flag"
    done <<< "$list"
  else
    echo "        Re-run $(rerun_cmd) from a persistent clone (not a /tmp checkout)."
  fi
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
sh_jq_failed_why=""   # "jq failed" or "permission denied": what the WARN said
settings_has_our_hooks() {
  local f="$1" rc=0
  [[ -f "$f" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  # A file this process cannot read is unknown, not "not wired": this is the
  # read the user-scope --uninstall registry scan relies on before it deletes
  # the shared secret, and a mode-000 project file may well still be wired.
  # Reported through sh_jq_failed like a jq failure, so every caller that
  # acts on "not wired" stops the same way (the WARN names the real cause).
  if [[ ! -r "$f" ]]; then
    echo "  WARN    $f cannot be read (check its permissions);" >&2
    echo "          treating its wiring as unknown. Fix the file and re-run." >&2
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
    echo "  WARN    jq failed (exit $settings_usable_rc) while checking whether $f is a JSON object;" >&2
    echo "          treating its wiring as unknown. Fix jq and re-run." >&2
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
    echo "  WARN    jq failed (exit $rc) while checking whether $f wires handoff hooks;" >&2
    echo "          treating it as unknown. Fix jq and re-run." >&2
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
registry_collect() {
  local want="$1" rp rn has nl=$'\n' before
  REGISTRY_OUT=""
  [[ -f "$project_registry" && ! -L "$project_registry" ]] || return 0
  while IFS=$'\t' read -r rp rn || [[ -n "$rp" ]]; do
    [[ -n "$rp" ]] || continue
    case "$rn" in settings.json|settings.local.json) ;; *) continue ;; esac
    has=stale
    before=$sh_jq_failed
    if settings_has_our_hooks "$rp/.claude/$rn"; then has=wired; fi
    if (( sh_jq_failed && ! before )); then continue; fi
    if [[ "$has" == "$want" ]]; then
      REGISTRY_OUT="${REGISTRY_OUT:+$REGISTRY_OUT$nl}$rp"$'\t'"$rn"
    fi
  done < "$project_registry"
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
  local broken=0 dst tgt name mdl mdl_rc sl_rc secret smode sign_reason

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
  local usable_rc=0
  if command -v jq >/dev/null 2>&1 && [[ -f "$settings" ]]; then
    settings_usable "$settings" || usable_rc=$?
  fi
  if command -v jq >/dev/null 2>&1 && [[ ! -f "$settings" ]]; then
    echo "  info    statusLine unset (re-run $(rerun_cmd) to wire it)"
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
        echo "  info    statusLine unset (re-run $(rerun_cmd) to wire it)"
      elif [[ $sl_rc -eq 0 ]]; then
        echo "  info    statusLine present (user's own; manual wiring documented in README)"
      fi
    fi
    if [[ $sl_rc -gt 1 ]]; then
      echo "  WARN    jq failed (exit $sl_rc) while probing statusLine in $settings;"
      echo "          its state is unknown. Fix jq and re-run ./install.sh --doctor."
      sh_jq_failed=1
    fi
    # Model context-window check — advisory only, never counts toward broken:
    # a bare 'opus'/'claude-opus-4-8' pin silently runs at a 200k context
    # window; the 1M variant needs the [1m] suffix. Any other value (including
    # absent) is a legitimate choice we stay quiet about.
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
    rerun_remedy >&2
    return 1
  fi
  if (( sh_jq_failed )); then
    # Exits non-zero (owner decision, see the PR for #187): a jq failure means
    # some state above is unknown, which a clean exit would hide from CI.
    echo "doctor: jq failed while reading settings (see WARN above); fix jq and re-run ./install.sh --doctor." >&2
    return 1
  fi
  echo "doctor: all hooks resolve."
}

