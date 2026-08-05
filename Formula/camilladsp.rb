class Camilladsp < Formula
  desc "Flexible cross-platform IIR and FIR audio DSP engine"
  homepage "https://github.com/HEnquist/camilladsp"
  license any_of: ["GPL-3.0-only", "MPL-2.0"]

  livecheck do
    url :stable
    strategy :github_latest
  end

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/HEnquist/camilladsp/releases/download/v4.1.3/camilladsp-macos-aarch64.tar.gz"
      sha256 "70628ac7b66f67da04522e9040d484c2cbd61e9379d227c595f46dc61355bef8"
    else
      url "https://github.com/HEnquist/camilladsp/releases/download/v4.1.3/camilladsp-macos-amd64.tar.gz"
      sha256 "b66ff5fd036344340e10e46060eaf07a1fb45b5c092fba46f116457550085564"
    end
  end

  def install
    (var / "camilladsp").mkpath
    bin.install "camilladsp"

    # Helper: list available CoreAudio devices for use in config.yml
    (bin / "camilladsp-devices").write <<~SH
      #!/bin/bash
      # List audio devices available for CamillaDSP configuration.
      # Usage: camilladsp-devices
      echo "Audio devices (use the exact name in config.yml device: field):"
      echo ""
      printf "%-35s %-10s %-8s %-8s %s\\n" "DEVICE NAME" "TYPE" "INPUT" "OUTPUT" "DEFAULT"
      printf "%-35s %-10s %-8s %-8s %s\\n" "-----------" "----" "-----" "------" "-------"
      system_profiler SPAudioDataType 2>/dev/null | awk '
        /^        [A-Z]/ {
          if (name != "") print_line()
          name=$0; gsub(/^        /, "", name); gsub(/:$/, "", name)
          transport=""; in_ch="-"; out_ch="-"; flags=""
        }
        /Transport:/ { transport=$NF }
        /Input Channels:/ { in_ch=$NF }
        /Output Channels:/ { out_ch=$NF }
        /Default Input Device: Yes/ { flags=flags "in " }
        /Default Output Device: Yes/ { flags=flags "out " }
        END { if (name != "") print_line() }
        function print_line() {
          printf "%-35s %-10s %-8s %-8s %s\\n", name, transport, in_ch, out_ch, flags
        }
      '
      echo ""
      echo "Example config.yml capture/playback:"
      echo '  capture:'
      echo '    type: CoreAudio'
      echo '    channels: 1'
      echo '    device: "MacBook Pro Microphone"'
      echo '  playback:'
      echo '    type: CoreAudio'
      echo '    channels: 1'
      echo '    device: "BlackHole 2ch"'
    SH
    chmod 0755, bin / "camilladsp-devices"

    # Example configuration template (copy to ~/.config/camilladsp/config.yml)
    (pkgshare / "config.example.yml").write <<~YAML
      ---
      # CamillaDSP example config — microphone processing for macOS.
      # Copy to ~/.config/camilladsp/config.yml and edit devices/filters.
      # List available devices: camilladsp-devices

      devices:
        samplerate: 48000
        chunksize: 1024
        target_level: 512
        silence_threshold: -90
        silence_timeout: 3.0
        enable_rate_adjust: true
        capture:
          type: CoreAudio
          channels: 1
          device: "MacBook Pro Microphone"
        playback:
          type: CoreAudio
          channels: 1
          device: "BlackHole 2ch"

      filters:
        highpass:
          type: Biquad
          parameters: {type: Highpass, freq: 100, q: 0.707}
        warmth:
          type: Biquad
          parameters: {type: Lowshelf, freq: 150, gain: 3, q: 0.7}
        box_cut:
          type: Biquad
          parameters: {type: Peaking, freq: 250, gain: -5, q: 1.0}
        presence:
          type: Biquad
          parameters: {type: Peaking, freq: 3000, gain: 5, q: 0.8}
        air:
          type: Biquad
          parameters: {type: Highshelf, freq: 10000, gain: 4, q: 0.7}
        limiter:
          type: Limiter
          parameters: {clip_limit: -1}

      processors:
        compressor:
          type: Compressor
          parameters: {channels: 1, threshold: -20, attack: 15, release: 100, factor: 4, makeup_gain: 4}
        gate:
          type: NoiseGate
          parameters: {channels: 1, threshold: -38, attack: 2, release: 100, attenuation: 40}

      pipeline:
        - type: Filter
          names: [highpass, warmth, box_cut, presence, air]
        - type: Processor
          name: compressor
        - type: Processor
          name: gate
        - type: Filter
          names: [limiter]
    YAML
  end

  service do
    run [opt_bin / "camilladsp", Pathname.new(Dir.home) / ".config/camilladsp/config.yml"]
    keep_alive true
    log_path var / "log/camilladsp.log"
    error_log_path var / "log/camilladsp.error.log"
    working_dir "#{var}/camilladsp"
  end

  def caveats
    <<~EOS
      Quick start:
        1. List available audio devices:
             camilladsp-devices
        2. Copy the example config:
             mkdir -p ~/.config/camilladsp
             cp #{opt_pkgshare}/config.example.yml ~/.config/camilladsp/config.yml
        3. Edit the config to match your devices:
             nano ~/.config/camilladsp/config.yml
        4. Start the service:
             brew services start fabioluciano/camilladsp/camilladsp
        5. In your app (Zoom, OBS, etc.), select "BlackHole 2ch" as microphone.

      Logs: #{var}/log/camilladsp.log

      macOS microphone permission:
        On first capture, macOS prompts for microphone access. If denied,
        CamillaDSP appears to run but only records silence. To reset:
          tccutil reset Microphone
    EOS
  end

  test do
    # Bounded parse-only test: validates YAML config with `-c/--check` and
    # the help text. Does NOT start audio processing and does NOT exercise
    # CoreAudio hardware (explicit anti-slop guardrail: the runner never
    # captures or plays audio through the engine).

    # Happy contract: --help exits 0 and advertises the websocket-driven
    # config workflow. Catches a binary that lost its CLI front-end.
    help = shell_output("#{bin}/camilladsp --help")
    assert_match "CamillaDSP", help
    assert_match "Usage", help
    assert_match "websocket", help.downcase

    # Happy contract: a valid CoreAudio config validates cleanly (exit 0).
    valid_yaml = <<~YAML
      devices:
        samplerate: 44100
        chunksize: 1024
        capture:
          type: CoreAudio
          channels: 2
          format: S32
        playback:
          type: CoreAudio
          channels: 2
          format: S32
    YAML
    (testpath / "valid.yml").write valid_yaml
    shell_output("#{bin}/camilladsp -c #{testpath}/valid.yml")

    # Failure contract: unknown backend type produces exit 101.
    invalid_yaml = <<~YAML
      devices:
        samplerate: 44100
        chunksize: 1024
        capture:
          type: NonExistentBackend
          channels: 2
        playback:
          type: NonExistentBackend
          channels: 2
    YAML
    (testpath / "invalid.yml").write invalid_yaml
    shell_output("#{bin}/camilladsp -c #{testpath}/invalid.yml", 101)

    # Failure contract: a non-existent config file is rejected with the
    # same 101 exit code as a malformed config (catches the engine
    # silently accepting `--check` with no input).
    shell_output("#{bin}/camilladsp -c #{testpath}/does-not-exist.yml 2>&1", 101)
  end
end
