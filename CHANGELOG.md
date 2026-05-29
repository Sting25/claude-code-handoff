# Changelog

Notable changes to claude-code-handoff. The intended use of this file
is to flag any change to the shipped hook commands or permission
entries — those are the parts that don't auto-update from a `git pull`,
because they live in `~/.claude/settings.json` on the user's machine.

If a future release changes any of them, re-running `./install.sh`
after `git pull` re-patches settings.json idempotently (existing
entries are detected by marker substring and left alone; new ones
are appended).

## [0.8.2] — 2026-05-29

Audit remainder (issue #16: MEDIUM/LOW/INFO findings after v0.8.1) plus a
Forge parity bug (issue #21). No hook-command or permission changes — a
`git pull` re-points the symlinked scripts; no re-install needed. The one
exception is installs made from a **volatile checkout** (a `/tmp` worktree,
git-archive extract, CI scratch dir): those symlinks dangle once the source
is cleaned up. v0.8.2 now copies instead of symlinks in that case — re-run
`./install.sh` from a persistent clone (or with `--copy`) to repair a prior
dangling install, and `./install.sh --doctor` to check.

### Added
- **`./install.sh --doctor`** — verifies every installed `~/.claude/bin/*.sh`
  hook resolves to a real file; exits non-zero listing any dangling/missing
  ones. (#21)
- **`./install.sh --copy` / `--link`** — force copy vs. symlink install mode;
  `HANDOFF_FORCE_SYMLINK=1` overrides the volatile-source auto-copy. (#21)
- **SessionStart sibling self-check** — `handoff_session_start.sh` warns
  (visibly, in SessionStart output) if any of its sibling hook links dangle;
  silent when healthy. Second layer of defense for the silent-no-op mode. (#21)

### Fixed
- **Installing from a volatile source no longer dangles silently.** install.sh
  detects a `repo_root` under `/tmp`, `/var/tmp`, `/dev/shm`, `$TMPDIR`, or an
  mktemp-style `tmp.XXXX` component and switches to copy mode (which survives
  the source's cleanup) with a clear warning. A persistent clone still
  symlinks. (#21)
- **`handoff_turn_append.sh` validates `session_id`** before interpolating it
  into dump/cursor/lock/ctx paths — rejects anything outside `[A-Za-z0-9_-]`,
  closing a newline/slash/`..` path-construction vector. (#16, MEDIUM)
- **mkdir-lock fallback now reclaims a stale `.lock.d`.** On platforms without
  `flock` (macOS/BSD), a lock left by a hard-killed holder froze per-session
  appends forever; age-based detection (`HANDOFF_LOCK_STALE_SECS`, default 60s)
  reclaims and retries once. (#16, MEDIUM)
- **`HANDOFF_CTX_WINDOW_TOKENS` div-by-zero.** A non-positive-integer override
  (0/negative/garbage) divided by zero and killed the hook under `set -e`; such
  values now fall through to auto-detection. (#16, LOW)
- **`handoff_session_start.sh` upgraded to `set -euo pipefail`**, with the
  history-pointer `ls | wc -l` pipeline hardened so an empty history dir can't
  abort the hook before the current handoff is emitted. (#16, LOW)
- **Owner-only permissions (`umask 077`).** settings.json (can hold env tokens),
  its backups, copy-mode installs, and the handoff doc (verbatim session prose)
  are now created 0600/0700. (#16, LOW)
- **`$claude_home` validation** — install.sh refuses a root or relative path and
  warns when it's outside `$HOME`, before touching anything under it. (#16, INFO)
- **Configured-but-missing substrate is surfaced on stderr** instead of silently
  skipped, so `HANDOFF_SUBSTRATE_NAME` typos are visible. (#16, INFO)

### Tests
- New negative-controlled coverage for all of the above, plus three previously
  untested paths from the #16 audit: the System-log handoff nudge, install.sh's
  legacy hook-migration, and the symlink→copy fallback. Suite remains
  dependency-free; `./tests/run.sh` green.

## [0.8.1] — 2026-05-29

Security hardening from a full code + security audit (30 confirmed findings
after adversarial verification; these are the HIGH-severity ones). No hook-
command or permission changes — a `git pull` re-points the symlinked scripts;
no re-install needed. Re-running `./install.sh` is harmless, and existing dump
files are tightened to 0600 on the next session automatically.

### Fixed (security)
- **Raw transcript dumps are now created owner-only (0600), and git-ignored
  before the first write.** The Stop hook's per-turn dumps contain verbatim
  session content — including anything sensitive surfaced in tool output — but
  were written with plain `>` redirection (0664, world/group-readable), and the
  `.gitignore` entry for `.claude/handoff_backups/` was only added at SessionEnd
  by `write_handoff.sh` — after the Stop hook had already written dumps on the
  first prompt, leaving a window where `git add` could stage secrets. Now
  `handoff_turn_append.sh` runs `umask 077` (dir 0700, dump 0600), defensively
  `chmod 600`s the dump (tightening files left 0664 by older versions), and
  bootstraps the `.gitignore` entry itself before the first dump write.
- **`install.sh` restores `settings.json` on a mid-patch failure.** The patch
  is a series of separate `jq` writes after a backup; if one failed mid-sequence
  the file was left half-patched with no restore. The `EXIT` trap now rolls
  `settings.json` back to the pre-patch backup on any abnormal exit during the
  patch/unpatch sequence (backup retained for inspection).
- **`install.sh` uninstall matches the full installed path, not the bare
  filename.** Hook markers were bare filenames matched with `jq contains()`, so
  a user's own hook merely mentioning a script name (e.g. a wrapper
  `my_handoff_turn_append.sh`) could be removed on uninstall. Markers are now
  the full `$HOME/.claude/bin/<script>` command path — more specific and
  backward-compatible. `bin/` is unchanged; this is `install.sh` only.
- **`HANDOFF_HISTORY_KEEP` is validated against negative / non-numeric values.**
  The rotation guard skipped on `KEEP<=0`, but pruning still ran
  `tail -n +$((KEEP+1))`; with `KEEP=-1` that is `tail -n +0`, which on GNU
  means "from the start" — so prune silently **deleted every handoff_history
  file**. Any value that isn't a non-negative integer now warns and falls back
  to the default 5. `bin/write_handoff.sh`.

## [0.8.0] — 2026-05-29

Robustness, portability, and test coverage: macOS/BSD support for the hook
scripts, hardened `install.sh` settings.json patching, a `--if-curated`
data-loss fix, spaced-filename handling in the in-flight list, and a new
`tests/` suite. No hook-command or permission changes — a `git pull` re-points
the symlinked scripts; no re-install needed for existing installs.

### Fixed
- **In-flight `.md` files with spaces in their names are no longer dropped from
  the handoff.** `list_inflight_md` parsed `git status --porcelain` with
  `awk '{print $2}'`, which truncates at the first space — and plain porcelain
  also C-quotes spaced paths — so a file like `docs/my notes.md` failed the
  `.md` filter and silently vanished from the "In-flight" section. Now uses
  `git status --porcelain -z` (NUL-terminated, verbatim paths) parsed in bash.
  `bin/write_handoff.sh`.
- **`install.sh` is robust to empty / malformed `settings.json`, and uninstall
  no longer deletes a user's co-located hook.** Three related issues, all in the
  settings.json patching:
  - *Empty file → silent false success.* An empty (0-byte) `settings.json`
    isn't absent, so it wasn't seeded with `{}`; `jq` then read empty input,
    emitted nothing, and the `> tmp; mv` blanked the file while exiting `0` —
    the install reported success but wired no hooks. Now empty (and absent)
    files are normalized to `{}` before patching.
  - *Malformed file → mid-run abort + orphaned `.tmp`.* Invalid JSON made `jq`
    fail mid-patch (exit 5), aborting after the backup and leaving a stray
    `settings.json.tmp`. Now JSON is validated up front: a malformed file is
    left **untouched** with a clear error + the manual snippet, and an `EXIT`
    trap removes any stray temp file regardless.
  - *Uninstall deleted co-located commands.* The uninstall/migrate `jq` filters
    selected at the hook-**group** level, so removing our command dropped the
    whole group — taking any user command sharing that group with it. Filtering
    is now at the **command** level: only matching commands are removed, groups
    that become empty are pruned, and unrelated commands are preserved.
- **`--if-curated` no longer clobbers curated notes when the sentinel string
  appears elsewhere in the file (data loss).** The SessionEnd safety-net
  decided "this is an unedited placeholder, safe to overwrite" by grepping the
  *whole* `handoff_current.md` for the placeholder sentinel. But the snapshot
  embeds verbatim commit subjects, and curated Notes can legitimately quote the
  sentinel — either match made the safety-net overwrite real, curated notes.
  Detection is now scoped: the file counts as an unedited placeholder only when
  the sentinel is the **first non-blank line under the `## Notes from this
  session` header** (where the placeholder builder writes it). The sentinel
  string itself is unchanged, so placeholders written by older versions are
  still recognized. `bin/write_handoff.sh`.
- **`install.sh` no longer aborts when a non-owner runs it.** The post-link
  `chmod +x` targeted the repo's source scripts; under `set -euo pipefail`,
  a user who doesn't own those files (e.g. a forge user installing from
  chris-owned files) hit `chmod: Operation not permitted` and the script
  aborted **before `patch_settings`**, leaving a half-install with the hooks
  unwired. The `chmod` is now best-effort (`2>/dev/null || true`) — the
  scripts are committed mode 0755 so a normal checkout is already executable,
  and the `chmod` only rescues filesystems that don't preserve the exec bit.
- **macOS / BSD portability of the hook scripts.** Four GNU/bash-4-isms that
  break (or silently misbehave) on stock macOS are now portable:
  - `handoff_turn_append.sh` used `flock` (util-linux, absent on macOS) — now
    falls back to an atomic `mkdir` lock released by an `EXIT` trap;
  - it used `tac` (absent on macOS) to find the last assistant turn — now
    `grep … | tail -n 1`;
  - it used the bash-4 `mapfile` builtin (macOS ships bash 3.2) for prune —
    now a `while read` loop over a process substitution;
  - `write_handoff.sh` used `date -u -r FILE` (GNU-only; on BSD `-r` means
    epoch, so it silently fell back to *current* time and mis-stamped rotated
    history filenames) — now a portable `stat`+`date` mtime helper covering
    both GNU (`stat -c` / `date -d @`) and BSD (`stat -f` / `date -r`).
  (Git Bash on Windows is GNU, so it was already fine; this is macOS-specific.)

### Added
- **Behavioral coverage for the scripts' core paths**, beyond the per-fix
  regression tests. `handoff_ctx_check.sh` and `handoff_session_start.sh`
  previously had **no** tests; both are now covered (threshold / window /
  token-vs-bytes fallback / suggest-vs-act / cooldown for the ctx hook;
  placeholder detection / history fallback / recover banner / disable toggles
  for SessionStart). Adds core coverage for `handoff_turn_append.sh` (cursor
  dedup, incremental append, noise stripping, tool-result truncation, repo /
  transcript guards) and `write_handoff.sh` (document shape, argument parsing,
  `--if-stale-by` deprecation alias, history pruning + `HANDOFF_HISTORY_KEEP=0`,
  `.gitignore` bootstrap toggle, pinned injection, in-flight `.md` listing,
  substrate snapshot). Each test file verified with a negative control.
- **Test suite** under `tests/` (`./tests/run.sh`) — dependency-free bash +
  git (jq-using tests self-skip without it). Covers the fixes above:
  `--if-curated` preserve-vs-overwrite across placeholder / curated / embedded-
  sentinel / quoted-sentinel / malformed fixtures; install.sh surviving a
  failing `chmod`; and settings.json robustness (empty / malformed / absent /
  valid+idempotent inputs, and command-level uninstall preserving co-located
  user hooks); in-flight `.md` listing of spaced filenames; and macOS/BSD
  portability (flock-absent mkdir-lock fallback, tac→grep|tail token
  extraction, mapfile→while prune, and the stat+date mtime stamp under
  simulated-BSD tool shims). New changes ship with a test going forward.
- **README documents the `tests/` suite and platform compatibility.** The repo
  tree now lists `tests/`, the Develop section explains `./tests/run.sh`, and a
  Compatibility note records the supported platforms (Linux, macOS, Windows Git
  Bash) and the `bash`/`git`/`jq`/`perl` dependencies.

## [0.7.2] — 2026-05-27

Reliability, privacy, docs, and Windows (Git Bash) support. No hook-command
or permission changes; the `.gitignore` bootstrap gains one entry, picked up
automatically on the next handoff — no re-install needed for existing repos
(Windows copy-mode installs being the exception; see Added).

### Fixed
- **Raw transcript dumps are now gitignored.** `write_handoff.sh` adds
  `.claude/handoff_backups/` to the project `.gitignore` on bootstrap. The
  Stop hook writes verbatim transcript content there (which can include
  secrets surfaced in tool output); previously only the handoff and history
  paths were ignored, so a `git add -A` could commit the dumps.
- **Manual-install docs shipped the pre-0.5.0 SessionEnd command.**
  `skills/handoff/README.md` now uses `write_handoff.sh --if-curated`;
  without it the SessionEnd safety-net can clobber a curated `/handoff`
  (the bug v0.4.1/v0.5.0 fixed). The manual steps also now include
  `handoff_session_start.sh` and the `handoff-more`/`handoff-recover` skills
  (previously omitted — following them left a broken SessionStart hook), and
  the components diagram lists `handoff-recover`.
- **Hook/permission counts corrected** from "three hooks / two permissions"
  to **four / four** in `install.sh --help` and `skills/handoff/README.md`.
- **Documented four env vars** the code reads but the skill README omitted:
  `HANDOFF_PINNED_FILE`, `HANDOFF_SYSTEMLOG_FILE`, `HANDOFF_SS_DISABLE_RECOVER`,
  `HANDOFF_CTX_REMINDER_MODE`.

### Added
- **Windows (Git Bash / WSL) support.**
  - `.gitattributes` forces `LF` on `*.sh` so a CRLF checkout doesn't break
    the bash shebang.
  - `install.sh` falls back to **copying** scripts into `~/.claude` when real
    symlinks aren't available (Git Bash without Developer Mode), prints a
    reminder to re-run `./install.sh` after a `git pull` (copies, unlike
    symlinks, don't auto-update), and `--uninstall` removes copies too.
  - Under WSL everything already worked; this makes plain Git Bash work too.

## [0.7.1] — 2026-05-27

No hook-command or permission changes — a `git pull` is enough; no need to
re-run `./install.sh`. Documentation / release-hygiene only.

### Fixed
- **README described the deprecated flag as current.** The `SessionEnd`
  hook section claimed the hook passes `--if-stale-by 300` with a
  "last five minutes" mtime rule. Since v0.5.0 it actually passes
  `--if-curated` (a content check — the placeholder sentinel — not a time
  window). Reworded so the README documents the shipped behavior instead
  of steering users toward the deprecated flag.
- Corrected the `--if-stale-by` deprecation note. It promised removal in
  v0.6.0, but the alias shipped through v0.6.0 and v0.7.0 unchanged. The
  note now reads "a future release" (in `write_handoff.sh` and this file)
  so the docs match reality. The alias still works as an `--if-curated`
  synonym; nothing functional changed.
- Release tags `v0.5.0`, `v0.6.0`, and `v0.7.0` were created and pushed
  retroactively — the CHANGELOG and `vX.Y.Z:` release commits existed but
  the annotated tags had been missed, leaving tags stuck at v0.4.2.

## [0.7.0] — 2026-05-25

No settings.json / hook-command changes — a `git pull` is enough; no
need to re-run `./install.sh`. Two additions to `bin/write_handoff.sh`,
both feature-gated and INERT unless the relevant file exists, so repos
that don't opt in are entirely unaffected.

### Added
- **Pinned section.** If `<repo>/.claude/handoff_pinned.md` exists, its
  contents are injected verbatim into every handoff (first, before the
  git snapshot). The script only *reads* the file — it is never rotated
  or regenerated, so it survives across sessions until you edit it. This
  is the durable-but-temporary layer between permanent rules (`AGENTS.md`)
  and this-session intent (the Notes block): carry-forward context +
  guardrails that outlive a session but expire when the underlying state
  resolves. Path overridable via `HANDOFF_PINNED_FILE`; auto-added to
  `.gitignore` (same per-developer, not-checked-in posture as the handoff).
- **System-log nudge.** If `<repo>/SYSTEM_LOG.md` exists, the handoff
  flags (a `⚠️` section) when this session's commits look *system-level*
  (path or subject heuristic) but none touched the log — a reminder to
  record shape-changing work. Handoff-time only; fires on the
  previous-handoff→HEAD range, so it's silent on routine sessions (the
  anti-alert-fatigue guard). Path overridable via `HANDOFF_SYSTEMLOG_FILE`;
  tune the heuristics inline if it over-fires for your repo.

## [0.6.0] — 2026-05-22

### Added
- `skills/handoff-recover/SKILL.md` — new `/handoff-recover` slash
  command. Composes a retroactive curated Notes block when the
  previous session ended without `/handoff` (crashed, killed,
  never invoked). Reads the previous session's raw per-turn dump
  under `.claude/handoff_backups/`, the most recent curated
  handoff under `.claude/handoff_history/`, and (if present) the
  host-wide session registry; writes the recovered Notes back
  into `handoff_current.md` so the recovery persists into future
  handoff history.
- `bin/handoff_session_start.sh` now emits a loud
  `ACTION: RUN /handoff-recover` sentinel block whenever the
  placeholder Notes block is detected. Replaces the previous
  silent-fallback behavior — the model is now explicitly told to
  reconstruct rather than just see the fallback and proceed.
  Opt out via `HANDOFF_SS_DISABLE_RECOVER=1`.
- `bin/handoff_session_start.sh` placeholder detection also
  recognizes the `<!-- HANDOFF_PLACEHOLDER: ... -->` sentinel
  introduced in 0.5.0 (the prior detection was string-matching
  the pre-0.5.0 instruction line only; placeholder writes from
  0.5.0+ would have slipped through silently).

### Changed
- `install.sh` links the new skill into `~/.claude/skills/handoff-recover/`.
  Re-run `./install.sh` after `git pull` to pick it up (existing
  hooks and permissions are detected and skipped — only the new
  symlink is added).

### Deprecation status
- `--if-stale-by SECONDS` removal target shifted from v0.6.0 to
  v0.7.0. This release is feature-additive only; the deprecated
  flag still accepts its numeric argument and behaves as
  `--if-curated` with a stderr warning.

## [0.5.0] — 2026-05-21

### Added
- `HANDOFF_CTX_REMINDER_MODE` env var on `handoff_ctx_check.sh`.
  Default `suggest` preserves the original passive-mention reminder
  text (the assistant flags a /handoff moment to the user, who
  decides). Opt-in `act` switches the reminder to model-directed
  text — the assistant wraps up the current logical step and
  invokes /handoff itself without asking. Intended for projects
  where the assistant should autonomously refresh its context.
- `--if-curated` flag on `write_handoff.sh`. SessionEnd safety-net
  now detects whether the existing `handoff_current.md` has been
  curated by content (sentinel comment presence) rather than by
  mtime, so post-/handoff work in the same session no longer causes
  a false skip.
- `<!-- HANDOFF_PLACEHOLDER: ... -->` sentinel embedded in the
  auto-generated placeholder block. The /handoff skill now replaces
  the entire placeholder block (sentinel included) when adding
  curated Notes; removal of the sentinel is what tells the
  SessionEnd guard there's curated content to preserve.

### Changed
- `/handoff` skill (`skills/handoff/SKILL.md`) now instructs the
  assistant to **replace** the placeholder block when adding Notes,
  not append below it. Leaving the placeholder in place even with
  Notes added below would leave the sentinel intact, and SessionEnd
  could later overwrite the curated content.
- `install.sh` `se_cmd` switched from `--if-stale-by 300` to
  `--if-curated`. The legacy `migrate_legacy_se_hook` now detects
  any pre-0.5.0 form (write_handoff.sh present but `--if-curated`
  absent) and removes it so the current command installs cleanly.
  Covers both pre-0.4.1 (no guard) and 0.4.1-0.4.2 (`--if-stale-by`)
  callers in a single pass.

### Deprecated
- `--if-stale-by SECONDS` on `write_handoff.sh` — still accepted
  and behaves as `--if-curated` (the numeric argument is ignored),
  with a stderr deprecation warning. Slated for removal in a future
  release (the original v0.6.0 target slipped — see 0.7.1).

### Migration
- Re-run `./install.sh` after `git pull` to update
  `~/.claude/settings.json` from `--if-stale-by 300` to
  `--if-curated`. The migration block in `install.sh` handles this
  idempotently — no manual editing required.
- Opt-in to autonomous-act mode by adding to a project's
  `.claude/settings.json`:
  ```json
  "env": {
    "HANDOFF_CTX_REMINDER_MODE": "act",
    "HANDOFF_CTX_THRESHOLD_PCT": "30"
  }
  ```
  Lowering the threshold to ~30 pairs naturally with `act` mode —
  the model needs runway to find a clean boundary before context
  quality degrades. Projects without this env block keep the
  original passive-mention behavior at the 50% threshold.

## [0.4.2] — 2026-05-19

### Fixed
- `handoff_ctx_check.sh` 1M-tier auto-detection now degrades gracefully
  when the current project has no recorded `lastModelUsage`. Previously
  a fresh project entry — typically created by a directory rename or by
  opening a new repo for the first time — would default to a 200k
  window even for a clearly-1M user, causing the threshold check to
  fire at the wrong percentage. New detection order: (1) this project's
  `lastModelUsage` has `[1m]` → 1M; (2) this project's
  `lastModelUsage` exists but no `[1m]` → 200k (explicit non-1m signal
  respected); (3) this project's `lastModelUsage` is missing/empty →
  check globally across all projects in `~/.claude.json`; if any have
  `[1m]`, treat the user as a 1M user → 1M, else 200k.

### Migration
- No action required. The change is local-only — `git pull` (no
  re-install needed since the script is symlinked from `~/.claude/bin/`).

## [0.4.1] — 2026-05-19

### Fixed
- `SessionEnd` hook no longer clobbers a curated `/handoff` write. The
  shipped hook command now passes `--if-stale-by 300` to
  `write_handoff.sh`, which exits early (no rotation, no write) if
  `handoff_current.md` was modified within the last 300 seconds. Before
  this, invoking `/handoff` and then exiting the session within a few
  seconds — the natural flow — meant the safety-net write fired
  immediately afterward, rotated the curated content into
  `handoff_history/`, and wrote a fresh mechanical snapshot as the new
  `handoff_current.md`. The next session would auto-load the
  mechanical one and miss the curated prose.

### Changed
- New shipped `SessionEnd` hook command:
  `bash $HOME/.claude/bin/write_handoff.sh --if-stale-by 300 >/dev/null 2>&1 || true`
- `install.sh` includes `migrate_legacy_se_hook`: on re-install, it
  detects the pre-0.4.1 SessionEnd command (`write_handoff.sh` present,
  `--if-stale-by` absent) and removes it so the new command can be
  installed without duplication.

### Migration
- After `git pull`, run `./install.sh` again. The migration replaces
  the old SessionEnd hook with the new one. Existing settings.json is
  backed up to `settings.json.bak.<timestamp>` first.

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
