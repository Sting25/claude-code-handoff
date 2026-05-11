# handoff

Portable, user-wide Claude Code skill for snapshotting session state at
clean boundaries. The next session auto-loads the snapshot, so context
never gets lost across a restart.

This repo is the canonical source for the skill. Clone it on any machine
and run `install.sh` to symlink it into `~/.claude/`.

For what the skill actually does, see [`skills/handoff/README.md`](skills/handoff/README.md).

## Layout

```
.
├── bin/
│   ├── write_handoff.sh        # snapshot script (called by skill + SessionEnd hook)
│   └── handoff_turn_append.sh  # Stop-hook: appends each turn to the running raw-dump
├── skills/
│   └── handoff/
│       ├── SKILL.md            # /handoff slash command spec
│       └── README.md           # user-facing docs for the skill
├── install.sh                  # symlink installer
└── README.md                   # this file
```

Symlink install means edits made here are live immediately — no
re-install step. Pulling this repo on a new machine + `./install.sh` is
the whole setup.

## Install

```bash
git clone git@github.com:Sting25/handoff.git ~/code/handoff   # or wherever
cd ~/code/handoff
./install.sh
```

Then patch `~/.claude/settings.json` with the hooks + permission below.

### settings.json snippet

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
      "Bash(bash /home/YOU/.claude/bin/write_handoff.sh)",
      "Bash(bash /home/YOU/.claude/bin/handoff_turn_append.sh)"
    ]
  }
}
```

Replace `YOU` with your username in the permission entries.

The three hooks:

- **`SessionStart`** — loads `.claude/handoff_current.md` into the new session.
- **`SessionEnd`** — silently writes a snapshot on session exit.
- **`Stop`** — fires after every assistant turn; appends a formatted turn block to `.claude/handoff_backups/handoff_raw_<session_id>.md`. This is the incremental raw-dump backup. The hook strips recurring noise tags (`<system-reminder>`, `<command-*>`, etc.) and keeps only the 3 newest dump files in the directory.

## Uninstall

```bash
rm ~/.claude/bin/write_handoff.sh
rm -r ~/.claude/skills/handoff
```

(Only removes the symlinks — the repo is untouched.) Then remove the
hook + permission entries from `~/.claude/settings.json`.

## Develop

Edit files in this repo. Because `install.sh` symlinks rather than
copies, changes are live in the next Claude Code session. Commit and
push when you're happy with them; pull on other machines to update.
