cask 'camillagui' do
  version '1.0.0'
  sha256 arm: 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
         intel: 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
  url "https://github.com/HEnquist/camillagui-backend/releases/download/v#{version}/bundle_macos_#{arch}.tar.gz"
end
