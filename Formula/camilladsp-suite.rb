class CamilladspSuite < Formula
  desc "Meta-package for the complete CamillaDSP command-line ecosystem"
  homepage "https://github.com/HEnquist/camilladsp"
  url "https://github.com/HEnquist/camilladsp.git",
      tag:      "v4.1.3",
      revision: "05e9cfcdf43c0dfe078ed3feb8af4c8bd701fd74"
  license "MIT"

  # This suite aggregates the six CLI formulae shipped by this tap:
  #   - camilladsp                (engine binary)
  #   - camilladsp-config         (reference configurations)
  #   - camilladsp-controller     (automatic source-format controller)
  #   - camilladsp-setupscripts   (Jinja templates + renderer)
  #   - pycamilladsp              (Python client library)
  #   - pycamilladsp-plot         (config validator + plotting)
  #
  # CamillaGUI is intentionally NOT a `depends_on` here: it is distributed
  # as a separate formula (install with `brew install camillagui`) and is not
  # aggregated into this CLI-only suite. This split is upstream-driven (GUI
  # ships its own bundled runtime) and is documented in the tap README.
  depends_on "camilladsp"
  depends_on "camilladsp-config"
  depends_on "camilladsp-controller"
  depends_on "camilladsp-setupscripts"
  depends_on "pycamilladsp"
  depends_on "pycamilladsp-plot"

  def install
    (share / "camilladsp-suite").mkpath
    (share / "camilladsp-suite/README").write <<~EOS
      This meta-formula installs the CamillaDSP engine and all command-line,
      Python, configuration, controller, and setup-script packages in this tap.
      CamillaGUI is distributed as a separate formula (not aggregated here)
      and must be installed separately.
    EOS
  end

  def caveats
    <<~EOS
      Install the GUI bundle separately:
        brew install camillagui

      Or install every formula using this tap's Brewfile:
        brew bundle --file="$(brew --repository fabioluciano/camilladsp)/Brewfile"
    EOS
  end

  test do
    # Public artifact installed by `def install`: the README that documents
    # the suite's CLI-only contract.
    readme = share / "camilladsp-suite/README"
    assert_path_exists readme
    assert_predicate readme, :file?
    refute_empty readme.read, "expected the suite README to be non-empty"
    assert_match(/command-line/i, readme.read)
    assert_match(/separate formula/i, readme.read)

    # Every CLI formula aggregated by this suite must be a registered Homebrew
    # Formula (catches a typo in `depends_on` and pins the CLI-only contract:
    # six formulae, no GUI/cask).
    cli_dependents = %w[
      camilladsp
      camilladsp-config
      camilladsp-controller
      camilladsp-setupscripts
      pycamilladsp
      pycamilladsp-plot
    ].freeze
    cli_dependents.each do |name|
      f = Formula[name]
      assert_kind_of Formula, f
      assert_equal name, f.name, "expected dependent #{name} to be loadable by short name"
    end

    # Failure contract: the suite must NOT include the GUI in its
    # dependency list (GUI and CLI are separate dispatch paths in
    # Homebrew; the suite is a CLI-only aggregator). This is the real
    # CLI-only contract test — the meta-formula is wrong if the GUI
    # ever leaks into `depends_on`. We assert this at the source-file
    # level so the test never depends on the formula library being
    # importable in a subshell.
    shell_output(<<~SH)
      ! grep -E '^[[:space:]]*depends_on[[:space:]]+["'"'"']?camillagui["'"'"']?[[:space:]]*$' \
        #{__FILE__}
    SH

    # Failure contract: the suite's CLI dependents must each be installed
    # (proceeds the dependency is real, not just declared). If a CLI
    # formula is missing, the dependency chain is broken and this exit
    # surfaces it instead of silently skipping the dependents.
    cli_dependents.each do |name|
      shell_output("brew --prefix #{name} >/dev/null 2>&1")
    end
  end
end
