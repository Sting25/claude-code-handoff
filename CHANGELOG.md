# Changelog

Notable changes to claude-code-handoff. The intended use of this file
is to flag any change to the shipped hook commands or permission
entries — those are the parts that don't auto-update from a `git pull`,
because they live in `~/.claude/settings.json` on the user's machine.

If a future release changes any of them, re-running `./install.sh`
after `git pull` re-patches settings.json idempotently (existing
entries are detected by marker substring and left alone; new ones
are appended).

## [0.4.0] — 2026-05-17

### Changed
- `handoff_ctx_check.sh` now uses the **real** token count from the
  latest assistant turn's `usage` block (input + cache_read +
  cache_creation) instead of a 4-bytes-per-token estimate against
  the transcript JSONL. With heavy prompt caching the byte estimate
  understates real context use by a wide margin — most visibly on
  the 1M tier, where the threshold could fail to fire even at
  genuinely-saturated context. Token count is the same number
  Claude Code's `/context` reports.
- `handoff_turn_append.sh` writes the per-turn token sum to a new
  sibling file `.claude/handoff_backups/.ctx_tokens_<session_id>`.
  The byte-size file `.ctx_<session_id>` is still written as a
  fallback signal (used when the tokens file isn't yet populated —
  first prompt of a fresh session, or an older install).
- `handoff_ctx_check.sh` auto-detects the context window from
  `~/.claude.json`. If this project's `lastModelUsage` records any
  model with a `[1m]` suffix, the default window becomes
  `1000000` tokens; otherwise `200000`. Setting
  `HANDOFF_CTX_WINDOW_TOKENS` explicitly still overrides.
- Emitted `<system-reminder>` reads
  `"Context at ~N tokens (~P% of a W-token window)"` — the legacy
  `"Transcript at NKB"` wording is gone since bytes are no longer
  the primary signal.
- Cooldown gate (`HANDOFF_CTX_COOLDOWN_KB`) now only applies to
  re-flags. The first time a session crosses the threshold the
  reminder always fires, regardless of transcript byte size.
  Previously a token-heavy / byte-light session could be gated on
  the byte minimum even on its first crossing.

### Notes
- No hook command or permission changes — re-installing is **not**
  required. `git pull` is sufficient to pick up the new behavior.

## [0.3.0] — 2026-05-13

### Added
- `write_handoff.sh` now rotates the previous `handoff_current.md`
  into `<repo>/.claude/handoff_history/handoff_<YYYY-MM-DD_HHMMSS>.md`
  before each new write, and prunes the directory to the
  `HANDOFF_HISTORY_KEEP` newest (default 5, env var override). The
  archived filename reflects the original generation time (file
  mtime), so the history reads as a chronological log of session
  endings. Set `HANDOFF_HISTORY_KEEP=0` to disable retention.
- New `bin/handoff_session_start.sh` script for the `SessionStart`
  hook. Cats `handoff_current.md` as before, plus two extras:
  (a) if the current handoff has the unedited placeholder Notes
  block (auto-write, no `/handoff` was run), it also cats the most
  recent file from `handoff_history/` so the new session inherits
  curated prose from one session further back; (b) prints a one-line
  pointer to `handoff_history/` when entries exist, so the assistant
  knows it can run `/handoff-more` to pull more. Suppress (a) via
  `HANDOFF_SS_DISABLE_FALLBACK=1`.
- New `/handoff-more` skill (`skills/handoff-more/SKILL.md`). When
  invoked in a fresh session, reads the retained snapshots from
  `.claude/handoff_history/` into context. Use when the current
  handoff is thin, when the user references work from a session
  further back, or to give a dormant sibling re-entering the repo
  deeper continuity than yesterday alone.
- `.claude/handoff_history/` is added to the project `.gitignore` by
  the existing self-bootstrap step on first write.

### Changed
- `SessionStart` hook command moved from an inline bash one-liner to
  `bash $HOME/.claude/bin/handoff_session_start.sh`. The installer
  detects the legacy inline form on re-install and migrates it out
  before installing the new one — no manual edit needed; just
  re-run `./install.sh` after `git pull`.

### Shipped hook commands (new / changed)
- `SessionStart` (CHANGED) — `bash $HOME/.claude/bin/handoff_session_start.sh 2>/dev/null || true`

### Shipped permissions (new)
- `Bash(bash $HOME/.claude/bin/handoff_session_start.sh)`

**Re-run `./install.sh` after `git pull`** to migrate the legacy
SessionStart hook and add the new permission.

## [0.2.0] — 2026-05-12

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
