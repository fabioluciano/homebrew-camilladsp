class Camillagui < Formula
  desc "Web interface and backend bundle for CamillaDSP"
  homepage "https://github.com/HEnquist/camillagui-backend"
  license "GPL-3.0-only"

  livecheck do
    url :stable
    strategy :github_latest
  end

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/HEnquist/camillagui-backend/releases/download/v4.1.0/bundle_macos_aarch64.tar.gz"
      sha256 "09da0b654aefaa1c983f0208524d9abf768e8a13ae4670d69bc65c17fd4b4f63"
    else
      url "https://github.com/HEnquist/camillagui-backend/releases/download/v4.1.0/bundle_macos_intel.tar.gz"
      sha256 "4540c78bc05b86977276bea5188f9308d4ccaad954ca8260b47d2b1b6c74d641"
    end
  end

  def install
    libexec.install "_internal"
    libexec.install "camillagui_backend"
    bin.install_symlink libexec / "camillagui_backend" => "camillagui"

    # Override the embedded default config: camilla_port must be 16440
    # (not 1234) to match the camilladsp service, and the ~/camilladsp/
    # paths do not exist on a fresh install.
    (etc / "camillagui.yml").write <<~YAML
      ---
      camilla_host: "127.0.0.1"
      camilla_port: 16440
      bind_address: "127.0.0.1"
      port: 5005
      ssl_certificate: null
      ssl_private_key: null
      gui_config_file: null
      config_dir: "#{HOMEBREW_PREFIX}/var/camillagui/configs"
      coeff_dir: "#{HOMEBREW_PREFIX}/var/camillagui/coeffs"
      default_config: "#{HOMEBREW_PREFIX}/var/camillagui/default_config.yml"
      statefile_path: "#{HOMEBREW_PREFIX}/var/camillagui/statefile.yml"
      log_file: "#{HOMEBREW_PREFIX}/var/log/camilladsp.log"
      on_set_active_config: null
      on_get_active_config: null
      supported_capture_types: null
      supported_playback_types: null
    YAML

    (var / "camillagui/configs").mkpath
    (var / "camillagui/coeffs").mkpath

    (var / "camillagui/default_config.yml").write <<~YAML
      ---
      devices:
        samplerate: 44100
        chunksize: 1024
        silence_threshold: -60
        silence_timeout: 3.0
        capture:
          type: CoreAudio
          channels: 2
        playback:
          type: CoreAudio
          channels: 2
    YAML
  end

  service do
    run [opt_bin / "camillagui", "-c", etc / "camillagui.yml"]
    keep_alive true
    log_path var / "log/camillagui.log"
    error_log_path var / "log/camillagui.error.log"
  end

  def caveats
    <<~EOS
      camillagui is now a Homebrew service. Run it with:
        brew services start fabioluciano/camilladsp/camillagui
      Then open: http://localhost:5005/gui/index.html

      Configs are stored in #{HOMEBREW_PREFIX}/var/camillagui/configs/.
      The backend connects to camilladsp on port 16440 (matching the
      camilladsp formula service). Override the backend config at
      #{HOMEBREW_PREFIX}/etc/camillagui.yml.

      Logs: #{var}/log/camillagui.log
      To uninstall, run `brew services stop fabioluciano/camilladsp/camillagui && brew uninstall camillagui`.
      Do NOT use `brew bundle cleanup --force`; cleanup means only stopping and uninstalling services.
    EOS
  end

  test do
    assert_path_exists bin / "camillagui"
  end
end
