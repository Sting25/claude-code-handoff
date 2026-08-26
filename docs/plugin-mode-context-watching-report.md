# Why context watching and nudging broke in plugin mode

**Date:** 2026-08-26 · **Version examined:** v0.14.1 (`3112815`) · **Scope:** analysis only, no code changed

---

## Verdict

Context watching was not clobbered by a bad edit during the plugin
conversion. `hooks/hooks.json` is a faithful mirror of the installer's
canonical hooks — `tests/test_plugin_layout.sh` proves that, and it passes.

It broke because **context watching was never carried by hooks alone.** It
stands on four legs, and three of them were delivered by `install.sh`. The
plugin channel does not run `install.sh` — and, for one of those legs,
*cannot*. The plugin ships the leg it can ship and silently drops the rest.

| # | Leg | Provides | Bare-scripts | Plugin |
|---|-----|----------|--------------|--------|
| 1 | `statusLine` wiring | `.ctx_sl_<sid>` — Claude Code's own `context_window_size` + `current_usage` | `install.d/20-settings-patch.sh` wires it (never clobbering a user's own) | **Impossible.** Claude Code honors only `agent` and `subagentStatusLine` from a plugin's settings. Manual paste only |
| 2 | jq preflight | Refuses to install when `jq` is missing (`install.d/40-main.sh:25`) | Enforced | **Bypassed.** `/plugin install` never runs the installer |
| 3 | The six hooks | SessionStart / SessionEnd / PreCompact / PostCompact / Stop / UserPromptSubmit | settings.json | ✅ Shipped identically |
| 4 | `permissions.allow` + `--doctor` | Prompt-free skill Bash calls; install verification | Wired and accurate | **Dropped and actively wrong.** Perms hardcode `$HOME/.claude/bin/...`; doctor reports a healthy plugin install as 8 broken hooks (#64) |

---

## The amplifier: one missing file silences the whole feature

`bin/handoff_ctx_check.sh:209`

```bash
[[ -f "$size_file" ]] || exit 0
```

`$size_file` is `.ctx_<session_id>`, written **only** by the Stop hook. The
gate is deliberate and commented — the cooldown ledger is byte-denominated,
so the author refused to let statusline data alone activate nudging:

> *"Deliberately still gated on the Stop hook's size file even when
> statusline data exists: the cooldown ledger below is byte-denominated, so
> statusline data alone (Stop hook broken/uninstalled) must not activate
> nudging."*

The consequence is that the nudge has **no independent path**. Measured on a
scratch project:

| Condition | Result |
|---|---|
| `.ctx_sl_*` says 180 000 / 200 000 tokens (90 %), `.ctx_<sid>` **absent** | `exit 0`, **0 bytes of output** |
| Same, `.ctx_<sid>` present | nudge fires, "~90 % of a 200000-token window" |

At 90 % context, with a perfect statusline cache in hand, the tool says
nothing. Combine that with the hook wiring — every command ends
`2>/dev/null || true` — and any Stop-hook failure removes context watching
**completely and without a single diagnostic line.**

---

## The most likely proximate cause of #67 — and it reproduces

Issue #67's signature is unusual: *SessionStart fires, Stop and
UserPromptSubmit do not.* That asymmetry is not arbitrary. It is exactly
what a missing `jq` produces, because the three scripts treat `jq`
differently:

| Script | jq handling | Behavior with jq off PATH |
|---|---|---|
| `handoff_session_start.sh` | Parses its payload with `sed`; **jq-free by contract** | `exit 0`, handoff loads normally |
| `handoff_turn_append.sh:36-37` | `jq -r ... <<<"$payload"` — **unguarded**, under `set -euo pipefail` | `exit 127`, **no `.ctx_*`, no raw dump** |
| `handoff_ctx_check.sh:124` | `jq ... 2>/dev/null \|\| true` | empty `session_id` → `exit 0`, **silent** |

Reproduced in a clean project with a jq-less PATH:

```
clean project: no backups dir yet -> absent
after Stop hook (no jq): .ctx_ file -> ABSENT
                          raw dump -> ABSENT
control, same call WITH jq:
                         .ctx_ file -> written
                          raw dump -> written

SessionStart hook (no jq): exit=0  loaded_handoff=yes
```

And as the plugin actually wires it:

```
$ ... | bash handoff_turn_append.sh 2>/dev/null || true
visible exit=0     # the hook reports success either way
```

This failure mode is already known to the project. The header of
`tests/test_jq_missing.sh` says it outright:

> *"jq going missing used to disable the Stop hook, the ctx nudge, and the
> recover-tail rescue SILENTLY (every call site is wired `|| true`), while
> install.sh still printed 'done'…"*

The remediation that closed it hardened `install.sh`, `--doctor`,
`handoff_session_start.sh` and `handoff_recover_tail.sh`. It did **not**
harden `handoff_turn_append.sh` or `handoff_ctx_check.sh` — the installer's
refusal was accepted as the gate. **Leg 2 in the table above is that gate,
and plugin mode walks straight past it.**

### Honest caveat

This is the most parsimonious explanation for #67's asymmetry, not a proven
diagnosis for that machine. The reporter has `/usr/bin/jq`, which is present
in essentially any PATH, so jq-absence is unlikely to be *their* trigger —
though the desktop app launches hook subprocesses with a GUI PATH rather
than a login-shell PATH, and their `flock` does live at
`/opt/homebrew/bin`. Other candidates that fit the same signature and cannot
be ruled out from the repo alone:

- Desktop-app plugin-hook dispatch differing per event (the reporter's own
  suspicion).
- The reporter's personal `UserPromptSubmit` hook in `settings.json`
  shadowing the plugin's — explains the ctx check, **not** the missing Stop
  dump, since no user-level `Stop` hook exists there.
- A transcript path the Stop payload names but the hook cannot stat
  (`handoff_turn_append.sh:57` exits 0 on `[[ ! -f "$transcript_path" ]]`).

**What would settle it in one session:** temporarily rewire the plugin's Stop
command to `bash "${CLAUDE_PLUGIN_ROOT}/bin/handoff_turn_append.sh"
2>>/tmp/handoff-stop.log; echo "$? $(date)" >>/tmp/handoff-stop.log` — i.e.
drop the `2>/dev/null || true` that is destroying the evidence. An empty log
means the hook never fired (dispatch); `127` means a missing binary; `0` with
no dump means an internal guard.

---

## Second-order: even a fully working plugin install watches context worse

With leg 1 unavailable, window detection falls back to the model-id regex
`\[1m\]|claude-(fable|mythos)-`:

| Model id | Resolves to |
|---|---|
| `claude-fable-5` | 1M |
| `claude-opus-4-7[1m]` | 1M |
| `claude-opus-5` | **200k** |
| `claude-sonnet-5` | **200k** |

That regex is a hand-maintained enumeration; it goes stale by construction,
and the statusline cache exists precisely because it already broke once
(`c0faf38`: a 5× over-report of usage on 1M-native ids). Plugin mode cannot
have the durable fix and is permanently back on the fragile one. The README
records this, but files it under *"Status line (optional)"* — which
understates it: for plugin users the statusline is the only accurate context
signal there is.

---

## Open issues — verified

All five open issues were checked against the code at `3112815`.

| # | Title | Verdict | Evidence |
|---|---|---|---|
| **67** | Plugin mode: Stop + UserPromptSubmit hooks never fire | **Confirmed as a real failure class; root cause not proven for the reporting machine** | Asymmetry reproduced exactly via jq-absence (above). Note: the issue body cites "#65 (statusLine unset)" — that is **#64**; #65 is the HMAC secret issue |
| **66** | Generated handoff header hardcodes bare-scripts paths | **Confirmed, exactly as filed** | `bin/write_handoff.sh:1095-1097` is an unconditional heredoc naming `~/.claude/bin/write_handoff.sh` and `~/.claude/settings.json`. No mode detection anywhere in the writer |
| **65** | Bare→plugin migration loses the HMAC secret | **Confirmed, exactly as filed** | `remove_secret_if_ours()` (`install.d/10-symlinks.sh:245-275`) `rm -f`s the secret with no opt-out. Its own printed advice ("re-installing … re-signs them") describes returning to bare-scripts — not the migration the user is performing |
| **64** | doctor reports plugin-only install as 8 broken hooks | **Confirmed — reproduced verbatim** | Ran `--doctor` against a synthetic plugin-only home: 8 `MISSING` lines, `statusLine unset (re-run ./install.sh to wire it)`, `plugin install detected … nothing to do here`, then `8 hook(s) broken or missing` and **exit 1**. Both remediation hints steer the user into the documented dual-mode trap |
| **63** | Cross-session overwrite guard | **Open by design; unaffected by the plugin work** | Feature request, not a regression. Independent of everything above |

**Issues 64, 65, 66 and 67 are all the same story:** each is a place where
the codebase assumes the bare-scripts channel. They are not four unrelated
bugs; they are four symptoms of the plugin channel having been added beside
the installer rather than as a peer to it.

### Test suite

`tests/run.sh` — 1 failing check, environment-caused, not a regression:
`test_fences_reinject.sh` → *"flag not created when unwritable"*. The test
makes a directory unwritable with `chmod`; this container runs as uid 0, and
root ignores write permissions. Everything else passes, including all 65
context-check assertions (`test_ctx_check.sh`, `test_ctx_check_statusline.sh`)
and `test_plugin_layout.sh`.

---

## Recommendations

Ordered by ratio of harm removed to effort. No code was written for this
report.

1. **Make the two silent hooks loud (closes the whole class).** Give
   `handoff_turn_append.sh` and `handoff_ctx_check.sh` the `command -v jq`
   preflight that `session_start` and `recover_tail` already have, and have
   them emit one visible line when the dependency is missing. Today the
   installer is the only thing that ever says this, and plugin users never
   run it.

2. **Break the single point of failure at `handoff_ctx_check.sh:209`.** When
   a fresh `.ctx_sl_*` cache exists but `.ctx_<sid>` does not, nudge from the
   statusline data and denominate the cooldown in tokens instead of bytes.
   The current gate trades a working nudge for ledger tidiness.

3. **Detect the dead Stop hook and say so.** #67 suggests this and it is the
   right instinct: if the ctx check sees several prompts in a session with no
   `.ctx_<sid>` ever appearing, emit one `<system-reminder>` saying the
   per-turn backup is not running. The user finds out mid-session instead of
   at `/handoff` time.

4. **Fix `--doctor` for plugin mode (#64).** Plugin detected + no bare-scripts
   artifacts = healthy: report the mode, skip the `MISSING` lines, **exit 0**,
   and never advise `re-run ./install.sh` — that advice manufactures the
   dual-mode state the README warns against. Then have it check what actually
   matters in plugin mode: is `jq` on PATH, is `statusLine` wired to the
   plugin's script, are `.ctx_*` files appearing.

5. **`--uninstall --keep-secret`, or keep by default and delete on `--purge`
   (#65).** The secret is per-machine identity, not per-channel state. A
   one-line nudge in the current output covers most of the harm immediately.

6. **Mode-aware handoff header (#66).** The writer already knows its own path
   via `BASH_SOURCE[0]`; a test against `plugins/cache/` picks the wording and
   makes the install channel visible in every handoff — the exact fact that was
   invisible in the incident that issue describes.

7. **Promote the statusline paste out of "optional".** For plugin installs it
   is the only accurate context signal. Consider printing it at SessionStart
   once, when plugin mode is detected and no `.ctx_sl_*` has ever been written.
