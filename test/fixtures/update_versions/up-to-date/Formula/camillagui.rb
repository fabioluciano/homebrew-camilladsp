class Camillagui < Formula
  desc 'fixture'
  homepage 'https://github.com/HEnquist/camillagui-backend'
  url 'https://github.com/HEnquist/camillagui-backend/releases/download/v3.0.0/bundle_macos_aarch64.tar.gz'
  sha256 '3333333333333333333333333333333333333333333333333333333333333333'
  url 'https://github.com/HEnquist/camillagui-backend/releases/download/v3.0.0/bundle_macos_intel.tar.gz'
  sha256 '4444444444444444444444444444444444444444444444444444444444444444'
  service do
    run [opt_bin / 'camillagui', '--port', '5005']
    keep_alive true
  end
end
