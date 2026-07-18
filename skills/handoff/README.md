# /handoff — auto-snapshot session state for clean session restarts

A user-wide Claude Code skill that solves "context window fills up
mid-task and the next session starts blind." Invoke `/handoff` at any
clean boundary (commit lands, track wraps, your meter is getting tight)
— it writes a structured snapshot of the current repo's state, the next
session reads it on startup, and nothing important gets lost across the
restart.

## What it does

When you run `/handoff`:

1. Snapshots the current git repo: HEAD, branch, recent commits,
   working-tree state.
2. **Optional:** if you've configured a sibling "substrate" repo
   (`HANDOFF_SUBSTRATE_NAME` env var — useful for shared decisions /
   RFCs / cross-project coordination repos), snapshots that too.
3. Lists in-flight (untracked / modified) `.md` files under the
   configured directories (default: `docs/`; set `HANDOFF_INFLIGHT_DIRS`
   to add more, e.g. `"docs design rfcs"`).
4. Writes everything to `<repo>/.claude/handoff_current.md`.
5. Prompts the assistant to append a `## Notes from this session`
   prose block capturing decisions, in-flight tracks, open questions —
   the things git can't see.
6. Prints a loud, deliberate `-*-*-` banner telling you to start a new
   session.

When you start a new session in the same repo, the `SessionStart` hook
loads `<repo>/.claude/handoff_current.md` automatically as context. No
manual copy-paste, no kickoff prompt to remember.

## Components

```
~/.claude/
├── bin/
│   ├── write_handoff.sh           # the snapshot script (no Claude required); rotates history
│   ├── handoff_session_start.sh   # SessionStart hook body: cats current handoff + history-pointer
│   ├── handoff_turn_append.sh     # Stop hook: per-turn raw dump + records transcript size
│   └── handoff_ctx_check.sh       # UserPromptSubmit hook: flags /handoff past threshold
├── skills/
│   ├── handoff/
│   │   ├── SKILL.md               # invoked by /handoff
│   │   └── README.md              # this file
│   ├── handoff-more/
│   │   └── SKILL.md               # /handoff-more: load older handoffs from history/ into context
│   └── handoff-recover/
│       └── SKILL.md               # /handoff-recover: reconstruct a handoff when the prior session didn't run one
├── settings.json                  # SessionStart + SessionEnd + Stop + UserPromptSubmit hooks
└── RULES.md                       # self-policing rule (optional)
```

## Install

