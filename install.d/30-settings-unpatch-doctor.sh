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
    echo "  new     $settings (created with {})"
    return 0
  fi
  if [[ ! -s "$settings" ]]; then
    echo '{}' > "$settings"
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

patch_settings() {
  if ! command -v jq >/dev/null 2>&1; then
    echo
    echo "jq not found — can't auto-patch $settings."
    print_manual_snippet
    return
  fi
  ensure_settings_json || return
  cp "$settings" "$settings.bak.$ts"
  echo "  backup  $settings -> $settings.bak.$ts"
  # Arm restore-on-abort: from here until the sequence completes, any abort
  # rolls settings.json back to this backup (see cleanup() / the EXIT trap).
  settings_backup="$settings.bak.$ts"
  patch_in_progress=1
  migrate_legacy_ss_hook
  maybe_install_hook SessionStart     "$ss_marker" "$ss_cmd"
  maybe_install_hook SessionEnd       "$se_marker" "$se_cmd"
  # Marker detection is event-scoped, so PreCompact can safely reuse the
  # SessionEnd marker: each event's hook list is checked independently.
  maybe_install_hook PreCompact       "$se_marker" "$pc_cmd"
  maybe_install_hook PostCompact      "$post_marker" "$post_cmd"
  maybe_install_hook Stop             "$st_marker" "$st_cmd"
  maybe_install_hook UserPromptSubmit "$up_marker" "$up_cmd"
  maybe_install_statusline
  maybe_install_perm "$perm_write"
  maybe_install_perm "$perm_stop"
  maybe_install_perm "$perm_ctx"
  maybe_install_perm "$perm_ss"
  maybe_install_perm "$perm_sl"
  maybe_install_perm "$perm_reset"
  maybe_install_model
  patch_in_progress=0   # full sequence succeeded; disarm restore-on-abort
  # If no change vs backup, drop the redundant backup.
  if cmp -s "$settings" "$settings.bak.$ts"; then
    rm "$settings.bak.$ts"
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
  cp "$settings" "$settings.bak.$ts"
  echo "  backup  $settings -> $settings.bak.$ts"
  settings_backup="$settings.bak.$ts"
  patch_in_progress=1
  maybe_uninstall_hook SessionStart     "$ss_marker"
  maybe_uninstall_hook SessionStart     "$ss_legacy_marker"
  maybe_uninstall_hook SessionEnd       "$se_marker"
  maybe_uninstall_hook PreCompact       "$se_marker"
  maybe_uninstall_hook PostCompact      "$post_marker"
  maybe_uninstall_hook Stop             "$st_marker"
  maybe_uninstall_hook UserPromptSubmit "$up_marker"
  maybe_uninstall_statusline
  maybe_uninstall_perm "$perm_write"
  maybe_uninstall_perm "$perm_stop"
  maybe_uninstall_perm "$perm_ctx"
  maybe_uninstall_perm "$perm_ss"
  maybe_uninstall_perm "$perm_sl"
  maybe_uninstall_perm "$perm_reset"
  maybe_uninstall_model
  patch_in_progress=0   # full sequence succeeded; disarm restore-on-abort
  if cmp -s "$settings" "$settings.bak.$ts"; then
    rm "$settings.bak.$ts"
    echo "  ok      no settings.json changes (backup removed)"
  fi
}

