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

  caveats <<~EOS
    CamillaGUI is not a Homebrew service. Run it manually:

      camillagui &

    Then open:
      http://localhost:5005/gui/index.html

    To uninstall, stop any running `camillagui` process and run
    `brew uninstall --cask camillagui`. Do NOT use
    `brew bundle cleanup --force`; cleanup in this tap means only stopping
    and uninstalling the camilladsp launchd service.
  EOS
end
