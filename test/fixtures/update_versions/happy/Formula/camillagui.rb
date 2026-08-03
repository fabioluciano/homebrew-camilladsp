class Camillagui < Formula
  desc 'fixture'
  homepage 'https://github.com/HEnquist/camillagui-backend'
  url 'https://github.com/HEnquist/camillagui-backend/releases/download/v1.0.0/bundle_macos_aarch64.tar.gz'
  sha256 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
  url 'https://github.com/HEnquist/camillagui-backend/releases/download/v1.0.0/bundle_macos_intel.tar.gz'
  sha256 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
  service do
    run [opt_bin / 'camillagui', '--port', '5005']
    keep_alive true
  end
end
