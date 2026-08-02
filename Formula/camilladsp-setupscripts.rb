class CamilladspSetupscripts < Formula
  include Language::Python::Virtualenv

  desc "Templates used to generate CamillaDSP and CamillaGUI setup scripts"
  homepage "https://github.com/HEnquist/camilladsp-setupscripts"
  url "https://github.com/HEnquist/camilladsp-setupscripts.git",
      tag:      "v3.0.3",
      revision: "abf52ae9397988c98a5cd789c44cf6e17c0802fb"
  license "GPL-3.0-only"
  head "https://github.com/HEnquist/camilladsp-setupscripts.git", branch: "master"

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

  resource "markupsafe" do
    url "https://files.pythonhosted.org/packages/b2/97/5d42485e71dfc078108a86d6de8fa46db44a1a9295e89c5d6d4a06e23a62/markupsafe-3.0.2.tar.gz"
    sha256 "ee55d3edf80167e48ea11a923c7386f4669df67d7994554387f84e7d8b0a2bf0"
  end

  resource "jinja2" do
    url "https://files.pythonhosted.org/packages/df/bf/f7da0350254c0ed7c72f3e33cef02e048281fec7ecec5f032d4aac52226b/jinja2-3.1.6.tar.gz"
    sha256 "0137fb05990d35f1275a587e9aee6d56da821fc83491a0fb838183be43f66d6d"
  end

  def install
    venv = virtualenv_create(libexec, "python3.14", system_site_packages: false)
    venv.pip_install resources

    pkgshare.install Dir["*"]

    (bin / "camilladsp-build-setup-scripts").write <<~SH
      #!/bin/bash
      exec "#{libexec}/bin/python" "#{opt_pkgshare}/build_release.py" "$@"
    SH
  end

  def caveats
    <<~EOS
      Upstream stores Jinja templates in the repository and publishes rendered
      installer scripts as release assets. The templates and renderer are in:
        #{opt_pkgshare}

      Render the scripts from a working directory that contains "versions.yml"
      and the "templates/" folder (both ship in the path above), for example:
        cp -R "#{opt_pkgshare}"/* ./ && mkdir -p output && camilladsp-build-setup-scripts
    EOS
  end

  test do
    work = testpath / "work"
    mkdir work
    cp pkgshare / "versions.yml", work
    cp_r pkgshare / "templates", work
    mkdir work / "output"
    cd work do
      assert_empty shell_output("#{bin}/camilladsp-build-setup-scripts 2>&1")
    end
    assert_path_exists work / "output/full_install_venv.sh"
    assert_predicate work / "output/full_install_venv.sh", :executable?

    empty = testpath / "empty"
    mkdir empty
    cd empty do
      shell_output("#{bin}/camilladsp-build-setup-scripts 2>&1", 1)
    end
  end
end
