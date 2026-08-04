# Homebrew CamillaDSP

A dedicated Homebrew tap for the complete official CamillaDSP ecosystem on macOS.

The GitHub repository is named **`homebrew-camilladsp`**. Homebrew exposes it as:

```bash
brew tap fabioluciano/camilladsp
```

## Packages

The tap ships exactly eight Homebrew packages — seven CLI formulae (including the GUI) and one meta-formula that aggregates the six CLI-only packages. The version column is the upstream pin; the packaging column is how the tap installs it.

| Homebrew package | Upstream component | Packaging |
|---|---|---|
| `camilladsp` | CamillaDSP engine 4.1.3 | Native binary (Apple Silicon and Intel) |
| `camillagui` | CamillaGUI backend/frontend bundle 4.1.0 | Native binary (Apple Silicon and Intel) with service block |
| `pycamilladsp` | Python client library 4.0.0 | Isolated Python virtual environment |
| `pycamilladsp-plot` | Config validator and plotting tools 4.1.0 | Isolated Python virtual environment |
| `camilladsp-controller` | Automatic source-format controller 2026.03.19 | Isolated Python application |
| `camilladsp-config` | Official reference configurations 2023.01.21 | Shared data package |
| `camilladsp-setupscripts` | Official setup-script templates 3.0.3 | Shared data and renderer |
| `camilladsp-suite` | All command-line packages 4.1.3 | Meta-formula (aggregator) |

The GUI formula is intentionally separate from the suite: CamillaGUI is bundled by upstream with its own backend, frontend, and Python runtime, so a separate frontend formula is unnecessary.

## Install everything

Install the tap and run the canonical Brewfile. The Brewfile aggregates the six CLI formulae via the `camilladsp-suite` meta-formula and installs the GUI formula; it never lists the individual CLI formulae.

```bash
brew tap fabioluciano/camilladsp
brew bundle --file="$(brew --repository fabioluciano/camilladsp)/Brewfile"
```

## Install the normal desktop setup

```bash
brew tap fabioluciano/camilladsp
brew install camilladsp
brew install camillagui
```

## Install all command-line packages

```bash
brew install camilladsp-suite
brew install camillagui
```

## Individual packages

```bash
brew install pycamilladsp
brew install pycamilladsp-plot
brew install camilladsp-controller
brew install camilladsp-config
brew install camilladsp-setupscripts
```

## GUI formula

The GUI formula is delivered as two architecture-specific tarballs with pinned SHA-256 sums; there is no `sha256 :no_check` placeholder in the formula.

ARM64: sha256 09da0b654aefaa1c983f0208524d9abf768e8a13ae4670d69bc65c17fd4b4f63
Intel: sha256 4540c78bc05b86977276bea5188f9308d4ccaad954ca8260b47d2b1b6c74d641

## Run

Start CamillaDSP with its WebSocket server and state file:

```bash
mkdir -p ~/.config/camilladsp
camilladsp -p 16440 -w -s ~/.config/camilladsp/statefile.yml
```

`-w` makes the engine wait for a configuration to be uploaded over WebSocket; `-s` persists the active config path and the five volume/mute faders. The statefile is not a device YAML — it is the state of the websocket session, not a configuration file.

Start the GUI in another terminal:

```bash
camillagui
```

Then open:

```text
http://localhost:5005/gui/index.html
```

## Python packages

Homebrew installs the Python libraries in isolated virtual environments under the formula's `libexec`; the tap never uses the global macOS Python, and `system_site_packages: false` is mandatory in every Python formula.

```bash
pycamilladsp-python -c 'import camilladsp; print(camilladsp.VERSION)'
plotcamillaconf /path/to/config.yml
```

`pycamilladsp-python` and `pycamilladsp-plot-python` are thin wrappers that `exec` the venv interpreter; `plotcamillaconf` is a symlink into the same venv. The libraries are not on the global Python `sys.path`.

## Controller

The controller runs manually (there is no `brew services` launchd agent for it). It monitors the active audio device and restarts CamillaDSP automatically when the source format changes.

```bash
camilladsp-controller -p 16440 -s "$HOME/.config/camilladsp/configs/config_{samplerate}.yml"
```

Required arguments:

- `-p <port>` — WebSocket port CamillaDSP is listening on
- `-s <path>` — Per-samplerate config template (use `{samplerate}` as a placeholder)
- `-a <path>` — Alternative to `-s`: single fixed config file

Optional arguments:

- `-d <device>` — macOS CoreAudio listener/output device (auto-switches on samplerate changes)

At least one of `-s` or `-a` is required.

## CoreAudio limits

The tap does not exercise real CoreAudio capture or playback. The CI runners have no CoreAudio hardware, so every audio test is parse-only (the engine's `-c` flag validates a YAML config and exits without starting audio processing). Real audio behaviour is verified upstream by the engine's own integration tests; this tap only pins the packaging and the CLI surface.

## Microphone permission

macOS prompts for microphone access on the first capture. If the prompt is denied, CamillaDSP appears to run but only records silence. To reset the permission so the prompt is shown again:

```bash
tccutil reset Microphone
```

This is the canonical remedy recommended by the upstream `backend_coreaudio.md` and is also documented in the engine formula caveats.

## Update package versions

The updater is a transactional, allow-listed Python script that reads the official GitHub releases and PyPI, downloads the release assets to calculate the SHA-256 sums, and rewrites exactly the eight `Formula/*.rb` files in a single atomic operation. It refuses to fall back to a partial write on failure, and re-running it on an already-current tap is a no-op.

```bash
python3 scripts/update_versions.py  # transactional; uses --fetcher-fixture in CI
```

The `Update packages` GitHub Actions workflow runs the updater, validates the result with `bash scripts/verify.sh` and `brew audit --strict` on every formula, and commits directly to main only when the updater produced a non-empty diff AND the validation passed. See `CONTRIBUTING.md` § "Automated updates" for the full ordering, the diff→validation→commit gating, and the SHA-pinned action versions.

## Local validation

```bash
bash scripts/verify.sh
```

This runs `brew style`, `brew audit --strict`, `brew bundle check`, `brew test` on every formula, and the Ruby Minitest contract suite under `test/`. Exits non-zero on the first failed step; never silently skips a required check.

## Repository layout

```text
homebrew-camilladsp/
├── Formula/
├── Casks/
├── scripts/
├── .github/workflows/
├── test/
├── Brewfile
├── README.md
└── LICENSE
```

## License

The tap definitions and automation are MIT licensed. Each installed component remains under its own upstream license (CamillaDSP engine: GPL-3.0-only OR MPL-2.0; CamillaGUI: GPL-3.0-only; configuration and Python packages: GPL-3.0-only).
