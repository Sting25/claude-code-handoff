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
#
# Plugin-mode awareness (issues #64, #70): a plugin-only machine has none of
# this installer's bin/ scripts or settings.json hooks by design (the plugin
# ships its own hooks/hooks.json and runs from its own cache copy), so the
# bare-scripts per-script loop below does not apply there. Reporting those
# eight scripts as MISSING on a healthy plugin-only machine was issue #64: the
# verdict contradicted the diagnosis, and the "re-run ./install.sh" remedy is
# exactly the action that creates a second, parallel bare-scripts install
# alongside the plugin (every hook then fires twice, see the coexistence
# check further down). `plugin_only` below gates both: skip the per-script
# loop and its MISSING lines, and never suggest ./install.sh in the closing
# remedy, when a plugin cache is present and no bare-scripts artifact is.
doctor() {
  local broken=0 dst tgt name mdl secret smode sign_reason
  local plugin_dir bare_wired plugin_only script_hooks_present dangling_list
  local vdir vcount hooks_json missing_scripts events_str expected_events
  local missing_events extra_events ev rest

  # Plugin cache detection lives up front now (used by several sections
  # below), via the `|| true` idiom already used elsewhere in this file so a
  # "not found" result can't trip `set -e` (find_plugin_cache_dir returns 1
  # when there's no cache; that's a normal, expected outcome, not an error).
  plugin_dir="$(find_plugin_cache_dir || true)"

  echo "doctor: checking runtime dependencies"
  # jq is a RUNTIME dependency of the Stop hook (payload parsing), the ctx
  # nudge, and the /handoff-recover tail rescue — a resolving script link is
  # not enough if the tool it needs is missing (they all no-op silently).
  # Mode-neutral: this fires the same way whether the six hooks came from
  # bare-scripts settings.json entries or the plugin's own hooks.json, since
  # both invoke the same scripts under the hood (issue #70's "jq" note).
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

  # bare_wired: is there a REAL bare-scripts install, not just leftover
  # cruft? Either a hook wired into settings.json, or at least one bin/
  # script that actually resolves. `-e` alone (not `-e || -L`) is
  # deliberate: for a symlink it follows the link and requires the target to
  # exist, so a lone DANGLING symlink does not flip this true on its own.
  # Before this fix, any one of the eight paths existing (dangling or not)
  # was enough, so a plugin-only machine with a single stale dangling
  # `write_handoff.sh` left behind by a hand-removed bare install got
  # dragged into the per-script loop below and reported the other seven as
  # MISSING, restoring issue #64's exact bug. Dangling remnants are real and
  # worth naming, so they're collected separately (dangling_list) and
  # reported as one WARN instead of feeding this check.
  bare_wired=0
  for name in write_handoff handoff_turn_append handoff_ctx_check handoff_session_start handoff_recover_tail handoff_statusline handoff_compact_reset handoff_provenance; do
    dst="$claude_home/bin/$name.sh"
    if [[ -e "$dst" ]]; then
      bare_wired=1
      break
    fi
  done
  if (( ! bare_wired )) && command -v jq >/dev/null 2>&1 && [[ -f "$settings" ]]; then
    if jq -e --arg ss "$ss_marker" --arg se "$se_marker" --arg post "$post_marker" \
           --arg st "$st_marker" --arg up "$up_marker" '
         ( (.hooks.SessionStart // [])     | any(.. | .command? // "" | contains($ss)) ) or
         ( (.hooks.SessionEnd // [])       | any(.. | .command? // "" | contains($se)) ) or
         ( (.hooks.PreCompact // [])       | any(.. | .command? // "" | contains($se)) ) or
         ( (.hooks.PostCompact // [])      | any(.. | .command? // "" | contains($post)) ) or
         ( (.hooks.Stop // [])             | any(.. | .command? // "" | contains($st)) ) or
         ( (.hooks.UserPromptSubmit // []) | any(.. | .command? // "" | contains($up)) )
       ' "$settings" >/dev/null 2>&1; then
      bare_wired=1
    fi
  fi

  # Collect any dangling-only leftovers regardless of bare_wired: a symlink
  # whose target is gone is real breakage worth naming even on a healthy
  # plugin-only machine, just not evidence of a wired bare-scripts install.
  dangling_list=""
  for name in write_handoff handoff_turn_append handoff_ctx_check handoff_session_start handoff_recover_tail handoff_statusline handoff_compact_reset handoff_provenance; do
    dst="$claude_home/bin/$name.sh"
    if [[ -L "$dst" && ! -e "$dst" ]]; then
      dangling_list="$dangling_list $dst"
    fi
  done

  plugin_only=0
  if [[ -n "$plugin_dir" ]] && (( ! bare_wired )); then
    plugin_only=1
  fi

  if (( plugin_only )); then
    echo "doctor: no bare-scripts install found under $claude_home/bin, skipping"
    echo "        the per-script hook checks (this installer's own scripts were"
    echo "        never installed here). See the plugin section below."
    if [[ -n "$dangling_list" ]]; then
      echo "  WARN    stale bare-scripts artifact(s) found, but no bare-scripts"
      echo "          install is actually wired:$dangling_list"
      echo "          Dangling symlink(s) left over from a removed install; they"
      echo "          don't affect the plugin. Safe to remove: rm$dangling_list"
    fi
  else
    echo "doctor: checking installed handoff hooks under $claude_home/bin"
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
  fi
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
  # A genuinely plugin-only machine (#64, #70) may never have a settings.json
  # at all, this installer never created one and the plugin doesn't need it
  # for anything BUT statusLine. Report "unset" for that case too instead of
  # silently saying nothing: in plugin mode statusLine is the only accurate
  # context signal there is (docs/plugin-mode-context-watching-report.md),
  # so its absence is worth a line even when there's no file to inspect.
  if command -v jq >/dev/null 2>&1 && [[ ! -f "$settings" ]]; then
    if (( plugin_only )); then
      echo "  info    statusLine unset (optional: a plugin install can't wire it"
      echo "          automatically; paste the manual snippet from"
      echo "          docs/reference.md, Status line section, to enable the"
      echo "          context nudge's most accurate signal in plugin mode)"
    else
      echo "  info    statusLine unset (re-run ./install.sh to wire it)"
    fi
    echo
  elif command -v jq >/dev/null 2>&1 && [[ -f "$settings" ]]; then
    if jq -e --arg m "$sl_marker" '(.statusLine.command // "") | contains($m)' \
         "$settings" >/dev/null 2>&1; then
      echo "  ok      statusLine wired (ours)"
    elif [[ -n "$plugin_dir" ]] && jq -e --arg p "$plugin_dir" '
           (.statusLine.command // "") as $c
           | ($c | contains($p)) and ($c | contains("handoff_statusline.sh"))
         ' "$settings" >/dev/null 2>&1; then
      # Second marker (issue #70): a plugin install can't wire statusLine
      # itself (Claude Code has no per-plugin mechanism for it), so the only
      # way this line matches is a user-pasted command pointing at the
      # plugin's own cached script (README's documented manual snippet).
      # Before this check, that command matched neither this branch nor the
      # bare-scripts marker above, and fell through to "user's own" below.
      echo "  ok      statusLine wired (ours, plugin)"
    elif jq -e '(.statusLine // null) != null' "$settings" >/dev/null 2>&1; then
      echo "  info    statusLine present (user's own — manual wiring documented in README)"
    elif (( plugin_only )); then
      # Plugin-only (#64): never suggest ./install.sh here, that's the
      # dual-mode trap. statusLine is optional in every mode, so this stays
      # an info line, not BROKEN, same as the bare-scripts case below.
      echo "  info    statusLine unset (optional: a plugin install can't wire it"
      echo "          automatically; paste the manual snippet from"
      echo "          docs/reference.md, Status line section, to enable the"
      echo "          context nudge's most accurate signal in plugin mode)"
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
  # Plugin-specific health checks (issue #70). The eight-script loop above
  # only ever looks under $claude_home/bin, this installer's own copy; it has
  # nothing to say about the plugin's own cache copy at $plugin_dir, which
  # has real, checkable failure modes of its own: a partial or stale cache
  # extraction makes every plugin hook a silent no-op, the same class of
  # failure issue #21 fixed for bare-scripts symlinks, just relocated to
  # wherever Claude Code checked the plugin out.
  if [[ -n "$plugin_dir" ]]; then
    echo "doctor: checking plugin cache at $plugin_dir"
    # Cache layout is <plugin_dir>/<version>/{hooks,bin,...}; pick the newest
    # version dir by mtime, same "ls -td | head -1" idiom the README's own
    # manual statusLine snippet uses for the same reason (a cache can hold
    # more than one version, see docs/reference.md's stale-cache note).
    # `|| true` on both substitutions below (same idiom as plugin_dir above):
    # when the glob matches nothing (no version subdirectory at all), `ls`
    # itself exits nonzero even with output suppressed by 2>/dev/null, and
    # under set -e that failure inside a bare assignment aborts doctor
    # entirely, silently, before the "no version subdirectory" BROKEN line a
    # few lines down ever gets a chance to print. `|| true` lets that BROKEN
    # line do its job instead of the whole command dying first.
    # shellcheck disable=SC2012  # ls -t is deliberate: mtime ordering, and BSD find has no -printf (same idiom as bin/handoff_recover_tail.sh's ls -t)
    vdir="$(ls -td "$plugin_dir"/*/ 2>/dev/null | head -1 || true)"
    vdir="${vdir%/}"
    # shellcheck disable=SC2012  # plain dir count, not name-sensitive: any non-empty ls -d line counts as one version regardless of its characters
    vcount="$(ls -d "$plugin_dir"/*/ 2>/dev/null | wc -l | tr -d ' ' || true)"
    if [[ -z "$vdir" || ! -d "$vdir" ]]; then
      echo "  BROKEN  $plugin_dir has no version subdirectory, the plugin cache looks empty or corrupted"
      broken=$((broken + 1))
    else
      if [[ -n "$vcount" ]] && (( vcount > 1 )); then
        echo "  note    $vcount versions cached under $plugin_dir; using the newest by"
        echo "          mtime ($vdir). An older cache touched more recently can shadow"
        echo "          the current version, see docs/reference.md's stale-cache note."
      fi
      hooks_json="$vdir/hooks/hooks.json"
      if [[ ! -f "$hooks_json" ]]; then
        echo "  BROKEN  $hooks_json missing, every plugin hook is silently disabled"
        broken=$((broken + 1))
      elif ! command -v jq >/dev/null 2>&1; then
        echo "  note    $hooks_json present but jq is missing, cannot verify it parses"
      elif ! jq -e . "$hooks_json" >/dev/null 2>&1; then
        echo "  BROKEN  $hooks_json is not valid JSON, every plugin hook is silently disabled"
        broken=$((broken + 1))
      else
        # `.hooks // {}` guards a valid-but-hookless hooks.json (`{}` parses
        # fine but has no "hooks" key, so bare `.hooks` resolves to null, and
        # `keys` on null is a jq runtime error, exit 5, which used to abort
        # doctor entirely under set -e before this BROKEN branch ever ran).
        # `|| true` on the substitution catches that same failure mode for
        # any other malformed shape too, leaving events_str empty so the
        # subset check below reports it as BROKEN (missing all six) instead
        # of taking doctor down with it.
        events_str="$(jq -r '.hooks // {} | keys | sort | join(",")' "$hooks_json" 2>/dev/null || true)"
        expected_events="PostCompact,PreCompact,SessionEnd,SessionStart,Stop,UserPromptSubmit"
        # Subset check, not exact equality: hooks.json only counts as broken
        # if it's missing one of the six events this tool wires. Exact
        # equality used to flag a hooks.json with an EXTRA event (a future
        # Claude Code hook, or a fork's own addition) as "missing" events it
        # never lost, just because the sorted list no longer matched
        # verbatim.
        missing_events=""
        for ev in PostCompact PreCompact SessionEnd SessionStart Stop UserPromptSubmit; do
          case ",$events_str," in
            *",$ev,"*) ;;
            *) missing_events="$missing_events $ev" ;;
          esac
        done
        if [[ -n "$missing_events" ]]; then
          echo "  BROKEN  $hooks_json is missing hook event(s):$missing_events (has [$events_str], need all of [$expected_events])"
          broken=$((broken + 1))
        else
          echo "  ok      $hooks_json has all six hook events"
          extra_events=""
          rest="$events_str"
          while [[ -n "$rest" ]]; do
            ev="${rest%%,*}"
            case "$rest" in
              *,*) rest="${rest#*,}" ;;
              *) rest="" ;;
            esac
            case " $ev " in
              *" PostCompact "*|*" PreCompact "*|*" SessionEnd "*|*" SessionStart "*|*" Stop "*|*" UserPromptSubmit "*) ;;
              *) [[ -n "$ev" ]] && extra_events="$extra_events $ev" ;;
            esac
          done
          if [[ -n "$extra_events" ]]; then
            echo "  note    $hooks_json also declares extra hook event(s), harmless:$extra_events"
          fi
        fi
      fi
      missing_scripts=""
      for name in write_handoff handoff_turn_append handoff_ctx_check handoff_session_start handoff_recover_tail handoff_statusline handoff_compact_reset handoff_provenance; do
        [[ -f "$vdir/bin/$name.sh" ]] || missing_scripts="$missing_scripts $name.sh"
      done
      if [[ -n "$missing_scripts" ]]; then
        echo "  BROKEN  $vdir/bin is missing:$missing_scripts (the plugin's hooks call these directly)"
        broken=$((broken + 1))
      else
        echo "  ok      $vdir/bin has all eight scripts"
      fi
    fi
    echo
  fi
  # Plugin/script coexistence (v0.14.0+ ships a plugin form of this tool).
  # Plugin hooks and these script-install hooks COEXIST — Claude Code fires
  # both, no dedup — so a machine with both installed double-fires every
  # hook. Advisory only: never counts toward `broken`, same as the model and
  # statusLine checks above, since neither installed form is itself faulty.
  # script_hooks_present is deliberately the narrow, SessionStart-marker-only
  # signal (unchanged from before #64/#70): it decides WARN vs. info for
  # the coexistence note specifically, not whether the per-script loop above
  # ran (that's plugin_only/bare_wired, a broader check, see above).
  if [[ -n "$plugin_dir" ]]; then
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
      # F5: "nothing to do here" used to follow this, which contradicted the
      # plugin cache checks that just ran a few lines up. Reworded to say
      # what's actually true: doctor reads the plugin's files to verify them,
      # it just never installs, updates, or removes them (that stays
      # Claude Code's own /plugin command).
      echo "  info    plugin install detected ($plugin_dir); this installer's doctor"
      echo "          does not manage plugin installs (install/update/removal is"
      echo "          Claude Code's own /plugin command); the checks above are"
      echo "          read-only verification of the plugin's cache, not management."
    fi
    echo
  fi
  if (( broken )); then
    echo "doctor: $broken issue(s) found." >&2
    if (( plugin_only )); then
      # #64: never point a plugin-only machine at ./install.sh, that is the
      # one action that manufactures the dual-mode state the README warns
      # about (a second, parallel bare-scripts install; every hook then
      # fires twice). Point at the plugin's own update path instead.
      echo "        This is a plugin-only install: do not run ./install.sh." >&2
      echo "        Reinstall the plugin instead: '/plugin uninstall claude-code-handoff'," >&2
      echo "        then '/plugin install claude-code-handoff@claude-code-handoff'." >&2
    else
      echo "        Re-run ./install.sh from a persistent clone (not a /tmp checkout)." >&2
    fi
    return 1
  fi
  echo "doctor: all hooks resolve."
}

