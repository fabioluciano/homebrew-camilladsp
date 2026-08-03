cask 'camillagui' do
  version '3.0.0'
  sha256 arm:   '3333333333333333333333333333333333333333333333333333333333333333',
         intel: '4444444444444444444444444444444444444444444444444444444444444444'
  url "https://github.com/HEnquist/camillagui-backend/releases/download/v#{version}/bundle_macos_#{arch}.tar.gz"
end
