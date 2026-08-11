# install.sh split — v0.14.0 design

> Status: PROPOSED design note, written 2026-08-10 during the v0.13.0 release
> stabilization. Implementation is v0.14.0 work — do NOT land any of this on
> `release/v0.13.0`. `bin/write_handoff.sh` is explicitly EXCLUDED from any
> split by user decision (see `.scaffold.toml`).

Two load-bearing findings shaped this plan:

- **`.scaffold.toml` already anticipates this work.** It carries a committed
  override (`[size] "install.sh" = 1400`, dated 2026-08-10) — this doc
  formalizes the plan that override references.
- **`install.sh` is not actually a bare curl-pipe artifact today.** It
  resolves `repo_root` from its own path and `link`/`cp`s sibling `bin/*.sh`
  and `skills/*` from that tree (lines 41, 384–396) — it only works run from
  inside a checked-out repo (`README.md`'s documented flow is `git clone` +
  `./install.sh`). The operative constraint is "cannot `source` sibling files
  at runtime" (true regardless of fetch mechanism); the concat-build design
  below satisfies both the current git-clone flow and any future single-file
  curl flow. PROPOSED interpretation — flag if wrong.

## 1. Module boundaries

Split as **contiguous slices** of the current file (not a functional
regrouping) so the split is mechanical and auditable, and so bash's
define-before-call requirement is trivially satisfied — nothing executes until
`main` dispatches at the bottom, so slice order == today's line order.

| Module | Responsibility | Lines today | Approx size |
|---|---|---|---|
| `install.d/00-preamble.sh` | Usage/help, `set -euo pipefail`, umask, `repo_root`/`claude_home` resolution + validation, settings-symlink resolution, EXIT trap/cleanup, arg parsing, hook command/marker constants | 1–211 | 211 |
| `install.d/10-symlinks.sh` | Volatile-path detection, `link()`/`unlink_if_ours()`, `install_symlinks()`/`uninstall_symlinks()`, `record_replaced_link()`, `remove_secret_if_ours()` | 212–474 | 263 |
| `install.d/20-settings-patch.sh` | `print_manual_snippet`, `commit_settings_tmp`, `maybe_install_hook`, `maybe_install_perm`, `maybe_install_model`/`maybe_uninstall_model`, `maybe_install_statusline`/`maybe_uninstall_statusline` | 475–704 | 230 |
| `install.d/30-settings-unpatch-doctor.sh` | `maybe_uninstall_hook`, `maybe_uninstall_perm`, `migrate_legacy_ss_hook`, `ensure_settings_json`, `patch_settings`, `unpatch_settings`, `doctor` | 706–1018 | 313 |
| `install.d/40-main.sh` | Mode dispatch (`install`/`uninstall`/`doctor`) | 1020–1075 | 56 |

All ≤313 lines — under 500 with headroom before any module needs re-splitting.

## 2. Build step

**PROPOSED: commit the built artifact at `install.sh` (repo root, unchanged
path), built by contributors and re-verified in CI.**

- **Location:** `tools/build-install.sh`. Reads an **explicit ordered array**
  of module filenames (not a bare glob) — a stray or misnamed file in
  `install.d/` can't silently get spliced into a security-relevant script.
  Alternative: glob `install.d/*.sh` sorted by numeric prefix — simpler, less
  safe against an accidental extra file.
- **Shebang/set-flags:** only the build script emits `#!/usr/bin/env bash`
  and the generated-file banner; module files carry no shebang (they're bash
  fragments). `set -euo pipefail`/`umask 077` stay inside `00-preamble.sh` as
  today — one flat script at runtime, no cross-module scoping question.
- **Marker tying artifact to sources:** a `# SOURCE-SHA256: <hash>` comment
  near the top of the generated `install.sh`, computed over the concatenated
  `install.d/*.sh` + the build script itself. Provenance/human-visible only —
  the actual gate (§3) is a full rebuild-and-diff, so the marker can never
  itself be the thing that's stale.
- **Artifact location:** committed at repo root, same path as today. This
  makes §5 (test impact) a no-op — every `test_install_*.sh` invokes
  `bash "$REPO_ROOT/install.sh"` — and `README.md`'s flow needs zero changes.
  Alternative: build in CI only, ship as a release asset — cleaner generated-
  files hygiene, but breaks main-branch raw-URL convenience and re-paths
  every test.

## 3. CI changes

- **New drift gate (blocking):** run `tools/build-install.sh` into a temp
  path and diff against committed `install.sh`; fail on any difference.
  PROPOSED as its own fast job (`install-drift`, ubuntu-latest) rather than a
  step in `tests-linux` — it's a repo-hygiene check, not a functional test.
  Alternative: fold into `tests-linux` as a pre-step.
- **`shellcheck` job: no change.** It already lints the committed
  `install.sh` (`ci.yml:65`); the build output is committed at the same
  path, so it still lints the real, final script. Linting `install.d/*.sh`
  fragments directly would false-positive on names defined in earlier
  modules and adds no coverage the drift gate + whole-file shellcheck lack.
- **`guardrails` (`check-size`):** update the `.scaffold.toml` `install.sh`
  override reason to "generated build artifact; source lives in
  `install.d/*.sh`, each ≤500 (default cap)". The human-edited source becomes
  compliant by construction; the generated concatenation is exempt the same
  way a minified bundle would be.
- **`tests-linux`/`tests-macos`:** unaffected.

## 4. Migration / curl-verify story

The artifact stays at `install.sh` on `main`, so the documented `git clone`
flow is unaffected. For a future curl consumer (single-file curl isn't
functional today anyway — the script needs the surrounding tree):

- PROPOSED: `tools/build-install.sh` also writes a committed
  `install.sh.sha256`; a curl user fetches it and `sha256sum -c` before
  piping. Pin the curl URL to a tagged release (`.../v0.14.0/install.sh`),
  not `main`.
- Alternative: signed release tags (`git tag -s` + `git verify-tag`) —
  stronger, heavier than this repo needs now.

## 5. Test impact

All 12 `tests/test_install_*.sh` files invoke `bash "$REPO_ROOT/install.sh"`
as a subprocess (none `source` it) — **zero pathing changes**. PROPOSED
addition: `tests/test_install_build_drift.sh` runs the build and diffs
against the committed artifact, giving the drift gate local coverage via
`tests/run.sh` before a PR hits CI.

## 6. Risks and landing order

**Risks:** (a) contributors editing `install.d/*.sh` and forgetting to
rebuild — caught by the CI drift gate; mitigate with a local pre-commit check
mirroring it (commit 4). (b) module reordering drifting from the byte-
identical slices — mitigated by the explicit ordered array. (c) the `--help`
self-read reads the *running* script's source — safe post-split since the
generated file is what executes.

**Recommended commits, in order:**
1. Add `install.d/00…40-*.sh` (exact slices, no behavior change) +
   `tools/build-install.sh`; verify rebuild reproduces today's `install.sh`
   (banner aside). Not yet wired into CI.
2. Replace committed `install.sh` with the generated output (banner +
   `SOURCE-SHA256`); update the `.scaffold.toml` override reason.
3. Add the CI drift-gate job; confirm existing jobs pass unchanged.
4. Add `tests/test_install_build_drift.sh` + the local pre-commit mirror.
5. Docs: `CHANGELOG.md` v0.14.0 entry, `docs/reference.md` tree listing
   (add `install.d/`, `tools/build-install.sh`).
