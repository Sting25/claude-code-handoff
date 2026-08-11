# ------------------------------------------------------------------ settings.json

print_manual_snippet() {
  cat <<EOF

Paste this into $settings under "hooks" and "permissions":

{
  "hooks": {
    "SessionStart":      [{ "hooks": [{ "type": "command", "command": "$ss_cmd" }] }],
    "SessionEnd":        [{ "hooks": [{ "type": "command", "command": "$se_cmd" }] }],
    "PreCompact":        [{ "hooks": [{ "type": "command", "command": "$pc_cmd" }] }],
    "PostCompact":       [{ "hooks": [{ "type": "command", "command": "$post_cmd" }] }],
    "Stop":              [{ "hooks": [{ "type": "command", "command": "$st_cmd" }] }],
    "UserPromptSubmit":  [{ "hooks": [{ "type": "command", "command": "$up_cmd" }] }]
  },
  "permissions": {
    "allow": [
      "$perm_write",
      "$perm_stop",
      "$perm_ctx",
      "$perm_ss",
      "$perm_sl",
      "$perm_reset"
    ]
  },
  "statusLine": { "type": "command", "command": "$sl_cmd" }
}

NOTE: only add the "statusLine" key if you don't already have a statusLine
set — it is a single slot (not a list like hooks), so pasting it would
replace your existing status line. To keep yours AND get handoff's context
numbers, call our script from your existing statusline command instead.
EOF
}

# Install $settings.tmp over $settings — the ONE place every maybe_install_*/
# maybe_uninstall_*/migrate_* function below lands its jq output, instead of
# each calling `mv` directly. ensure_settings_json validates $settings once,
# up front, but every one of these functions re-reads whatever the PREVIOUS
# step's `mv` just installed — so that one up-front check does not cover the
# rest of the chain. jq on empty/unreadable input still exits 0 and prints
# nothing (a crashed jq, a disk full mid-write, anything that truncates the
# pipe): a bare `mv` of that nothing would blank settings.json with a
# false-success exit code, and because rc==0 the EXIT trap's rollback (see
# cleanup() near the top of the file) would never fire — the script would
# print "done" over a wiped config. handoff_statusline.sh's write_cache
# already guards precisely this pattern ("never install the tmp unless printf
# succeeded") for a far less valuable file; this is the same discipline
# applied to the one file every hook depends on.
#
# Every call site here runs inside patch_settings() or unpatch_settings(),
# which arm patch_in_progress and take the pre-patch backup BEFORE calling
# any of these — so `exit 1` on a bad tmp both aborts the run AND is the
# rollback: cleanup() sees patch_in_progress=1 and a non-zero rc and restores
# $settings from $settings_backup. No caller needs to check a return value.
commit_settings_tmp() {
  if [[ ! -s "$settings.tmp" ]] || ! jq -e . "$settings.tmp" >/dev/null 2>&1; then
    echo "  ERROR   jq produced empty or invalid JSON while patching $settings — aborting." >&2
    echo "          $settings is unmodified; restoring from the pre-patch backup." >&2
    exit 1
  fi
  mv "$settings.tmp" "$settings"
}

