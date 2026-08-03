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
  end

  service do
    run [opt_bin / "camillagui", "--port", "5005"]
    keep_alive true
    log_path var / "log/camillagui.log"
    error_log_path var / "log/camillagui.error.log"
    environment_variables CAMILLAGUI_PORT: "5005"
  end

  def caveats
    <<~EOS
      camillagui is now a Homebrew service. Run it with:
        brew services start fabioluciano/camilladsp/camillagui
      Then open: http://localhost:5005/gui/index.html

      Logs: #{var}/log/camillagui.log
      To uninstall, run `brew services stop fabioluciano/camilladsp/camillagui && brew uninstall camillagui`.
      Do NOT use `brew bundle cleanup --force`; cleanup means only stopping and uninstalling services.
    EOS
  end

  test do
    assert_path_exists bin / "camillagui"
  end
end
