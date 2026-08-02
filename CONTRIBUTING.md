# Contributing

## Validate changes

```bash
scripts/verify.sh
brew style Formula/*.rb
brew style --cask camillagui.rb
brew audit --strict --formula Formula/*.rb
brew audit --strict camillagui
```

`brew audit --strict --cask <path>` is the disabled path form in
Homebrew 6.0.x; the canonical invocation is by cask name (`brew
audit --strict camillagui`).

## Packages and inventory

The tap ships exactly eight Homebrew packages. The same table appears in `README.md` § "Packages"; this section is the developer-facing mirror that pairs each package with the formula/cask path and the key validation commands. Keep the two tables in sync; `test/test_docs_inventory.rb` cross-checks them.

| Homebrew package | Formula/cask path | Key validation |
|---|---|---|
| `camilladsp` | `Formula/camilladsp.rb` | `brew style Formula/camilladsp.rb`, `brew test camilladsp`, `ruby -Ilib -Itest test/test_formula_contracts.rb` |
| `camillagui` | `Casks/camillagui.rb` | `brew style Casks/camillagui.rb`, `brew audit --strict --cask camillagui` |
| `pycamilladsp` | `Formula/pycamilladsp.rb` | `brew test pycamilladsp`, `brew audit --strict pycamilladsp` |
| `pycamilladsp-plot` | `Formula/pycamilladsp-plot.rb` | `brew test pycamilladsp-plot`, `brew audit --strict pycamilladsp-plot` |
| `camilladsp-controller` | `Formula/camilladsp-controller.rb` | `brew test camilladsp-controller`, `brew audit --strict camilladsp-controller` |
| `camilladsp-config` | `Formula/camilladsp-config.rb` | `brew test camilladsp-config`, `brew audit --strict camilladsp-config` |
| `camilladsp-setupscripts` | `Formula/camilladsp-setupscripts.rb` | `brew test camilladsp-setupscripts`, `brew audit --strict camilladsp-setupscripts` |
| `camilladsp-suite` | `Formula/camilladsp-suite.rb` | `brew test camilladsp-suite`, `brew audit --strict camilladsp-suite` |

The suite formula is the only `depends_on` aggregator; the Brewfile lists only the suite plus the cask, never the individual CLI formulae. The cask and every formula are real-arch-pinned (no `sha256 :no_check`); `test/scope_check.rb` enforces both contracts.

## Updating releases

```bash
python3 scripts/update_versions.py
```

### Safety contract

`scripts/update_versions.py` is a transactional, allow-listed updater. Every release is governed by the user invariant that a new tag must build and publish a new tap release; the updater is the mechanism that turns a tag into the tap pin. It enforces four safety guarantees:

- **Strict scope.** It updates exactly the seven `Formula/*.rb` files and `Casks/camillagui.rb`. It never expands that scope to README, Brewfile, or arbitrary files; any extra `.rb` in `Formula/` or `Casks/`, or any missing expected file, aborts with `Unexpected updater scope` before any write.
- **One-substitution rule.** Every regex replacement (version line, tag, revision, cask architecture hashes, Python resource URL/SHA-256) must match **exactly once** per file. Zero or multiple matches abort the whole run with a clear `expected exactly one substitution, found N` message and a file:label context, before any disk write.
- **Upstream validation.** Each repo's release tag is re-validated against the GitHub refs API; every required asset (engine ARM/Intel tarballs, GUI ARM/Intel tarballs) is checked by name and download URL, and every SHA-256 is verified to be a 64-hex string. A missing tag, missing asset, missing branch commit, or non-2xx API response aborts before any write.
- **Atomic write + rollback.** Before writing, the updater snapshots the bytes and mode of every file in the tap (excluding `.git/` and `.omo/`). It then writes each planned file through an `os.replace`-based atomic rename. If any write fails — or if the post-write SHA-256 of a planned file does not match the bytes that were supposed to land there — every file is restored from the snapshot, including any file that was created during this run. The exit status is 1 and no partial state is ever left on disk.

### Idempotency

Re-running the updater against a tap that already matches the upstream responses is a no-op: every version, tag, revision, URL, resource SHA-256, and cask architecture hash is already pinned to the value the API returns, so each "exactly one substitution" regex matches and replaces the line with its current value. No second diff. This is verified in `test/test_update_versions.rb` by running the updater twice on the same fixture and asserting the second run produces zero byte-level change.

