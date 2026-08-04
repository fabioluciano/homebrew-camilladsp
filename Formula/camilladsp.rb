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

    # Install default configuration template (example, not used by the service)
    (pkgshare / "config.yml").write <<~YAML
      ---
      # CamillaDSP default configuration for macOS
      # See: https://github.com/HEnquist/camilladsp/blob/main/README.md

      devices:
        samplerate: 44100
        chunksize: 1024
        silence_threshold: -60
        silence_timeout: 3.0
        capture:
          type: CoreAudio
          channels: 2
          device: "BlackHole 2ch"
          format: S32
        playback:
          type: CoreAudio
          channels: 2
          device: "MacBook Pro Speakers"
          format: S32

      # Uncomment and configure filters as needed
      # filters:
      #   highpass:
      #     type: Biquad
      #     parameters:
      #       type: Highpass
      #       freq: 80
      #       q: 0.7

      # Uncomment and configure pipeline as needed
      # pipeline:
      #   - type: Filter
      #     channel: 0
      #     names:
      #       - highpass
      #   - type: Filter
      #     channel: 1
      #     names:
      #       - highpass
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
      camilladsp runs headless, reading its config from:
        ~/.config/camilladsp/config.yml
      Edit that file to change devices, filters, or pipeline. Then restart:
        brew services restart fabriluciano/camilladsp/camilladsp

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
