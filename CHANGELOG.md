# Changelog

Notable changes to claude-code-handoff. The intended use of this file
is to flag any change to the shipped hook commands or permission
entries — those are the parts that don't auto-update from a `git pull`,
because they live in `~/.claude/settings.json` on the user's machine.

If a future release changes any of them, re-running `./install.sh`
after `git pull` re-patches settings.json idempotently (existing
entries are detected by marker substring and left alone; new ones
are appended).

## [Unreleased]

### Fixed
- **`--doctor` now checks `handoff_recover_tail.sh`** — the script has been
  installed (and uninstalled) all along but was missing from doctor's
  checklist, so a dangling or deleted copy went unreported while
  `/handoff-recover`'s tail rescue silently no-opped. A guard test asserts
  it appears in doctor output.
- **The test suite's last real-`$HOME` write is gone.** The "persistent
  source" fixture in `test_install_ephemeral.sh` was anchored in the real
  `$HOME` (a mktemp base is volatile by definition); it now uses the repo
  checkout when that is persistent, falls back to `$HOME` only for a
  /tmp-clone run, and is trap-cleaned either way. Companion to #49.
- **Test suite no longer writes key material to the real `~/.claude`**
  (#49). Since the v0.10.0 signing feature, `write_handoff.sh` generates
  the per-machine HMAC secret on first signed write; the pre-existing
  `test_write_handoff_*.sh` files invoked it without jailing
  `HANDOFF_SECRET_FILE` or `HOME`, so the first `tests/run.sh` on a
  machine silently created `~/.claude/handoff_secret`. The jail now
  lives centrally in `tests/lib.sh` (every current and future test file
  inherits it; per-fixture overrides still win), with a guard test
  (`tests/test_secret_jail.sh`) asserting a signed write under a jailed
  `HOME` leaves it untouched. No shipped script changed — tests only.

### Changed
- **Self-healing hook install: stale commands are reconciled, not skipped.**
  `maybe_install_hook` detected a prior install by marker substring (the
  script path), so when a release changed the arguments/redirects around
  that path, the old wiring passed the "already present" check forever
  unless a bespoke `migrate_legacy_*` function was hand-written for it
  (0.5.0's `--if-curated` needed one). Now, when the marker matches but the
  stored command differs from the canonical form for that event, the
  installer rewrites it in place — loudly: the old and new command are both
  printed, and the old form additionally survives in the `settings.json`
  backup made at the start of every patch (the "never silently unwire"
  principle from #45/#46 — no silent skip, no silent clobber). A config
  somehow holding both a stale and a current entry is collapsed to one.
  Reconciliation is per event against that event's canonical command, so
  SessionEnd and PreCompact (which share the `write_handoff.sh` marker) are
  handled independently. `maybe_install_statusline` gets the same treatment
  for the "ours but command differs" case, replacing only `.command` so any
  sibling keys you added (e.g. `"padding"`) survive; a statusLine that isn't
  ours remains untouched as before.
- **`migrate_legacy_se_hook` removed** — subsumed by the reconcile above
  (its pre-0.5.0 target forms all contain the script-path marker).
  `migrate_legacy_ss_hook` stays: the pre-0.3.0 inline SessionStart
  one-liner contains no script path, so only the dedicated detector can
  find it. Behavior nuance: the old migrator matched any command containing
  the bare filename `write_handoff.sh`; the reconcile only touches commands
  containing our full installed path, so a user's own wrapper that mentions
  the script some other way is now left alone (consistent with #45/#46).

### Added
- `tests/test_install_reconcile.sh` — covers in-place rewrite with a
  co-located user command, loud old/new output plus retained backup,
  idempotent re-run, per-event SessionEnd/PreCompact scoping, stale+current
  dedupe, and the statusLine ours-stale / not-ours cases.

## [0.10.0] — 2026-07-18

**Re-run `./install.sh` after `git pull`** to pick up one **new installed
file**, `bin/handoff_provenance.sh` — a shared library sourced by the
write/load/ctx-check scripts. Hook commands and permissions are unchanged, so a
`git pull` alone keeps everything working; without the re-run the trusted-rules
tier below just stays inactive and handoffs load exactly as before. Copy-mode
installs re-run `./install.sh` as usual. New env vars: `HANDOFF_SECRET_FILE`,
`HANDOFF_TRUST_DISABLE`, `HANDOFF_FENCES_REINJECT_KB`.

### Added
- **Tiered handoff loading: provenance-gated binding rules (issue #42).** The
  handoff's rules layer — a new marker-wrapped `## Rules` fences section plus
  the user-authored pin — now loads with BINDING framing ("standing working
  rules… these bind until the user lifts them") instead of the blanket
  "reference DATA, do not act" wrapper, but ONLY when provenance verifies:
  the file must be untracked in git (a tracked handoff was clone-delivered)
  AND carry a valid HMAC-SHA256 trailer written by `write_handoff.sh` with a
  per-machine secret (`~/.claude/handoff_secret`, 0600, auto-generated).
  Narrative content — including model-authored Notes — keeps the untrusted
  data framing unconditionally, and any verification failure (tampered/absent
  MAC, tracked file or pin, missing `openssl` — which stays optional,
  `HANDOFF_TRUST_DISABLE=1`) degrades to exactly the previous behavior.
  Because the `/handoff` curation edit invalidates the write-time stamp, the
  skill now finishes with `write_handoff.sh --restamp` (new flag) to re-sign.
  Against decay, the verified rules block is also re-injected: by the
  UserPromptSubmit hook after every `HANDOFF_FENCES_REINJECT_KB` (default
  200) KB of transcript growth, and by the SessionStart hook right after
  compaction (it branches on the hook payload's `source` field; older
  Claude Code versions without the field keep the normal full load).
  `install.sh --doctor` checks the new lib and notes a missing `openssl` as
  an advisory. 105 new tests cover the gate, the negative controls
  (including a clone-delivered pin that embeds its own BIND markers, an
  unbalanced-marker doc, and a relative tracked-pin path), and the
  re-injection cooldown.
- **`--uninstall` now removes the per-machine HMAC secret**, so it stays a
  true inverse and leaves no key material behind. Narrowly scoped: only the
  default `~/.claude/handoff_secret` path, only a regular file (never a
  symlink or directory), and only when the content is exactly the 64-hex
  digest this tool generates — a foreign file at that name, or a custom
  `HANDOFF_SECRET_FILE` location, is reported and left untouched. The
  secret's value is never printed. Existing signed handoffs degrade to
  reference-data framing after removal (nothing breaks; `/handoff` re-signs
  on the next install).

### Fixed
- **Pruning could delete files the user put in `.claude/handoff_history/` or
  `.claude/handoff_backups/` (#46).** Both retention loops selected with a
  loose glob (`handoff_*.md`, `handoff_raw_*.md`) and deleted everything past
  the keep-N cutoff, so a hand-preserved snapshot — naming an archived handoff
  `handoff_2026-01-05_IMPORTANT.md` is a natural thing to do — was silently
  removed once it fell outside the window, with no warning and no backup.
  Retention now only ever considers files this tool generated: history matches
  the exact emitted shape `handoff_<YYYY-MM-DD>_<HHMMSS>[_<N>].md`, and dumps
  must carry the companion `.handoff_raw_<id>.cursor` this hook writes beside
  every dump it creates (the filename alone can't prove ownership — a user's
  `handoff_raw_my_own_archive.md` satisfies the same id charset a real session
  does). Filtering happens *before* the keep-N cut, so foreign files no longer
  consume retention slots. Safe-direction trade-off: one of our dumps whose
  cursor was manually deleted now lingers instead of being removed.
- **Replacing a pre-existing symlink left no durable record of its old target
  (#45).** A regular file in an install path gets a `.bak.<ts>`; a symlink
  pointing at the user's own wiring (a customized fork, a second clone, a
  dotfiles manager) was removed with the old target echoed to stdout only —
  lost the moment it scrolled past, or immediately when the installer ran with
  output redirected. `install.sh` now appends a timestamped record to
  `~/.claude/handoff-install.log` before replacing it. The log is append-only
  by contract: an existing file is added to, never rewritten or truncated, and
  a symlinked log is never written through. Same-target relinks (the ordinary
  re-install) record nothing, and `--uninstall` leaves the log alone. The
  user's own file was never destroyed in either case — this restores
  recoverability of the *wiring*.

## [0.9.0] — 2026-07-18

**settings.json changes — re-run `./install.sh` after `git pull`.** This
release adds two new hook events (`PreCompact`, `PostCompact`), a
`statusLine` command (wired **only if you don't already have one** — an
existing statusLine is never overwritten; the installer prints the manual
step instead), two new permission entries, and two **new installed scripts**
(`bin/handoff_statusline.sh`, `bin/handoff_compact_reset.sh`) that a `git
pull` alone won't symlink. The existing four hook commands are byte-for-byte
unchanged. Everything degrades gracefully on Claude Code versions that lack
the new events/payload fields (see each entry). New env vars:
`HANDOFF_CTX_NO_STATUSLINE`, `HANDOFF_SESSIONEND_SKIP_REASONS`, plus
`HANDOFF_CTX_1M_MODEL_REGEX` from the earlier fix below.

### Added
- **Status line (`bin/handoff_statusline.sh`).** Renders
  `model | ctx N% (usedk/windowk) | handoff: curated/auto/none` and caches
  Claude Code's OWN `context_window_size` / `used_percentage` /
  `current_usage` into `.claude/handoff_backups/.ctx_sl_<session_id>`
  (single key=value file, atomic mv). `total_input_tokens` /
  `total_output_tokens` are deliberately never read — their semantics
  flipped at CC 2.1.132 (cumulative → current) and would be
  confidently-wrong on older builds. No jq → static minimal line, no cache;
  no `context_window` in the payload (pre-2.1.6 CC) → model-only line.
- **ctx-check prefers CC's own numbers.** When the statusline cache is
  present and fresh, `handoff_ctx_check.sh` adopts its window (skipping the
  model-regex / lastModelUsage guesswork that mis-sized 1M-native models)
  and its token count. `HANDOFF_CTX_WINDOW_TOKENS` still beats everything
  (contract unchanged, existing suite passes unmodified); a statusline
  window is never ratcheted; a stale cache (statusline unwired mid-session,
  mtime older than the Stop hook's tokens file) falls back to the previous
  chain; `HANDOFF_CTX_NO_STATUSLINE=1` ignores the cache entirely.
- **Compaction safety net (`PreCompact` + `PostCompact`).** PreCompact runs
  the same `write_handoff.sh --if-curated` command as SessionEnd (no
  matcher — fires on auto AND manual compaction; matcher semantics on older
  CC are unverified and firing on both is correct anyway). PostCompact runs
  new `bin/handoff_compact_reset.sh`, clearing the session's
  `.ctx_*` measurement/flag sidecars (keeping `.ctx_model_`) so the freed
  window is treated as session-start fresh: no stale-number nudge, and the
  once-per-session nudge cap re-arms. PostCompact only exists on CC ≥
  2.1.76; on older builds the entry never fires and behavior is unchanged.
- **Reason-aware SessionEnd safety net.** `write_handoff.sh --if-curated`
  now parses an optional `reason` from the hook payload and skips the write
  for reasons in `HANDOFF_SESSIONEND_SKIP_REASONS` (default `resume` — a
  `/resume` session-switch is a pause, not an ending, and each fire rotated
  placeholder churn through history). Absent/renamed field or missing jq →
  parse yields empty → today's always-write behavior (the guess can only
  add the skip, never subtract the safety net). Curated `/handoff` and
  manual runs never consult the list.

### Changed
- **Un-curated placeholder snapshots are deleted, not archived, on
  rotation.** They carry no curated prose, and with PreCompact the safety
  net can fire several times per session — archiving each one would evict
  curated snapshots from the keep-N history. Curated docs archive exactly
  as before.

### Deferred
- **Stop-payload `last_assistant_message` fallback in `handoff_turn_append.sh`
  (D2).** Evaluated and deliberately not implemented: the payload holds only
  the final assistant text (no user text, tool calls/results, usage, or
  model), so the transcript scan stays mandatory regardless; and a
  payload-derived block for the missing-transcript case creates a
  cursor-duplication hazard (the cursor never advanced, so a reappearing
  transcript would re-capture the same text) that costs more machinery than
  the rarely-rescued content is worth. Recorded as a `DEFERRED(D2)` comment
  at the missing-transcript guard.

### Fixed
- **Context reminders no longer over-report 5x on 1M-native models (Claude 5
  family).** Window auto-detection assumed 1M models always carry a `[1m]`
  suffix in their id; Claude 5 family ids (e.g. `claude-fable-5`) run a 1M
  window with no suffix, so detection resolved 200k and a session at ~9% of
  context was told it had used ~45%. Three-part fix: (1) the Stop hook now
  records the session's model id (from the same last main-chain, usage-bearing
  assistant line the token count comes from) into
  `.claude/handoff_backups/.ctx_model_<session_id>`, and ctx-check sizes the
  window from the session's OWN model rather than guessing from
  `~/.claude.json` lastModelUsage (which remains the fallback when no model is
  recorded yet); (2) the 1M signal is a configurable regex,
  `HANDOFF_CTX_1M_MODEL_REGEX` (default `\[1m\]|claude-(fable|mythos)-`), used
  by both the model-file check and the lastModelUsage fallback, so users can
  extend it when new 1M models ship; (3) a safety ratchet: a MEASURED token
  count above 200k provably cannot fit a 200k window, so ctx-check widens to 1M
  even when detection got it wrong (never on the bytes/4 estimate, which
  overshoots). `HANDOFF_CTX_WINDOW_TOKENS` still overrides everything.

Adversarially-verified audit (2026-07-17) — the high + medium findings landed
as individual fixes:

- **BSD portability (high):** `LC_ALL=C` on the SessionStart defang so an
  invalid UTF-8 byte (e.g. a Latin-1 commit subject in the snapshot) no longer
  makes BSD sed abort mid-emit and silently truncate the loaded context on
  macOS; and the big-dirty-tree SIGPIPE in `snapshot_repo` (thousands of dirty
  paths killed the whole write under pipefail) is guarded.
- **A mid-write failure can no longer consume the previous handoff.**
  `write_handoff.sh` now builds the replacement document fully before rotating
  `handoff_current.md` into history; an abort in between used to leave NO
  current handoff and the next session silently loaded nothing.
- **Malformed `HANDOFF_CTX_THRESHOLD_PCT` / `HANDOFF_CTX_COOLDOWN_KB` no
  longer silently disable the context nudge** — non-numeric or negative values
  fall back to the defaults (40 / 100) instead of aborting the hook.
- **Missing jq is now loud.** It is a runtime dependency of the Stop hook, the
  ctx nudge, and the recover-tail rescue: `install.sh` refuses to install
  without it, `--doctor` and the SessionStart self-check flag it, and
  `handoff_recover_tail.sh` errors instead of emitting a plausible-but-empty
  "recovered tail".
- **An unwritable `.gitignore` no longer kills the hooks.** Both gitignore
  bootstraps warn and continue (like the existing symlink skip) instead of
  aborting the Stop hook / SessionEnd write on every fire.
- **mkdir-lock hardening (macOS/no-flock):** the holder re-touches the lock
  dir during long backlog appends and the stale-reclaim default rose from 60s
  to 300s (`HANDOFF_LOCK_STALE_SECS`), so a live slow fire can't have its lock
  stolen (which interleaved dump content and clobbered the cursor).
- **Volatile-source detection canonicalizes paths.** `install.sh` now matches
  the physical (`pwd -P`) form plus the macOS `/private/tmp`,
  `/private/var/tmp`, and `/var/folders/*` spellings — so a canonical-path or
  TMPDIR-unset install from a temp checkout auto-copies instead of leaving
  issue-#21-style dangling symlinks.
- **SessionStart defang covers tool-conversation spoofing.** Fabricated
  `tool_result` / `tool_use` / `function_calls` / `function_results` /
  `invoke` / `parameter` tags (attributed and `antml:`-namespaced forms
  included) in a committed handoff are neutralized to guillemets like the
  control tags.
- **Docs de-drifted:** the nudge threshold default is documented as 40% (was
  still 50% in three places); `HANDOFF_CTX_MAX_FLAGS` joined the env-var
  reference and the reminder text no longer promises a re-fire the default
  one-nudge cap suppresses; the stale "errors outside a git worktree"
  limitation was replaced with the actual off-git contract;
  `handoff_recover_tail.sh` was added to both repo maps and the manual-install
  steps (five scripts, not four).

## [0.8.5] — 2026-06-14

Docs-only release. Leads the README with a plain-language "In plain terms, it:"
bullet summary — snapshot, auto-load, self-backup, context nudge — plus a one-line
"how you drive it", so a newcomer gets what the tool does before the detailed
three-paths section. (#39)

**No settings.json changes** — hook commands and permissions are unchanged, and
there are no new installed scripts. A `git pull` is sufficient; nothing to re-run.
No behavior change.

### Changed
- **README opens with a plain-language bullet summary.** A four-bullet "In plain
  terms" block plus a one-line "how you drive it" now precede the detailed
  sections, so a human gets the gist first. Docs only; existing sections
  unchanged. (#39)

## [0.8.4] — 2026-06-10

Robustness + reach batch. Three changes: `/handoff-recover` now rescues the final
turn(s) a crash dropped from the raw dump (#34); the context-pressure reminder no
longer over-fires on long/idle sessions (#36); and the hooks now work in projects
that aren't under git at all (#37).

**No settings.json changes are required** — the hook commands and permissions are
unchanged — but two runtime behaviors shift (ctx-check threshold and nag
frequency, see below) and one new env var is recognized (`HANDOFF_CTX_MAX_FLAGS`).
There is also a **new installed script** (`bin/handoff_recover_tail.sh`): symlinked
installs must **re-run `./install.sh`** after `git pull` to link it (a pull alone
won't create the new symlink); copy-mode installs re-run `./install.sh` as usual.
Without it, `/handoff-recover` degrades gracefully (it skips the tail step). Every
change ships with a test; the new git-optional contract is covered end to end.

### Fixed
- **`/handoff-recover` no longer silently loses the last turn before an abrupt
  end.** The raw dump is built turn-by-turn by the Stop hook, which fires *after*
  each turn — so a session killed before its final Stop (OOM, SIGKILL, closed
  terminal) never folds its last exchange into the dump, even though Claude Code
  already wrote it to the transcript JSONL. Recover read only the dump and lost
  it. New `bin/handoff_recover_tail.sh` compares the Stop hook's cursor against
  the JSONL and emits any turns past it (the un-captured tail) for the skill to
  fold into the recovered Notes; it counts lines with `awk NR` so a
  crash-truncated, newline-less final line is rescued rather than dropped. (#34)
- **The context-pressure reminder no longer nags repeatedly on a long or idle
  session.** Once a session crossed the threshold the hook re-flagged every
  ~100KB of transcript growth, so a session left open kept prompting. The flag
  file now appends one line per flag (newline-normalized so a pre-cap
  single-value file can't fuse and undercount) and a per-session cap counts them.
  (#36)

### Changed
- **ctx-check default threshold lowered 50% → 40%.** One earlier nudge gives more
  runway to reach a clean boundary before quality degrades. (#36)
- **One nudge per session by default.** New per-session cap `HANDOFF_CTX_MAX_FLAGS`
  defaults to `1` in "suggest" mode (one gentle nudge, then silence) and `0`
  (uncapped, cooldown-gated) in "act" mode, where an autonomous project keeps
  self-refreshing. Override to taste. (#36)

### Added
- `bin/handoff_recover_tail.sh` — new installed script, wired into
  `install.sh`'s link / chmod / uninstall paths. Not a hook itself (no
  settings.json entry); invoked by the `/handoff-recover` skill. (#34)
- **Git is now optional — handoff works in projects not under git.** The hooks
  anchored on `git rev-parse --show-toplevel` and no-op'd (or, for
  `write_handoff.sh`, errored) outside a git worktree. Every script now falls
  back to `CLAUDE_PROJECT_DIR` (then `$PWD`) when there's no git top — matching
  the resolver `handoff_session_start.sh` already used — so the `.claude/`
  artifacts land where the loader looks. Off-git, `write_handoff.sh` emits a
  "Not a git repository" note instead of a wall of `?`, points the verify block
  at `.claude/` via `ls -la`, and git-gates the `.gitignore` bootstrap. Shipped
  as a `feat` in a patch release by choice. (#37)
- `HANDOFF_CTX_MAX_FLAGS` env var (see **Changed**). (#36)

## [0.8.3] — 2026-06-09

Security + robustness release from a full code & security audit of the hooks.
**No hook-command or permission changes** — a `git pull` refreshes symlinked
installs; copy-mode installs re-run `./install.sh`. Every fix ships with a
regression test verified to fail against the pre-fix code.

The headline issues are **malicious-repo** attacks: the hooks run automatically,
with the user's privileges, in whatever repo Claude Code opens — so a crafted
clone could plant symlinks or a crafted `handoff_current.md`.

### Security
- **Hooks no longer follow planted symlinks on write.** A malicious clone could
  ship `.claude/handoff_backups` (or the dump file) as a symlink — the Stop
  hook's `>>` append would then write the verbatim, secret-bearing transcript
  dump through it to an attacker-chosen path on the first turn. Likewise a
  symlinked `.claude/handoff_current.md` + `HANDOFF_HISTORY_KEEP=0` let the
  `>` write truncate an arbitrary file (e.g. `~/.bashrc`). Both hooks now refuse
  a symlinked `.claude`/backup-dir/dump, drop a planted `handoff_current.md`
  symlink, and `write_handoff.sh` publishes atomically via `mktemp`+`mv -f`. (#25)
- **SessionStart no longer injects unsanitized handoff content into model
  context.** `handoff_current.md` / history snapshots are cat into the next
  session verbatim; a crafted file could smuggle fake `<system-reminder>` /
  `-*-*- ACTION` control structures. Those tags are now defanged to inert
  guillemets and the block is framed as untrusted reference DATA. (#26)
- **`handoff_ctx_check.sh` now validates `session_id`** before interpolating it
  into `.ctx_*` paths, mirroring the Stop hook (the documented guard had only
  ever landed in one of the two scripts). (#31)

### Fixed
- **Stop hook no longer silently produces empty dumps where `perl` is absent**
  (Alpine, minimal containers, some CI). `strip_noise` was a bare `perl` call
  that exited 127 and aborted the hook before the cursor advanced; it now falls
  back to verbatim passthrough. (#27)
- **Stop hook no longer aborts on a trailing user array-message** with no
  tool_result (which froze the cursor and produced duplicate turn dumps). (#27)
- **SessionStart loads the handoff when launched from a subdirectory.** It now
  anchors on the git worktree top like the writer hooks, instead of
  `CLAUDE_PROJECT_DIR`/`$PWD` (which silently no-op'd in monorepo subdirs). (#26)
- **SessionStart placeholder detection is scoped** (matching `write_handoff.sh`),
  so a curated handoff that merely quotes the sentinel no longer triggers a
  spurious `/handoff-recover` banner. (#26)
- **Rotated history snapshots are tightened to `0600`** — a doc left `0644` by a
  pre-0.8.2 version no longer stays world-readable once rotated into history. (#29)
- **`prune_history` is NUL/whitespace-safe.** A crafted history filename in a
  cloned repo could make the old bare `xargs` mis-split or abort the whole
  handoff write; it now uses a `read`/`rm -f --` loop. (#29)
- **A `.gitignore` created by the hooks is `0644`,** not left `0600` by the
  secret-protecting `umask 077`; an existing `.gitignore` is never re-moded. (#29)
- **`install.sh` preserves a symlinked `settings.json`** (dotfiles pattern):
  it resolves to and patches the target instead of replacing the link with a
  plain file. (#30)
- **`install.sh` refuses a valid-JSON-but-non-object `settings.json`** cleanly
  up front instead of hitting a raw jq error mid-patch. (#30)
- **`--uninstall` removes a dangling "ours" symlink** at the install path
  instead of reporting it "already absent" and leaving it. (#30)
- **Install backups no longer collide within the same clock second** (the
  `.bak.<ts>` name now carries the PID), so a rapid second run can't destroy the
  first run's pre-patch backup. (#30)

### Tests
- New regression suites for every fix above (symlink safety, perl-absent
  capture, trailing-array-message, session-start hardening, rotation perms,
  prune safety, install robustness, ctx-check validation).
- **Test harness hardened against vacuous passes** (#28): a `must` setup guard
  surfaces broken fixtures loudly and `mk_repo` now fails loudly instead of
  returning an empty path — the gap that let a broken setup make a later
  assertion trivially true.

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