### Offline / test mode

For local testing and CI, the updater accepts `--fixture <dir>` which swaps the GitHub/PyPI fetcher for an offline `MockFetcher` that reads `api-mocks/responses.json` from the given fixture root and refuses to fall back to the network. The fixtures under `test/fixtures/update_versions/{happy,up-to-date}/` cover intentional changes and the already-current state without making a real GitHub or PyPI request. The black-box Ruby Minitest suite in `test/test_update_versions.rb` drives the updater as a subprocess via `Open3.capture3("python3", "scripts/update_versions.py", "--fixture", ...)` — no Python import, no Gemfile, no VCR-style recording library — and covers validation, rollback, scope, idempotency, and the no-network contract.

## Automated updates

The user invariant ("every new tag must build and publish a new tap release") is enforced in CI by `.github/workflows/update.yml`. The workflow's source of truth is here, in this section, so the linkage between the user invariant and the pipeline stays in one place.

- **Triggers.** The workflow runs on three triggers, in priority order:
  1. `repository_dispatch: types: [upstream-release]` — fired by the upstream `HEnquist/*` repos (CamillaDSP, CamillaGUI, pycamilladsp, pycamilladsp-plot, camilladsp-setupscripts) on each new release tag. This is the user-invariant path: a new tag lands within minutes of upstream tagging.
  2. `workflow_dispatch` — manual reconciliation by a maintainer.
  3. `schedule: 0 6 * * *` (06:00 UTC daily) — reconciliation safety net that catches any missed `repository_dispatch` event.

  The workflow is intentionally not bound to `push` or `pull_request` so a contributor push never auto-opens a release PR.
- **Order.** The job is strictly ordered to fail fast and avoid partial state:
  1. `actions/checkout` (full history, `fetch-depth: 0`) so `git diff` has a real baseline.
  2. `Homebrew/actions/setup-homebrew` to install Homebrew on the macOS-15 runner.
  3. Run the transactional updater against the live GitHub Releases + PyPI APIs: `python3 scripts/update_versions.py` with `GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}` forwarded explicitly. The fixture under `test/fixtures/update_versions/` is for the local mirror (`test/run_update_workflow_fixture.rb`) only; CI never points the updater at it.
  4. `git diff --quiet` → emit `has_diff=true|false`. **A no-op run MUST NOT open a PR.**
  5. If `has_diff == 'true'`, run `bash scripts/verify.sh` plus `brew audit --strict` on the cask and every formula. Validation failure aborts the workflow before any PR is opened.
  6. If validation passed, write the diff summary to `.ci-evidence/update-pr-body.md` and open a single PR via `peter-evans/create-pull-request`.
- **Concurrency.** A single `concurrency: group: ${{ github.workflow }}-${{ github.ref }}` prevents the daily cron and a manual dispatch (or two `repository_dispatch` events fired back-to-back) from racing and producing duplicate PRs. `cancel-in-progress: false` keeps a slow in-flight update from being cut off mid-run by a fresher one.
- **PR token.** `peter-evans/create-pull-request` is invoked with an explicit `token: ${{ secrets.UPDATE_PR_TOKEN || secrets.GITHUB_TOKEN }}`. `UPDATE_PR_TOKEN` is the preferred path — a GitHub App installation token or a PAT — because the default `GITHUB_TOKEN` does NOT trigger downstream `on: pull_request` workflows on the auto-PR branch (per GitHub Actions policy). For tap repos that require `audit.yml` to gate the auto-PR, configure `UPDATE_PR_TOKEN` and rotate it via the installation's expiry; the fallback to `GITHUB_TOKEN` keeps the PR creation working but skips automatic audit on the PR.
- **PR gating.** A PR is opened only when (a) the updater produced a non-empty `git diff` AND (b) `scripts/verify.sh` + `brew audit --strict` both succeeded. No-diff runs exit cleanly; validation-failure runs never reach the PR step.
- **Permissions.** The workflow declares `permissions: contents: write, pull-requests: write` (different from `.github/workflows/audit.yml`, which is `contents: read`). No other workflow in this tap has write permissions.
- **Action pins.** `actions/checkout@f548e57e544e1ff5a4c46bf1e1b8685f8e4a348a`, `Homebrew/actions/setup-homebrew@850067efd47cb5801a4c1d71c2297c860b522f3b`, and `peter-evans/create-pull-request@7ec5aae3c91d101b005af46adc760d265911886a` are SHA-pinned. Bumping them is a deliberate change and must be reviewed alongside any GitHub Actions surface that depends on them.
- **Local mirror.** `test/run_update_workflow_fixture.rb` is the local black-box mirror of this workflow: it copies `test/fixtures/update_versions/{happy,up-to-date}/` to a tempdir, runs the same `python3 scripts/update_versions.py --fixture <tmpdir>` subprocess, and asserts the same `diff → validation → PR` gating that the YAML encodes. `test/test_update_versions.rb` is the black-box coverage of the updater itself (transactional, scope, idempotency, no-network).

