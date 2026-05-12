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
│   ├── write_handoff.sh         # the snapshot script (no Claude required)
│   └── handoff_turn_append.sh   # Stop-hook: appends each turn to the running raw-dump
├── skills/handoff/
│   ├── SKILL.md                 # invoked by /handoff
│   └── README.md                # this file
├── settings.json                # SessionStart + SessionEnd + Stop hooks
└── RULES.md                     # self-policing rule (optional)
```

## Install

Easiest: clone the [claude-code-handoff repo](https://github.com/Sting25/claude-code-handoff)
and run `./install.sh` — it symlinks all the files into `~/.claude/`
and patches `~/.claude/settings.json` to add the three hooks plus two
permissions. Edits in the repo flow live without re-installing.

Manual install:

1. Drop `bin/write_handoff.sh` and `bin/handoff_turn_append.sh` into
   `~/.claude/bin/` and `chmod +x` them both.
2. Drop `skills/handoff/SKILL.md` into `~/.claude/skills/handoff/`.
3. Add hooks to `~/.claude/settings.json`:

   ```json
   {
     "hooks": {
       "SessionStart": [{
         "hooks": [{
           "type": "command",
           "command": "f=\"$CLAUDE_PROJECT_DIR/.claude/handoff_current.md\"; if [ -f \"$f\" ]; then echo '## Auto-loaded handoff from previous session'; echo; cat \"$f\"; fi"
         }]
       }],
       "SessionEnd": [{
         "hooks": [{
           "type": "command",
           "command": "bash $HOME/.claude/bin/write_handoff.sh >/dev/null 2>&1 || true"
         }]
       }],
       "Stop": [{
         "hooks": [{
           "type": "command",
           "command": "bash $HOME/.claude/bin/handoff_turn_append.sh 2>/dev/null || true"
         }]
       }]
     },
     "permissions": {
       "allow": [
         "Bash(bash /home/<you>/.claude/bin/write_handoff.sh)",
         "Bash(bash /home/<you>/.claude/bin/handoff_turn_append.sh)"
       ]
     }
   }
   ```

   Adjust the permission paths for your username. The `Stop` hook is
   what makes the raw-dump backup incremental — it fires after every
   assistant turn and appends to
   `.claude/handoff_backups/handoff_raw_<session_id>.md`, keeping only
   the 3 newest such files. This avoids the "context too saturated to
   write a big dump at the end" failure mode.

4. (Optional) Add the self-policing rule to `~/.claude/RULES.md` so
   the assistant offers `/handoff` proactively. Note: Claude can't
   self-measure context %, so the rule triggers on observable signals,
   not fabricated numbers:

   > **Self-policed handoff: boundary + user-signal, never fabricate %.**
   > Two triggers: (a) after a clean boundary (commit lands, track
   > wraps, spec ships), ask "Good handoff moment — want me to run
   > /handoff, or keep going?"; (b) any time the user mentions context,
   > meter, percentage, or "getting long," immediately offer to run
   > /handoff. The user's meter is the source of truth — never estimate
   > the number yourself.

5. First time you invoke `/handoff` in a project, the script
   self-bootstraps `.claude/handoff_current.md` into that project's
   `.gitignore` (the file is regenerated, not source). One-line
   stderr notice the first time; idempotent after.

## Use

- **Manual:** type `/handoff` whenever — when a track closes, when
  your meter is getting tight, before stepping away for the day.
- **Auto-write on session exit:** the `SessionEnd` hook fires the
  script silently. Even unplanned exits leave a snapshot.
- **Auto-load on session start:** the `SessionStart` hook reads the
  handoff into context. Nothing for you to do.
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

# Skip the auto-add of .claude/handoff_current.md to project .gitignore
# Default: unset (bootstrap runs once per project)
export HANDOFF_NO_GITIGNORE_BOOTSTRAP=1
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
  its own session. The skill + self-policing rule together is the
  closest practical pattern; the human-in-the-loop step is "you start
  the next session" (one keystroke).
- **`SessionEnd` hook fires on session exit, not on `/clear`.** If
  you `/clear` to recycle context within the same session, no handoff
  is written. Invoke `/handoff` manually before `/clear` if you need
  the snapshot.
- **The handoff is per-repo.** If you `cd` between repos in one
  session, the handoff captures only the repo where you invoke. For
  cross-repo handoffs, run `/handoff` once in each.
- **The script assumes `git` is on PATH and the cwd is a git
  worktree.** It errors otherwise.

## License

Whatever license your dotfiles use. The author wrote this in a
collaboration with Claude; copy, modify, share freely.
