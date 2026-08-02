cask "camillagui" do
  arch arm: "aarch64", intel: "intel"

  version "4.1.0"
  sha256 arm:   "09da0b654aefaa1c983f0208524d9abf768e8a13ae4670d69bc65c17fd4b4f63",
         intel: "4540c78bc05b86977276bea5188f9308d4ccaad954ca8260b47d2b1b6c74d641"

  url "https://github.com/HEnquist/camillagui-backend/releases/download/v#{version}/bundle_macos_#{arch}.tar.gz",
      verified: "github.com/HEnquist/camillagui-backend/"
  name "CamillaGUI"
  desc "Web interface and backend bundle for CamillaDSP"
  homepage "https://github.com/HEnquist/camillagui-backend"

  livecheck do
    url :stable
    strategy :github_latest
  end

  depends_on :macos

  binary "camillagui_backend/camillagui_backend", target: "camillagui"
  service do
    run [opt_bin/"camillagui", "--port", "5005"]
    keep_alive true
    log_path var/"log/camillagui.log"
    error_log_path var/"log/camillagui.error.log"
    environment_variables CAMILLAGUI_PORT: "5005"
  end

  caveats <<~EOS
    camillagui is now a Homebrew service. Run it with:
      brew services start fabioluciano/camilladsp/camillagui
    Then open: http://localhost:5005/gui/index.html

    Logs: #{var}/log/camillagui.log
    To uninstall, run `brew services stop fabioluciano/camilladsp/camillagui && brew uninstall --cask camillagui`.
    Do NOT use `brew bundle cleanup --force`; cleanup means only stopping and uninstalling services.
  EOS
end
