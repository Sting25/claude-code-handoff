# Coding rules

Short rule set. Most discipline is enforced by the linter (`ruff` / `eslint`) and the pre-commit hook — those fail the build or the commit. The rules below are the things that aren't tool-enforceable.

## File size

1. **Max 500 lines per file.** When approaching the limit, extract a focused module. Never raise the limit.

## Structure

2. **No copy-paste logic** — import existing helpers. Duplication invites drift.
3. **Before creating a new file, check for extension candidates.** Search the codebase for existing modules that could absorb the new logic. When you do create, state in the commit or PR body what you considered and why it couldn't extend.
4. **FastAPI endpoints return Pydantic response models**, not raw dicts. Applies if the project uses FastAPI.
5. **SQLAlchemy 2.0 style only** (`Mapped[]`, `mapped_column()`). No `declarative_base` or pre-2.0 patterns. Applies if the project uses SQLAlchemy.
6. **`asyncio.to_thread()` for blocking I/O** in async paths — under the GIL a CPU-bound function moved to a thread still stalls the event loop (the CPython `asyncio.to_thread` docs call this out), so CPU-bound work belongs in a process pool (`loop.run_in_executor` with a `ProcessPoolExecutor`); free-threaded 3.13t+/3.14 builds are the exception. Never block the event loop. `ruff`'s `ASYNC2xx` rules fail the build when a blocking HTTP / file / subprocess call is detected inside an `async def`, so this is now tool-enforced on the Python side (not just advice). *(TypeScript)* Never leave a promise floating — `await` it or handle it explicitly. `eslint`'s `no-floating-promises` / `no-misused-promises` fail the build on the most common silent-async bug; they need type-aware linting (a `tsconfig.json`), which the shipped `eslint.config.js` enables by default.

## Pattern files

Stack-specific deny patterns live in `.forbidden-patterns/*.txt` (one per language — `backend.txt`, `frontend.txt`, `php.txt`, `go.txt`, `rust.txt`, `java.txt`, `kotlin.txt`, `ruby.txt`, `shell.txt` — plus the language-agnostic `secrets.txt`). Add deprecated import paths, old service names, banned API keys, etc. — the hook scans them on every commit and so does CI. Format is `<regex><TAB><description>` per line; each file declares the extensions it scans with a `# scaffold-extensions:` header, so adding a language is just dropping a file. See `forbidden-patterns/README.md` for the full reference.

## Communication

7. **Cite `file:line` when flagging an issue.** "The config is wrong" is vague; "`config.py:43` is wrong because…" is actionable. Applies to code review, bug reports, memory entries, and mid-task observations.

## Testing

8. **Four-category baseline**, picked per stack. Every project ships with all four:
   - **Linter/formatter** — catches sloppy edits before commit
   - **Type-checker** — catches contract drift before runtime
   - **Test runner** — unit + integration tests
   - **Property-based** — edge cases the human writer didn't think of, especially in numeric / spatial / parsing code

   Defaults: Python — `ruff`, `pyright`/`mypy`, `pytest`, `hypothesis`. TypeScript — `eslint`+`prettier`, `tsc`, `vitest`/`jest`, `fast-check`. New stacks pick equivalents and document the choice in the project's `AGENTS.md`.

9. **Don't skip the pre-commit hook (`--no-verify`) unless explicitly asked.** It runs the size/pattern/secret guards plus the linter (`ruff` / `eslint`), and — for TypeScript — `tsc --noEmit` whenever a `tsconfig.json` is present. Wire the rest of your type-checker (`pyright` / `mypy`) into CI per the project's `AGENTS.md`; the type-aware `eslint` config and `tsc` cover the TypeScript side at commit time and in CI.

## Observability

10. **Structured logging library**, picked per stack. Output JSON, not plain text — downstream tools (alerting, dashboards, log search) all depend on parseable structure. Defaults: Python — `structlog`. TypeScript — `pino` or `winston`. New stacks pick equivalents. On Python, `ruff`'s `G`/`LOG` rules fail the build on f-string/`%`/`.format()` formatting inside a log call (it defeats deferred/structured rendering) — pass fields as arguments. The idiomatic structured form `logger.info("event_name", key=val)` is not flagged.

11. **Event names are `snake_case_verbs`**, not prose. Example: `request_received`, `cog_written`, `gpu_lock_acquired`. They must be filterable strings — log handlers, alerting rules, and grep all depend on stable identifiers. Prose like "the request came in fine" is not a log event name.

12. **Bind a request correlation ID to log context** when running multiple services. Prefer the W3C `traceparent` header — it's the cross-service standard and OpenTelemetry SDK middleware propagates it for you; `X-Request-Id` is an acceptable lighter-weight fallback. Either way: echo incoming, generate if missing, bind to log context. Every log line emitted during the request carries the same ID, so a single grep finds the full cross-service trace.

## Versioning

13. **Stable-additive only.** Adding new fields, files, endpoints, or columns is free and doesn't require coordination. Renaming, removing, or changing the type of existing fields requires: (a) a schema-version bump, (b) explicit notice to consumers before the change ships, (c) a deprecation window when feasible. Silent breaking changes are the most expensive kind because they fail downstream, far from the cause.

## Git

See `AGENTS.md` for commit format and Git discipline (no amend, no force-push, no push unless asked).

## What the tooling enforces

See [README.md](./README.md) > "What the tooling enforces" for the full matrix of build-breaking (`ruff` / `eslint`) and commit-breaking (pre-commit hook + CI) checks. Single source of truth — this doc stays focused on the human-readable rules above.

## Project-specific additions

Each project adds its own tech-specific rules in `coding-rules.md` under a "Project-specific" section (library quirks, import-path conventions, architectural constraints). This scaffold file stays universal.
