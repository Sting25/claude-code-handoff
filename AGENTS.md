# AGENTS.md

Instructions for AI coding agents working in this repo. `AGENTS.md` is an open cross-tool standard (see [agents.md](https://agents.md)) read natively by Cursor, Aider, Codex, and others; the standard specifies nested `AGENTS.md` files with closest-file-wins precedence. For Claude Code, a thin `CLAUDE.md` pointer is installed alongside this file. Copy to your project root as `AGENTS.md` and edit the **Project** section.

## Coding rules

See [`coding-rules.md`](./coding-rules.md), `ruff.toml`, and `eslint.config.js`. Tool-enforced on every commit via `.githooks/pre-commit` and on every PR via `.github/workflows/lint.yml`.

The file-size ceiling (500 lines) is non-negotiable — never raise it.

## Checks

The same checks CI runs — pass these locally and you pass the PR gate. Run them
against **staged** content (stage your work first, or run the
`.githooks/lib/check-*` scripts directly — the hook scans the index, not the
working tree):

```sh
ruff check .                       # Python  (when ruff.toml / pyproject.toml present)
npx eslint . && npx tsc --noEmit   # TS/JS   (tsc when tsconfig.json present)
git hook run pre-commit            # size / pattern / secret / hygiene / filename guards
```

## Operational rules

See [`operational-rules.md`](./operational-rules.md) for process, collaboration, and judgment patterns extracted from real incidents — pre-flight checks before long jobs, smoke at the smallest scale that exercises the full path, "agent reports measurements / user calls done", scope discipline, surfacing uncertainty rather than guessing, and (under **Model economics**) the session-start delegate/stay-in-window mode check plus the Haiku → Sonnet → Opus model ladder for delegated work. Not tool-enforceable; meant to be skimmed before non-trivial work.

## Git discipline

- **Never `--amend` a commit that has been pushed.** Amending public history forces everyone else to reset.
- **Never `push --force` or `push --force-with-lease`** without explicit instruction for this specific push. On `main` / `master`, refuse even with instruction — ask first.
- **Never `git commit --no-verify`.** The pre-commit hook is the enforcement layer; bypassing it defeats the whole scaffold. If the hook is wrong, fix the hook.
- **Never push unless asked.** Committing is local and reversible; pushing is not. Wait for explicit "push it" / "open a PR" before `git push`.
- **Never `reset --hard`, `checkout .`, or `clean -fd`** on a dirty tree without confirming — those destroy uncommitted work silently.
- **One commit per logical change.** Don't bundle "fix bug + rename vars + add feature" into one commit; split them.
- **Use `git worktree` for parallel agent sessions.** Two agents working in the same checkout will overwrite each other. `git worktree add ../<repo>-<feature> -b <feature>` gives each session an isolated working tree on its own branch.

## Commit message format

```
<type>: <imperative summary, <=72 chars>

<optional body: why, not what — the diff shows what>
<optional: "Considered extending X but Y" for new files, per coding-rules.md rule 3>
```

Types: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`, `perf`.

## When creating a new file

Per `coding-rules.md` rule 3: search the codebase for an existing module that could absorb the logic. In the commit body, state what you considered and why extending wasn't viable. This is the single best defense against codebase sprawl.

## Project

- Stack: pure Bash (must run on bash 3.2.57 / macOS default; BSD *and* GNU coreutils/awk).
- Entry points: `install.sh` (curl|bash single-stream installer — must stay self-contained),
  `bin/write_handoff.sh` (writer; single file BY DESIGN — do not split, see `.scaffold.toml`),
  `bin/handoff_session_start.sh` (loader), `bin/handoff_provenance.sh` (sourced HMAC lib).
- Tests: `HANDOFF_TESTS_NO_SKIP=1 bash tests/run.sh` — run in the FOREGROUND (background
  runs stall subagents). Lint: `shellcheck bin/*.sh install.sh tests/*.sh`.
- Gotchas: `git stash` is shared across worktrees — never stash while parallel agents run;
  exit codes from `mv -n` are not portable (key on "did the source disappear");
  GNU vs BSD awk NUL handling differs; CI's shellcheck names some checks differently
  (SC2317 vs SC2329) — suppress both.
