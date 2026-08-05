# Homebrew CamillaDSP

Homebrew tap for the [CamillaDSP](https://github.com/HEnquist/camilladsp) audio processing ecosystem on macOS.

## Quick start

```bash
# 1. Add the tap and install
brew tap fabioluciano/camilladsp
brew install camilladsp

# 2. List your audio devices
camilladsp-devices

# 3. Create your config
mkdir -p ~/.config/camilladsp
cp "$(brew --prefix)/opt/camilladsp/share/camilladsp/config.example.yml" ~/.config/camilladsp/config.yml

# 4. Edit the config (set your capture/playback devices)
nano ~/.config/camilladsp/config.yml

# 5. Start the service
brew services start fabioluciano/camilladsp/camilladsp
```

Then in your app (Zoom, OBS, Discord, Voice Memo, etc.), select **BlackHole 2ch** as the microphone input.

## How it works

```
Your voice → MacBook Pro Microphone → CamillaDSP (filters) → BlackHole 2ch → Apps
```

CamillaDSP captures audio from your physical microphone, applies EQ/compression/gate filters, and outputs the processed audio to BlackHole (a virtual audio device). Apps that use BlackHole as their microphone input receive the processed audio.

**Requirements:** [BlackHole](https://github.com/ExistentialAudio/BlackHole) must be installed (`brew install blackhole-2ch`).

## List audio devices

```bash
camilladsp-devices
```

Shows all available CoreAudio devices with their names, types, and channel counts. Use the exact device name in your `config.yml`.

## Configuration

Config file: `~/.config/camilladsp/config.yml`

Example config (installed with the formula):

```bash
cat "$(brew --prefix)/opt/camilladsp/share/camilladsp/config.example.yml"
```

Key fields:

```yaml
devices:
  capture:
    type: CoreAudio
    channels: 1
    device: "MacBook Pro Microphone"   # your physical mic
  playback:
    type: CoreAudio
    channels: 1
    device: "BlackHole 2ch"            # virtual output → apps
```

After editing, restart the service:

```bash
brew services restart fabioluciano/camilladsp/camilladsp
```

## Manage the service

```bash
brew services start fabioluciano/camilladsp/camilladsp    # start
brew services stop fabioluciano/camilladsp/camilladsp     # stop
brew services restart fabioluciano/camilladsp/camilladsp  # restart
brew services list                                         # status
```

Logs:

```bash
tail -f /opt/homebrew/var/log/camilladsp.log        # normal log
tail -f /opt/homebrew/var/log/camilladsp.error.log  # errors
```

## Packages

| Package | Description |
|---|---|
| `camilladsp` | Audio DSP engine (this formula) |
| `camillagui` | Web GUI backend/frontend bundle |
| `pycamilladsp` | Python client library |
| `pycamilladsp-plot` | Config validator and plotting tools |
| `camilladsp-controller` | Auto source-format controller |
| `camilladsp-config` | Reference configurations |
| `camilladsp-setupscripts` | Setup-script templates |
| `camilladsp-suite` | Meta-formula: all CLI packages |

Install everything:

```bash
brew tap fabioluciano/camilladsp
brew bundle --file="$(brew --repository fabioluciano/camilladsp)/Brewfile"
```

## Microphone permission

macOS prompts for microphone access on first capture. If denied, CamillaDSP runs but records silence. Reset with:

```bash
tccutil reset Microphone
```

## Troubleshooting

| Problem | Solution |
|---|---|
| No audio in apps | Make sure app input is set to "BlackHole 2ch" |
| Feedback/howling | Playback must be BlackHole, NOT Speakers |
| Silence | Check mic permission: `tccutil reset Microphone` |
| Service won't start | Check logs: `tail /opt/homebrew/var/log/camilladsp.error.log` |
| Config error | Validate: `camilladsp -c ~/.config/camilladsp/config.yml` |

## Development

```bash
bash scripts/verify.sh                    # run all checks
python3 scripts/update_versions.py        # update package versions
```

## License

Tap definitions: MIT. Each component keeps its upstream license (CamillaDSP: GPL-3.0-only OR MPL-2.0; CamillaGUI: GPL-3.0-only).