Review every generated URL and checksum before merging. Do not replace upstream component licenses or publish modified binaries under the tap's MIT license.

## Maintenance: upstream contract references

The contracts below were consulted as primary sources on **2026-08-01**, each pinned to an exact revision. Do not add contract claims to this tap without a consulted primary source recorded here.

### Consulted sources (retrieved 2026-08-01)

| Source | Pinned URL | Revision |
|---|---|---|
| CamillaDSP engine README | https://github.com/HEnquist/camilladsp/blob/73a882cce0a6a769210d0509857b99eaf1a5c6bc/README.md | `73a882cce0a6a769210d0509857b99eaf1a5c6bc` |
| CamillaDSP CoreAudio backend doc | https://github.com/HEnquist/camilladsp/blob/16ad1b8515c53f5f733368207ae54ec8742b8e76/backend_coreaudio.md | `16ad1b8515c53f5f733368207ae54ec8742b8e76` |
| camilladsp-controller README | https://github.com/HEnquist/camilladsp-controller/blob/23adf7f2996c0da1f547d602101dbb479b3fa564/README.md | `23adf7f2996c0da1f547d602101dbb479b3fa564` |
| Homebrew Formula Cookbook | https://github.com/Homebrew/brew/blob/7e3b7b186f9b4a58cd3f5eeaae658b7976e80037/docs/Formula-Cookbook.md | `7e3b7b186f9b4a58cd3f5eeaae658b7976e80037` |
| Homebrew Cask Cookbook | https://github.com/Homebrew/brew/blob/7e3b7b186f9b4a58cd3f5eeaae658b7976e80037/docs/Cask-Cookbook.md | `7e3b7b186f9b4a58cd3f5eeaae658b7976e80037` |

### CamillaDSP engine contracts (README @ `73a882c`)

