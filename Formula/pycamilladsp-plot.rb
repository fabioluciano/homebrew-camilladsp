class PycamilladspPlot < Formula
  include Language::Python::Virtualenv

  desc "Validate, evaluate, and plot CamillaDSP configurations and filters"
  homepage "https://github.com/HEnquist/pycamilladsp-plot"
  url "https://github.com/HEnquist/pycamilladsp-plot.git",
      tag:      "v4.1.0",
      revision: "e865ea2db6c9d1bac050a0d1c1144b8cc27c555a"
  license "GPL-3.0-only"
  head "https://github.com/HEnquist/pycamilladsp-plot.git", branch: "master"

  livecheck do
    url :stable
    strategy :github_latest
  end

  depends_on "libyaml"
  depends_on "numpy"
  depends_on "python-matplotlib"
  depends_on "python@3.14"
  depends_on "rpds-py"

  resource "attrs" do
    url "https://files.pythonhosted.org/packages/9a/8e/82a0fe20a541c03148528be8cac2408564a6c9a0cc7e9171802bc1d26985/attrs-26.1.0.tar.gz"
    sha256 "d03ceb89cb322a8fd706d4fb91940737b6642aa36998fe130a9bc96c985eff32"
  end

  resource "pyyaml" do
    url "https://files.pythonhosted.org/packages/05/8e/961c0007c59b8dd7729d542c61a4d537767a59645b82a0b521206e1e25c2/pyyaml-6.0.3.tar.gz"
    sha256 "d76623373421df22fb4cf8817020cbb7ef15c725b9d5e45f17e189bfc384190f"
  end

  resource "referencing" do
    url "https://files.pythonhosted.org/packages/22/f5/df4e9027acead3ecc63e50fe1e36aca1523e1719559c499951bb4b53188f/referencing-0.37.0.tar.gz"
    sha256 "44aefc3142c5b842538163acb373e24cce6632bd54bdb01b21ad5863489f50d8"
  end

  resource "jsonschema-specifications" do
    url "https://files.pythonhosted.org/packages/19/74/a633ee74eb36c44aa6d1095e7cc5569bebf04342ee146178e2d36600708b/jsonschema_specifications-2025.9.1.tar.gz"
    sha256 "b540987f239e745613c7a9176f3edb72b832a4ac465cf02712288397832b5e8d"
  end

  resource "jsonschema" do
    url "https://files.pythonhosted.org/packages/b3/fc/e067678238fa451312d4c62bf6e6cf5ec56375422aee02f9cb5f909b3047/jsonschema-4.26.0.tar.gz"
    sha256 "0c26707e2efad8aa1bfc5b7ce170f3fccc2e4918ff85989ba9ffa9facb2be326"
  end

  def install
    venv = virtualenv_create(libexec, "python3.14", system_site_packages: false)
    venv.pip_install resources
    venv.pip_install buildpath
    bin.install_symlink libexec / "bin/plotcamillaconf"
    (bin / "pycamilladsp-plot-python").write <<~SH
      #!/bin/bash
      exec "#{libexec}/bin/python" "$@"
    SH
  end

  test do
    valid = <<~YAML
      devices:
        samplerate: 44100
        chunksize: 1024
        capture:
          type: CoreAudio
          channels: 2
        playback:
          type: CoreAudio
          channels: 2
    YAML
    (testpath / "valid.yml").write(valid)

    bad = <<~YAML
      devices:
        samplerate: 44100
        chunksize: 1024
        capture:
          type: NonExistent
          channels: 2
        playback:
          type: CoreAudio
          channels: 2
    YAML
    (testpath / "bad.yml").write(bad)

    validate_code = <<~PY
      from camilladsp_plot.validate_config import CamillaValidator
      v = CamillaValidator()
      v.validate_file("#{testpath}/valid.yml")
      errors = [e for e in v.get_errors() if e[2] == "error"]
      raise SystemExit(1 if errors else 0)
    PY
    shell_output("#{bin}/pycamilladsp-plot-python -c #{validate_code.shellescape}")

    assert_match "config has errors", shell_output("#{bin}/plotcamillaconf #{testpath}/bad.yml 2>&1")

    shell_output("#{bin}/plotcamillaconf #{testpath}/missing.yml 2>&1", 1)
  end
end