# Install-or-reconcile one hook. Three cases per event:
#   - marker absent            -> append the canonical command (fresh install)
#   - marker present, current  -> ok (idempotent re-run)
#   - marker present, STALE    -> rewrite it in place to the canonical command,
#     printing the old form loudly. The marker matches any release's variant of
#     our command (it is just the script path), so when a release changes the
#     arguments/redirects around that path, the old wiring would otherwise pass
#     the "already present" check forever. Rewriting here makes the install
#     self-healing — no bespoke migrate_* function per argument change (this
#     subsumed the former migrate_legacy_se_hook; migrate_legacy_ss_hook must
#     stay because the pre-0.3.0 inline form does not contain the script path).
#     Never a silent skip and never a silent clobber: the old form is printed
#     and lives in the settings.json backup made at the top of patch_settings.
#     Comparison is against THIS event's canonical $cmd — events may share a
#     marker (SessionEnd/PreCompact both use write_handoff.sh) but each call
#     reconciles only its own event's list against its own command.
maybe_install_hook() {
  local event="$1" marker="$2" cmd="$3"
  if jq -e --arg e "$event" --arg m "$marker" \
       '(.hooks[$e] // []) | any(.. | .command? // "" | contains($m))' \
       "$settings" >/dev/null 2>&1; then
    local stale
    stale="$(jq -r --arg e "$event" --arg m "$marker" --arg c "$cmd" \
      '(.hooks[$e] // []) | [.. | .command? // "" | select(contains($m) and . != $c)] | .[]' \
      "$settings" 2>/dev/null)"
    if [[ -z "$stale" ]]; then
      echo "  ok      hook $event (already present)"
      return
    fi
    # Rewrite every stale marker-match to the canonical command, then drop
    # exact duplicates of the canonical beyond the first (covers a config that
    # somehow held both a stale AND a current entry — rewriting alone would
    # leave two identical hooks firing twice). Groups that empty out are
    # removed; a user's own co-located command in the same group is untouched.
    jq --arg e "$event" --arg m "$marker" --arg c "$cmd" '
      .hooks[$e] |= (
          map(.hooks |= ((. // []) | map(
            if ((.command // "") | contains($m)) then .command = $c else . end)))
        | delpaths([paths(objects and ((.command? // "") == $c))][1:])
        | map(select((.hooks // []) | length > 0))
      )
    ' "$settings" > "$settings.tmp"
    commit_settings_tmp
    echo "  UPDATE  hook $event — stale command from an older install rewritten:"
    while IFS= read -r _old; do
      echo "          old: $_old"
    done <<< "$stale"
    echo "          new: $cmd"
    echo "          (old form also preserved in the settings.json backup above)"
    return
  fi
  jq --arg e "$event" --arg c "$cmd" '
    .hooks //= {}
    | .hooks[$e] = ((.hooks[$e] // []) + [{"hooks": [{"type": "command", "command": $c}]}])
  ' "$settings" > "$settings.tmp"
  commit_settings_tmp
  echo "  add     hook $event"
}

maybe_install_perm() {
  local perm="$1"
  if jq -e --arg p "$perm" '(.permissions.allow // []) | index($p)' \
       "$settings" >/dev/null 2>&1; then
    echo "  ok      permission already present: $perm"
    return
  fi
  jq --arg p "$perm" '
    .permissions //= {}
    | .permissions.allow = ((.permissions.allow // []) + [$p])
  ' "$settings" > "$settings.tmp"
  commit_settings_tmp
  echo "  add     permission: $perm"
}

# Optional model pin. Never overwrites an existing "model" key: a machine
# where the user already chose a model keeps that choice, and the differing
# request is reported instead of applied. A write is recorded in
# $model_pin_record (0600 via umask) so --uninstall can undo exactly ours.
maybe_install_model() {
  [[ -n "$model_pin" ]] || return 0
  local cur
  cur="$(jq -r '.model // ""' "$settings" 2>/dev/null)"
  if [[ -z "$cur" ]]; then
    jq --arg m "$model_pin" '.model = $m' "$settings" > "$settings.tmp"
    commit_settings_tmp
    printf '%s\n' "$model_pin" > "$model_pin_record"
    echo "  add     model: $model_pin (recorded for uninstall)"
  elif [[ "$cur" == "$model_pin" ]]; then
    echo "  ok      model already set: $cur"
  else
    echo "  keep    model '$cur' (your existing choice preserved — NOT overwriting"
    echo "          with requested '$model_pin'; edit settings.json yourself to change it)"
  fi
}

maybe_uninstall_model() {
  if [[ ! -f "$model_pin_record" || -L "$model_pin_record" ]]; then
    echo "  ok      model (not pinned by this installer)"
    return 0
  fi
  local rec cur
  rec="$(tr -d '[:space:]' < "$model_pin_record" 2>/dev/null || true)"
  cur="$(jq -r '.model // ""' "$settings" 2>/dev/null)"
  if [[ -n "$rec" && "$cur" == "$rec" ]]; then
    jq 'del(.model)' "$settings" > "$settings.tmp"
    commit_settings_tmp
    echo "  remove  model: $rec (this installer set it, unchanged since)"
  else
    echo "  keep    model '$cur' (differs from the recorded pin '$rec' — you changed"
    echo "          it since install; leaving your value alone)"
  fi
  rm -f "$model_pin_record"
}

# statusLine is a single settings.json slot (unlike hooks, which are lists we
# can append to), so wiring it must never clobber a user's own setting:
#   - absent/null            -> set ours
#   - present, ours, current -> ok (idempotent re-run)
#   - present, ours, STALE   -> rewrite the command to canonical, printing the
#     old form (same self-healing rule as maybe_install_hook: the marker only
#     proves it is our script, not that the args/redirects are this release's).
#     Only .command is replaced so any sibling keys the user added (e.g.
#     "padding") survive.
#   - present and NOT ours   -> untouched; print the documented manual step.
maybe_install_statusline() {
  if jq -e '(.statusLine // null) == null' "$settings" >/dev/null 2>&1; then
    jq --arg c "$sl_cmd" '.statusLine = {"type": "command", "command": $c}' \
      "$settings" > "$settings.tmp"
    commit_settings_tmp
    echo "  add     statusLine"
    return
  fi
  if jq -e --arg m "$sl_marker" '(.statusLine.command // "") | contains($m)' \
       "$settings" >/dev/null 2>&1; then
    local cur_sl
    cur_sl="$(jq -r '.statusLine.command // ""' "$settings" 2>/dev/null)"
    if [[ "$cur_sl" == "$sl_cmd" ]]; then
      echo "  ok      statusLine (already ours)"
      return
    fi
    jq --arg c "$sl_cmd" '.statusLine.command = $c' "$settings" > "$settings.tmp"
    commit_settings_tmp
    echo "  UPDATE  statusLine — stale command from an older install rewritten:"
    echo "          old: $cur_sl"
    echo "          new: $sl_cmd"
    echo "          (old form also preserved in the settings.json backup above)"
    return
  fi
  echo "  skip    statusLine (you already have one — to use handoff's instead, set"
  echo "          \"statusLine\": {\"type\": \"command\", \"command\": \"$sl_cmd\"}"
  echo "          yourself, or call our script from your existing statusline command)"
}

maybe_uninstall_statusline() {
  if jq -e --arg m "$sl_marker" '(.statusLine.command // "") | contains($m)' \
       "$settings" >/dev/null 2>&1; then
    jq 'del(.statusLine)' "$settings" > "$settings.tmp"
    commit_settings_tmp
    echo "  remove  statusLine"
  elif jq -e '(.statusLine // null) != null' "$settings" >/dev/null 2>&1; then
    echo "  ok      statusLine (not ours; leaving alone)"
  else
    echo "  ok      statusLine (not present)"
  fi
}