Easiest: clone the [claude-code-handoff repo](https://github.com/Sting25/claude-code-handoff)
and run `./install.sh` — it symlinks all the files into `~/.claude/`
and patches `~/.claude/settings.json` to add the four hooks plus four
permissions. Edits in the repo flow live without re-installing.

Manual install:

1. Drop `bin/write_handoff.sh`, `bin/handoff_turn_append.sh`,
   `bin/handoff_ctx_check.sh`, and `bin/handoff_session_start.sh` into
   `~/.claude/bin/` and `chmod +x` all four.
2. Drop `skills/handoff/SKILL.md`, `skills/handoff-more/SKILL.md`, and
   `skills/handoff-recover/SKILL.md` into the matching
   `~/.claude/skills/<name>/` directories.
3. Add hooks to `~/.claude/settings.json`:

   ```json
   {
     "hooks": {
       "SessionStart": [{
         "hooks": [{
           "type": "command",
           "command": "bash $HOME/.claude/bin/handoff_session_start.sh 2>/dev/null || true"
         }]
       }],
       "SessionEnd": [{
         "hooks": [{
           "type": "command",
           "command": "bash $HOME/.claude/bin/write_handoff.sh --if-curated >/dev/null 2>&1 || true"
         }]
       }],
       "Stop": [{
         "hooks": [{
           "type": "command",
           "command": "bash $HOME/.claude/bin/handoff_turn_append.sh 2>/dev/null || true"
         }]
       }],
       "UserPromptSubmit": [{
         "hooks": [{
           "type": "command",
           "command": "bash $HOME/.claude/bin/handoff_ctx_check.sh 2>/dev/null || true"
         }]
       }]
     },
     "permissions": {
       "allow": [
         "Bash(bash /home/<you>/.claude/bin/write_handoff.sh)",
         "Bash(bash /home/<you>/.claude/bin/handoff_turn_append.sh)",
         "Bash(bash /home/<you>/.claude/bin/handoff_ctx_check.sh)",
         "Bash(bash /home/<you>/.claude/bin/handoff_session_start.sh)"
       ]
     }
   }
   ```

   Adjust the permission paths for your username. Hook roles:
   - **`SessionStart`** runs `handoff_session_start.sh`, which cats
     `.claude/handoff_current.md` and — if it has the unedited Notes
     placeholder (auto-write, no /handoff was run) — also cats the
     most-recent file from `.claude/handoff_history/` so the new
     session has curated prose from the session before that. Adds a
     one-line pointer to the history dir when entries exist.
   - **`Stop`** makes the raw-dump backup incremental — fires after
     every assistant turn, appends to
     `.claude/handoff_backups/handoff_raw_<session_id>.md`, prunes to
     the 3 newest. Also records three context-usage measurements: the
     real token count from the latest assistant turn's `usage` block
     into `.ctx_tokens_<session_id>` (sum of input + cache_read +
     cache_creation, same number `/context` reports), that turn's
     model id into `.ctx_model_<session_id>` (so the window can be
     sized from the session's own model), and the
     transcript JSONL byte size into `.ctx_<session_id>` as a fallback.
   - **`UserPromptSubmit`** reads those files on the next prompt and,
     past a configurable threshold (default 40% of the context
     window — auto-detected as 1M tokens if the session's recorded
     model matches the 1M-model regex (`[1m]` suffix or 1M-native
     Claude 5 family id; see `HANDOFF_CTX_1M_MODEL_REGEX`), else 200k,
     probing `~/.claude.json` when no model is recorded), injects a
     `<system-reminder>` telling the assistant to flag a `/handoff`
     moment passively. The signal is the actual token count, not an
     estimate — same precision as `/context`.

4. (Optional) Add the self-policing rule to `~/.claude/RULES.md` so
   the assistant offers `/handoff` proactively. Three real triggers,
   never a fabricated percentage:

   > **Self-policed handoff: boundary + user-signal + size-signal,
   > never fabricate %.** Three triggers: (a) after a clean boundary
   > (commit lands, track wraps, spec ships), ask "Good handoff
   > moment — want me to run /handoff, or keep going?"; (b) any time
   > the user mentions context, meter, percentage, or "getting long,"
   > immediately offer to run /handoff; (c) when the
   > `handoff_ctx_check.sh` UserPromptSubmit hook injects its
   > `<system-reminder>` (real transcript-size measurement crossed
   > the threshold), surface it as a one-line passive mention — no
   > question mark, no "want me to?" — and continue with the user's
   > prompt. The user's meter is still the source of truth for (a)
   > and (b); the hook is the only legitimate numeric signal.

5. First time you invoke `/handoff` in a project, the script
   self-bootstraps `.claude/handoff_current.md` into that project's
   `.gitignore` (the file is regenerated, not source). One-line
   stderr notice the first time; idempotent after.

## Use

The two write paths capture different things:

- **`/handoff` (manual, preferred):** writes the git snapshot AND
  asks the assistant to append a "Notes from this session" prose
  block — decisions, open questions, "next session should start with
  X." This is the only path that captures intent. Practical rule of
  thumb: invoke at 30-50% context remaining, not at 5% — quality
  degrades well before the meter runs out, and you want the
  reflection to happen while the model is still sharp.
- **`SessionEnd` hook (automatic, safety net):** fires `write_handoff.sh`
  silently on clean session exit (`/exit`, Ctrl-D, etc.). Captures
  git state only — the "Notes from this session" block stays as a
  placeholder because no model is in the loop. Doesn't fire on
  SIGKILL or a closed terminal; the `Stop` hook's per-turn raw-dump
  backup covers that case.

The read path is the same for both:

- **Auto-load on session start:** the `SessionStart` hook reads
  `.claude/handoff_current.md` into context. Nothing for you to do.
- **Self-policing:** with the optional rule installed, the assistant
  flags context-pressure and offers to run the skill.

## Customize

All customization is via env vars set in your shell rc (e.g. `~/.bashrc`,
`~/.zshrc`). The shipped script ships generic — defaults work in any
single-repo project with a `docs/` directory.

### Env vars

```bash
# In-flight directories to scan for untracked / modified .md files
# Default: "docs"
export HANDOFF_INFLIGHT_DIRS="docs design rfcs proposals"

# Optional: name of a sibling git repo to also snapshot
# (useful if you have a shared decisions / RFCs / monorepo-substrate
# repo that lives at the same path level as your project repos)
# Default: empty (skip)
export HANDOFF_SUBSTRATE_NAME="_shared"

# Subdirs in the substrate to scan for in-flight .md
# Default: empty
export HANDOFF_SUBSTRATE_INFLIGHT_DIRS="rfcs proposals"

# Skip the auto-add of .claude/handoff_current.md and
# .claude/handoff_history/ to project .gitignore.
# Default: unset (bootstrap runs once per project)
export HANDOFF_NO_GITIGNORE_BOOTSTRAP=1

# Number of older handoffs to retain in .claude/handoff_history/.
# Each /handoff or SessionEnd auto-write rotates the previous
# handoff_current.md into the history dir, then prunes to the newest N.
# Default: 5. Set to 0 to disable retention (overwrite-in-place like
# pre-0.3.0). Each handoff is a few KB, so raising this further is
# cheap if you want a sibling re-entering the repo weeks later to be
# able to read back deeper than the last few sessions.
export HANDOFF_HISTORY_KEEP=5

# Path to a pinned-context file injected verbatim at the top of every
# handoff (read-only — the script never rotates or regenerates it, so it
# survives across sessions until you edit it). Default:
# .claude/handoff_pinned.md (auto-gitignored on first write when inside
# the repo). Inert when the file is absent.
export HANDOFF_PINNED_FILE=.claude/handoff_pinned.md

# Path to a system log the handoff-time nudge watches. When this session's
# commits look system-level (path/subject heuristic) but none touched this
# file, the handoff adds a ⚠️ nudge. Default: SYSTEM_LOG.md at repo root.
# Inert when the file is absent.
export HANDOFF_SYSTEMLOG_FILE=SYSTEM_LOG.md

# Disable the SessionStart auto-include of the most-recent history
# entry when handoff_current.md has placeholder-only Notes.
# Default: unset (fallback enabled).
export HANDOFF_SS_DISABLE_FALLBACK=1

# Disable the SessionStart "ACTION: RUN /handoff-recover" banner that
# fires when handoff_current.md has placeholder-only Notes (previous
# session ended without /handoff). Default: unset (banner enabled).
export HANDOFF_SS_DISABLE_RECOVER=1

# --- Context-usage system-reminder hook (handoff_ctx_check.sh) ---

# Total context budget the threshold is calculated against (tokens).
# Default: auto-detected — if the session's recorded model
# (.ctx_model_<session_id>, written by the Stop hook) matches the
# 1M-model regex below, defaults to 1000000; a recorded non-matching
# model means 200000; with no recorded model yet, ~/.claude.json's
# lastModelUsage is probed against the same regex. Set explicitly to
# override the auto-detection (e.g. to force 1M before any model has
# been recorded, or to force 200k while testing on a 1M tier).
export HANDOFF_CTX_WINDOW_TOKENS=200000

# POSIX ERE matching model ids known to run a 1M-token context window.
# Default: '\[1m\]|claude-(fable|mythos)-' — the `[1m]` beta suffix,
# plus Claude 5 family ids which are 1M-native without any suffix.
# Extend when new 1M models ship. (A measured token count above 200k
# also ratchets the window to 1M regardless, since a 200k window
# provably can't hold it.)
export HANDOFF_CTX_1M_MODEL_REGEX='\[1m\]|claude-(fable|mythos)-'

# Percent of the window at which the reminder fires.
# Default: 40 — fire at 40% used (lowered from 50 in 0.8.4). Drop to 30
# for a more conservative nudge, raise (e.g. 60) if 40% feels too eager.
export HANDOFF_CTX_THRESHOLD_PCT=40

# Transcript growth (in KB) required between consecutive reminders.
# Default: 100 — once the hook has flagged, it won't flag again until
# the transcript JSONL has grown another 100KB. Prevents nagging on
# every turn after the threshold trips. The first crossing always
# fires; the cooldown only spaces RE-flags, and re-flags only exist at
# all when HANDOFF_CTX_MAX_FLAGS (below) allows them — with the default
# suggest-mode cap of 1 there is nothing for the cooldown to gate.
export HANDOFF_CTX_COOLDOWN_KB=100

# Hard cap on how many times a single session flags, regardless of
# growth. Default: 1 in "suggest" mode (one nudge per session, then
# silence — a long or idle session won't keep nagging; added in 0.8.4),
# 0 (= unlimited, gated only by the cooldown) in "act" mode, where the
# assistant is expected to keep refreshing its own context. Set 0 to
# restore the pre-0.8.4 cooldown-spaced repeating behavior; set N>1 to
# allow up to N cooldown-spaced nudges.
export HANDOFF_CTX_MAX_FLAGS=1

# Reminder behavior when the threshold trips. "suggest" (default) emits a
# passive system-reminder for the assistant to flag a /handoff moment to
# you. "act" switches to model-directed text — the assistant wraps up the
# current step and invokes /handoff itself without asking. Pairs well with
# a lower HANDOFF_CTX_THRESHOLD_PCT (~30) so it has runway.
export HANDOFF_CTX_REMINDER_MODE=suggest
```

### Substrate pattern

A "substrate" is a sibling git repo that holds cross-project state
(shared decisions docs, RFCs you want every project to see, coordination
ASKs between teams). The skill snapshots both the current repo AND the
substrate so the next session sees both pictures at once. If you don't
have a substrate repo, leave `HANDOFF_SUBSTRATE_NAME` unset; the skill
just skips that section.

### Self-policing triggers (RULES.md or SKILL.md)

Default: trigger on (a) clean boundaries after meaningful work and
(b) any user signal about context pressure. To change behavior — e.g.
"only suggest at end-of-day," "ask after every commit no matter how
small," etc. — edit the rule in your `RULES.md`. The assistant
follows what you write there.

### Banner style (SKILL.md)

The `-*-*-` border is intentionally loud. To soften (or sharpen), edit
the banner block in `SKILL.md`. Note that the skill explicitly
instructs the assistant NOT to soften it on its own — you have to edit
the spec.

### Skip `.gitignore` auto-bootstrap

Set `HANDOFF_NO_GITIGNORE_BOOTSTRAP=1` in your shell env. The script
won't touch `.gitignore`; you handle ignoring the artifact yourself
(global ignore at `~/.config/git/ignore` works too).

### Canonical handoff path

Default: `<repo>/.claude/handoff_current.md`. To change, edit
`handoff_relpath` and `handoff_path` near the top of the script — but
keep it under `.claude/` so it sits with other Claude artifacts.

### Disable the auto-loaded label

The SessionStart hook prepends `## Auto-loaded handoff from previous
session` so the assistant knows what it's reading. To omit, edit the
hook command in `settings.json` to drop the `echo` lines.

## Limitations (worth knowing)

- **Claude Code can't actually force session restart at a context
  threshold.** No hook event fires on context %, and Claude can't end
  its own session. The skill + self-policing rule + size-signal
  reminder together is the closest practical pattern; the
  human-in-the-loop step is "you start the next session" (one keystroke).
- **Context-usage signal is the real token count, not an estimate.**
  Since 0.4.0, the hook reads `usage.input_tokens +
  cache_read_input_tokens + cache_creation_input_tokens` from the
  latest assistant turn — same number Claude Code's `/context`
  shows. The byte-size estimate is kept only as a fallback for the
  first prompt of a fresh session before any Stop hook has fired,
  or for older installs that haven't pulled the updated turn-append
  script. Tune `HANDOFF_CTX_THRESHOLD_PCT` if 40% fires too eagerly
  or too late for your workloads.
- **`SessionEnd` hook fires on session exit, not on `/clear`.** If
  you `/clear` to recycle context within the same session, no handoff
  is written. Invoke `/handoff` manually before `/clear` if you need
  the snapshot.
- **The handoff is per-repo.** If you `cd` between repos in one
  session, the handoff captures only the repo where you invoke. For
  cross-repo handoffs, run `/handoff` once in each.
- **Git is optional (since 0.8.4).** Outside a git worktree (or with
  no `git` on PATH) the script anchors on `CLAUDE_PROJECT_DIR` (falling
  back to the cwd) and omits the git-only sections — the commit/branch
  snapshot, the `.gitignore` bootstrap, and the git-based verify block.
  Everything else (rotation, history, notes, the hooks) works the same.

## License

Whatever license your dotfiles use. The author wrote this in a
collaboration with Claude; copy, modify, share freely.
