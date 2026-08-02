class Pycamilladsp < Formula
  include Language::Python::Virtualenv

  desc "Python client library for communicating with CamillaDSP"
  homepage "https://github.com/HEnquist/pycamilladsp"
  url "https://github.com/HEnquist/pycamilladsp.git",
      tag:      "v4.0.0",
      revision: "fdc0d163e02dd73206a493402b43c83502ad83d7"
  license "GPL-3.0-only"
  head "https://github.com/HEnquist/pycamilladsp.git", branch: "master"

  livecheck do
    url :stable
    strategy :github_latest
  end

  depends_on "libyaml"
  depends_on "python@3.14"

  resource "pyyaml" do
    url "https://files.pythonhosted.org/packages/05/8e/961c0007c59b8dd7729d542c61a4d537767a59645b82a0b521206e1e25c2/pyyaml-6.0.3.tar.gz"
    sha256 "d76623373421df22fb4cf8817020cbb7ef15c725b9d5e45f17e189bfc384190f"
  end

  resource "websocket-client" do
    url "https://files.pythonhosted.org/packages/2c/41/aa4bf9664e4cda14c3b39865b12251e8e7d239f4cd0e3cc1b6c2ccde25c1/websocket_client-1.9.0.tar.gz"
    sha256 "9e813624b6eb619999a97dc7958469217c3176312b3a16a4bd1bc7e08a46ec98"
  end

  def install
    venv = virtualenv_create(libexec, "python3.14", system_site_packages: false)
    venv.pip_install resources
    venv.pip_install buildpath
    (bin / "pycamilladsp-python").write <<~SH
      #!/bin/bash
      exec "#{libexec}/bin/python" "$@"
    SH
  end

  def caveats
    <<~EOS
      pyCamillaDSP is installed in an isolated environment.
      Use its interpreter to run scripts that import the library:
        pycamilladsp-python your_script.py
    EOS
  end

  test do
    assert_match "4.0.0", shell_output("#{bin}/pycamilladsp-python -c 'import camilladsp; print(camilladsp.VERSION)'")

    shell_output("#{bin}/pycamilladsp-python -c 'import camilladsp; camilladsp.NONEXISTENT_ATTR' 2>&1", 1)
  end
end