# Locate an installed plugin form of this tool (v0.14.0+ ships one), if any.
# Plugin installs live under $CLAUDE_CONFIG_DIR/plugins/cache/<marketplace>/
# claude-code-handoff/<version>/, falling back to $HOME/.claude when
# CLAUDE_CONFIG_DIR is unset — that's Claude Code's OWN env var for where it
# keeps its config/cache, unrelated to this installer's CLAUDE_HOME
# convention. NOTE: this is never under a CLAUDE_HOME override — the plugin
# loader has no concept of this installer's CLAUDE_HOME convention, only of
# Claude Code's own CLAUDE_CONFIG_DIR. Bash 3.2 has no nullglob, so a
# non-matching glob expands to its own literal (unexpanded) pattern text; the
# `-d` test below simply never passes for that literal string, which is what
# makes this safe without nullglob or an array/compgen dependency. Echoes the
# first matching directory on stdout and returns 0, or returns 1 if none.
find_plugin_cache_dir() {
  local pd
  for pd in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/plugins/cache/*/claude-code-handoff; do
    if [[ -d "$pd" ]]; then
      printf '%s\n' "$pd"
      return 0
    fi
  done
  return 1
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

# Self-check: verify each installed hook script under $claude_home/bin actually
# resolves. A dangling symlink (e.g. installed from a temp checkout that was
# later cleaned up) makes the corresponding hook no-op silently, so surface it
# loudly here. Exit non-zero if anything is broken so CI / a wrapper can detect
# it. (issue #21)
doctor() {
  local broken=0 dst tgt name mdl secret smode plugin_dir script_hooks_present sign_reason
  echo "doctor: checking installed handoff hooks under $claude_home/bin"
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
  for name in write_handoff handoff_turn_append handoff_ctx_check handoff_session_start handoff_recover_tail handoff_statusline handoff_compact_reset handoff_provenance; do
    dst="$claude_home/bin/$name.sh"
    if [[ -e "$dst" ]]; then
      if [[ -L "$dst" ]]; then
        echo "  ok      $dst -> $(readlink "$dst")"
      else
        echo "  ok      $dst (copy)"
      fi
    elif [[ -L "$dst" ]]; then
      tgt="$(readlink "$dst" 2>/dev/null || true)"
      echo "  BROKEN  $dst -> $tgt (dangling symlink — hook is silently disabled)"
      broken=$((broken + 1))
    else
      echo "  MISSING $dst (not installed)"
      broken=$((broken + 1))
    fi
  done
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
  if command -v jq >/dev/null 2>&1 && [[ -f "$settings" ]]; then
    if jq -e --arg m "$sl_marker" '(.statusLine.command // "") | contains($m)' \
         "$settings" >/dev/null 2>&1; then
      echo "  ok      statusLine wired (ours)"
    elif jq -e '(.statusLine // null) != null' "$settings" >/dev/null 2>&1; then
      echo "  info    statusLine present (user's own — manual wiring documented in README)"
    else
      echo "  info    statusLine unset (re-run ./install.sh to wire it)"
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
  # Plugin/script coexistence (v0.14.0+ ships a plugin form of this tool).
  # Plugin hooks and these script-install hooks COEXIST — Claude Code fires
  # both, no dedup — so a machine with both installed double-fires every
  # hook. Advisory only: never counts toward `broken`, same as the model and
  # statusLine checks above, since neither installed form is itself faulty.
  if plugin_dir="$(find_plugin_cache_dir)"; then
    script_hooks_present=0
    if command -v jq >/dev/null 2>&1 && [[ -f "$settings" ]] \
       && jq -e --arg m "$ss_marker" \
            '(.hooks.SessionStart // []) | any(.. | .command? // "" | contains($m))' \
            "$settings" >/dev/null 2>&1; then
      script_hooks_present=1
    fi
    if (( script_hooks_present )); then
      echo "  WARN    plugin install detected ($plugin_dir) AND this installer's"
      echo "          script hooks are wired in $settings — every hook fires TWICE"
      echo "          (Claude Code does not dedupe plugin vs. script hooks). Fix: pick"
      echo "          one mode — either '/plugin uninstall claude-code-handoff' or"
      echo "          './install.sh --uninstall'."
    else
      echo "  info    plugin install detected ($plugin_dir) — this installer's doctor"
      echo "          does not manage plugin installs; nothing to do here."
    fi
    echo
  fi
  if (( broken )); then
    echo "doctor: $broken hook(s) broken or missing." >&2
    echo "        Re-run ./install.sh from a persistent clone (not a /tmp checkout)." >&2
    return 1
  fi
  echo "doctor: all hooks resolve."
}