- `-c, --check` validates the YAML config and exits without starting audio processing.
- Exit codes: `0` normal exit, `101` invalid config file, `102` error from DSP process, `103` forced exit by a second SIGINT.
- `-w, --wait` starts the websocket server and waits for a configuration to be uploaded; the config file argument must be omitted in this mode.
- `-s, --statefile <path>` persists only the config file path and volume/mute settings (five faders: Main + Aux1-4); it is not a device YAML. A configfile argument overrides the statefile's `config_path`.
- `-p, --port` enables the websocket server (omitted or 0 disables it); the server binds to `127.0.0.1` by default, changed with `-a, --address`.
- macOS release assets: `camilladsp-macos-aarch64.tar.gz` (Apple Silicon) and `camilladsp-macos-amd64.tar.gz` (Intel), both with the CoreAudio backend and the websocket server included.
- License: GPL-3.0-only OR MPL-2.0 (user's choice).

### CoreAudio contracts (backend_coreaudio.md @ `16ad1b8`)

- Device names are entered exactly as shown in Audio MIDI Setup; `device` is optional (`null` or omitted selects the default capture/playback device).
- The optional `format` values for CoreAudio are `S16`, `S24`, `S32`, `F32` (mapping to the Audio MIDI Setup bit depths). If omitted, CamillaDSP leaves the sample format unchanged and only switches the sample rate.
- Playback `exclusive` (hog mode) is optional and defaults to `false`.
- Microphone access denial produces no error: CamillaDSP appears to run but records silence; remedy is `tccutil reset Microphone`.
- BlackHole is the recommended virtual sound card on both Intel and Apple Silicon; CoreAudio sample-rate change notifications stop CamillaDSP, and the new rate is readable via the websocket `StopReason`.

### Controller contracts (README @ `23adf7f`)

- Works with CamillaDSP v4.0 and later; requires the `pycamilladsp` and `pyyaml` Python packages.
- Config providers: `-s, --specific <template>` (path with `{samplerate}`, `{sampleformat}`, `{channels}` placeholders) and `-a, --adapt <config>` (sets `capture_samplerate` when a resampler is configured, otherwise the main `samplerate`). Multiple providers can be enabled and are tried in order, Specific first.
- macOS device listener: `-d <device>` monitors a CoreAudio device; it requires `cffi` and compiles a small C helper on first use, requiring the Xcode Command Line Tools.
- There is no device listener for Windows.

### Homebrew packaging contracts (Formula + Cask Cookbooks @ `7e3b7b1`)

- Formula `license` uses SPDX identifiers; `any_of` means the user may choose among the listed licenses.
- Formula `test do` runs with `HOME` set to `testpath`, must not require user input, and should exercise basic functionality.
- Top-level `depends_on :macos` marks a formula or cask as macOS-only.
- Python dependencies belong in `resource` blocks with immutable URLs and SHA-256 checksums; formulae must not rely on the contributor's global Python environment.
- Cask required stanzas are `version`, `sha256` (or the special value `:no_check`), `url`, `name`, `desc`, `homepage`; the cask DSL has no `license` stanza.
- Cask `arch arm: ..., intel: ...` provides per-architecture substitutions; the `binary` stanza links an executable into `$(brew --prefix)/bin` with an optional `target:` rename.

### Package surface matrix

Derived from the tap files themselves by `test/plan_contract_checks.py` (offline, deterministic). Re-run it after any packaging change:

```bash
python3 test/plan_contract_checks.py --inventory-only --json-out /dev/stdout
```

| Package | Upstream repo / component | Executables | Dependencies | License | Architectures | Install mode |
|---|---|---|---|---|---|---|
| `camilladsp` (formula) | `HEnquist/camilladsp` — engine (Rust CLI) 4.1.3 | `camilladsp` | none | GPL-3.0-only OR MPL-2.0 | arm64, x86_64 | prebuilt binary tarball per macOS arch |
| `camilladsp-config` (formula) | `HEnquist/camilladsp-config` — reference configs 2023.01.21 | none (data only) | none | GPL-3.0-only | universal | git checkout into `pkgshare` |
| `camilladsp-controller` (formula) | `HEnquist/camilladsp-controller` — format controller 2026.03.19 | `camilladsp-controller` | `cffi`, `libyaml`, `python@3.14`, `:macos`; resources: pyyaml, websocket-client, setuptools, pycamilladsp | GPL-3.0-only | universal | Python virtualenv in `libexec` + launcher wrapper |
| `camilladsp-setupscripts` (formula) | `HEnquist/camilladsp-setupscripts` — templates/renderer v3.0.3 | `camilladsp-build-setup-scripts` | `python@3.14` | GPL-3.0-only | universal | git checkout into `pkgshare` + renderer wrapper |
| `camilladsp-suite` (formula) | `HEnquist/camilladsp` — meta-package v4.1.3 | none | the six CLI formulae above | MIT (tap) | universal | meta-formula (dependencies only) |
| `pycamilladsp` (formula) | `HEnquist/pycamilladsp` — Python client v4.0.0 | `pycamilladsp-python` | `libyaml`, `python@3.14`; resources: pyyaml, websocket-client | GPL-3.0-only | universal | Python virtualenv in `libexec` + launcher wrapper |
| `pycamilladsp-plot` (formula) | `HEnquist/pycamilladsp-plot` — validator/plotting v4.1.0 | `plotcamillaconf`, `pycamilladsp-plot-python` | `numpy`, `python-matplotlib`, `rpds-py`, `libyaml`, `python@3.14`; resources: attrs, pyyaml, referencing, jsonschema-specifications, jsonschema | GPL-3.0-only | universal | Python virtualenv in `libexec` + symlinked script and launcher wrapper |
| `camillagui` (cask) | `HEnquist/camillagui-backend` — GUI bundle 4.1.0 | `camillagui` | `:macos` | not declared (cask DSL has no license stanza) | arm64, x86_64 | cask binary bundle, `binary` linked as `camillagui` |
