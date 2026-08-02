class CamilladspController < Formula
  include Language::Python::Virtualenv

  desc "Automatically switch CamillaDSP configs when the source format changes"
  homepage "https://github.com/HEnquist/camilladsp-controller"
  url "https://github.com/HEnquist/camilladsp-controller.git",
      revision: "e9fde2057d5869e6805a965e9c091bbb9a9e9980"
  version "2026.03.19"
  license "GPL-3.0-only"
  head "https://github.com/HEnquist/camilladsp-controller.git", branch: "main"

  livecheck do
    skip "No upstream tags; version is the commit date of the master/main branch"
  end

  depends_on "cffi"
  depends_on "libyaml"
  depends_on :macos
  depends_on "python@3.14"

  resource "pyyaml" do
    url "https://files.pythonhosted.org/packages/05/8e/961c0007c59b8dd7729d542c61a4d537767a59645b82a0b521206e1e25c2/pyyaml-6.0.3.tar.gz"
    sha256 "d76623373421df22fb4cf8817020cbb7ef15c725b9d5e45f17e189bfc384190f"
  end

  resource "websocket-client" do
    url "https://files.pythonhosted.org/packages/2c/41/aa4bf9664e4cda14c3b39865b12251e8e7d239f4cd0e3cc1b6c2ccde25c1/websocket_client-1.9.0.tar.gz"
    sha256 "9e813624b6eb619999a97dc7958469217c3176312b3a16a4bd1bc7e08a46ec98"
  end

  resource "setuptools" do
    url "https://files.pythonhosted.org/packages/18/5d/3bf57dcd21979b887f014ea83c24ae194cfcd12b9e0fda66b957c69d1fca/setuptools-80.9.0.tar.gz"
    sha256 "f36b47402ecde768dbfafc46e8e4207b4360c654f1f3bb84475f0a28628fb19c"
  end

  resource "pycamilladsp" do
    url "https://github.com/HEnquist/pycamilladsp.git",
        tag:      "v4.0.0",
        revision: "fdc0d163e02dd73206a493402b43c83502ad83d7"
  end

  def install
    venv = virtualenv_create(libexec, "python3.14", system_site_packages: false)
    venv.pip_install resources

    app = libexec / "app"
    app.install Dir["*.py"]

    cd app do
      system "#{libexec}/bin/python", "ca_listener_build.py"
    end

    (bin / "camilladsp-controller").write <<~SH
      #!/bin/bash
      exec "#{libexec}/bin/python" "#{app}/controller.py" "$@"
    SH
  end

  service do
    run [
      opt_bin/"camilladsp-controller",
      "-p", "1234",
      "-a", "#{var}/camilladsp-controller/config.yml"
    ]
    keep_alive true
    log_path var/"log/camilladsp-controller.log"
    error_log_path var/"log/camilladsp-controller.error.log"
    working_dir "#{var}/camilladsp-controller"
    environment_variables CAMILLADSP_PORT: "1234"
  end

  def caveats
    <<~EOS
      camilladsp-controller is now a Homebrew service. To enable it:
        1. Drop your controller config at #{var}/camilladsp-controller/config.yml
        2. brew services start fabioluciano/camilladsp/camilladsp-controller

      Required flags (already wired by the service stanza):
        -p 1234   WebSocket port (matches camilladsp -p 1234)
        -a PATH   Single-config mode pointing at the above YAML

      The macOS CoreAudio listener uses a small CFFI binding built at install.
      Xcode Command Line Tools are required.
    EOS
  end

  test do
    assert_match "--port", shell_output("#{bin}/camilladsp-controller --help")

    shell_output("#{bin}/camilladsp-controller 2>&1", 2)

    shell_output("#{bin}/camilladsp-controller -p 1234 2>&1", 2)
  end
end
