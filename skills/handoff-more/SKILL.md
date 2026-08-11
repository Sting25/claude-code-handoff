---
name: handoff-more
description: Pull older handoffs from .claude/handoff_history/ into the current session's context. Requires the scripts/hooks installed by this repo's ./install.sh — the history it reads only exists once those are in place. Use when the auto-loaded handoff_current.md is thin (placeholder Notes, missing context the user is referencing), when the user references work from "yesterday" or "the session before this one," or whenever the user explicitly invokes /handoff-more. Reads up to N older snapshots (default 5).
---

# /handoff-more — load older handoffs into context

> **Prerequisite:** this skill reads history that only exists when the
> scripts and hooks from https://github.com/Sting25/claude-code-handoff
> are installed — `write_handoff.sh` is what rotates snapshots into
> `handoff_history/`. That toolchain lives under `~/.claude/bin/`
> (script install) or the plugin's `bin/` (plugin install) and is NOT
> part of this file alone; run `./install.sh` from that repo (or
> install the plugin) once per machine first.

The `SessionStart` hook auto-loads `handoff_current.md` (the most
recent handoff). This skill pulls in the older snapshots that
`write_handoff.sh` rotated into `<repo>/.claude/handoff_history/`
before each new write.

## When to invoke

- **User asks explicitly** (`/handoff-more`, "load more handoff
  context," "what did we do two sessions ago," etc.).
- **Auto-loaded handoff is thin.** If `handoff_current.md` was the
  result of an automatic `SessionEnd` write (no model in the loop to
  add curated Notes), the SessionStart hook already loaded the prior
  one as a fallback. But if the user is referencing decisions or work
  the assistant still can't account for, run this skill to pull
  further back.
- **Continuity gap.** User mentions a track, decision, or artifact you
  have no context on, and the current handoff doesn't reference it.

## Steps

1. List the history dir:
   ```bash
   ls -la <repo-root>/.claude/handoff_history/
   ```
   If the directory is missing or empty, check whether that's "no
   history yet" or "toolchain never installed". Script installs put
   the scripts under `~/.claude/bin/`; plugin installs put them under
   the plugin's `bin/`. `CLAUDE_PLUGIN_ROOT` would name that location,
   but measurement (2026-08-11, plugin-enabled headless session) shows
   the CLI does NOT export it to model-driven Bash calls — the env-var
   check stays only as cheap future-proofing, and in plugin mode the
   cache-glob is the branch that actually resolves:
   ```bash
   hb=""
   if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/bin/write_handoff.sh" ]; then
     hb="${CLAUDE_PLUGIN_ROOT}/bin"
   elif [ -f "$HOME/.claude/bin/write_handoff.sh" ]; then
     hb="$HOME/.claude/bin"
   else
     for d in "$HOME"/.claude/plugins/cache/*/claude-code-handoff/*/bin; do
       [ -f "$d/write_handoff.sh" ] && hb="$d"
     done
   fi
   # env var wins when set (running from that plugin), legacy bin next (existing
   # installs), cache glob last (plugin installed but env var not visible to
   # skill Bash); the loop's last match takes the lexically-highest version dir.
   [ -n "$hb" ] || echo "MISSING: handoff scripts not installed (neither ~/.claude/bin nor a plugin install found)"
   echo "handoff-bin: $hb"
   ```
   (This skill only reads directories — `$hb` isn't invoked elsewhere
   in this file, so there's no cross-call persistence concern here.)
   If it prints MISSING, stop and tell the user to clone
   https://github.com/Sting25/claude-code-handoff and run `./install.sh`
   (or install the plugin) — don't try to substitute for the missing
   toolchain. If the scripts ARE installed, say there's simply no
   history yet and stop — there's nothing to load.

2. Read each retained snapshot, newest first. The default retention
   is 5 (configurable via `HANDOFF_HISTORY_KEEP` in the user's shell),
   so this is normally 1–5 files. Use the `Read` tool on each.

3. Acknowledge in one line that older handoffs are now in context
   (e.g. "Loaded 3 older handoffs from
   `.claude/handoff_history/` — `handoff_2026-05-12_140312.md`,
   `handoff_2026-05-11_180044.md`, `handoff_2026-05-10_223301.md` —
   into context."). Then continue answering whatever the user
   actually asked.

## What NOT to do

- Do not load history files that aren't in `handoff_history/`. The
  raw turn-by-turn dumps under `handoff_backups/` are a different
  artifact (verbose, per-turn, for forensic recovery) — use that
  directly if you need that level of detail, not this skill.
- Do not summarize the loaded handoffs back to the user as a wall of
  text. The point is to put the prose in context, not to recite it.
  One acknowledgement line is enough.
- Do not invoke proactively at every session start. The SessionStart
  hook already handles the "current handoff is thin → also include
  previous" fallback automatically. This skill is for when *that*
  fallback is also insufficient.
