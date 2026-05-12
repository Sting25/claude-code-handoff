# Changelog

Notable changes to claude-code-handoff. The intended use of this file
is to flag any change to the shipped hook commands or permission
entries — those are the parts that don't auto-update from a `git pull`,
because they live in `~/.claude/settings.json` on the user's machine.

If a future release changes any of them, re-running `./install.sh`
after `git pull` re-patches settings.json idempotently (existing
entries are detected by marker substring and left alone; new ones
are appended).

## [unreleased]

### Added
- New `UserPromptSubmit` hook (`bin/handoff_ctx_check.sh`) that
  measures the byte size of Claude Code's transcript JSONL and, past
  a configurable threshold, injects a `<system-reminder>` instructing
  the assistant to flag a `/handoff` moment passively. Replaces
  vibes-based "you've been at it a while" heuristics with a real
  measurement.
- `bin/handoff_turn_append.sh` (the existing `Stop` hook) now also
  records transcript byte size to `.claude/handoff_backups/.ctx_<id>`
  each turn. That file is the input the new UserPromptSubmit hook
  reads.
- Three new env vars to tune the size signal:
  `HANDOFF_CTX_WINDOW_TOKENS` (default 200000),
  `HANDOFF_CTX_THRESHOLD_PCT` (default 50),
  `HANDOFF_CTX_COOLDOWN_KB` (default 100).
- New shipped hook command + permission for the
  UserPromptSubmit hook. **Re-run `./install.sh` after `git pull`**
  to patch them into `~/.claude/settings.json`.

### Shipped hook commands (new)
- `UserPromptSubmit` — `bash $HOME/.claude/bin/handoff_ctx_check.sh 2>/dev/null || true`

### Shipped permissions (new)
- `Bash(bash $HOME/.claude/bin/handoff_ctx_check.sh)`

## [0.1.0] — 2026-05-12

First versioned release. Behavior matches the original out-of-tree
version that lived directly under `~/.claude/`.

### Added
- MIT `LICENSE`.
- `install.sh` symlinks the skill + bin scripts into `~/.claude/`.
- `install.sh` auto-patches `~/.claude/settings.json` via `jq`
  (backup-then-merge, idempotent). Falls back to printing the snippet
  if jq isn't installed.
- `install.sh --uninstall` removes the symlinks and strips the
  patched entries from settings.json. Unrelated hooks / permissions
  in the same file are left untouched.

### Shipped hook commands
- `SessionStart` — `f="$CLAUDE_PROJECT_DIR/.claude/handoff_current.md"; if [ -f "$f" ]; then echo '## Auto-loaded handoff from previous session'; echo; cat "$f"; fi`
- `SessionEnd` — `bash $HOME/.claude/bin/write_handoff.sh >/dev/null 2>&1 || true`
- `Stop` — `bash $HOME/.claude/bin/handoff_turn_append.sh 2>/dev/null || true`

### Shipped permissions
- `Bash(bash $HOME/.claude/bin/write_handoff.sh)`
- `Bash(bash $HOME/.claude/bin/handoff_turn_append.sh)`

The installer substitutes `$HOME` to the actual home directory at
install time when writing permission entries (Claude Code matches
permission strings literally).
