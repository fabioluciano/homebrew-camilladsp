class CamilladspConfig < Formula
  desc "Reference configurations and examples for CamillaDSP"
  homepage "https://github.com/HEnquist/camilladsp-config"
  url "https://github.com/HEnquist/camilladsp-config.git",
      revision: "ac18c5b23405928d4e1d81b962b8dd23ebf1f092"
  version "2023.01.21"
  license "GPL-3.0-only"
  head "https://github.com/HEnquist/camilladsp-config.git", branch: "master"

  livecheck do
    skip "No upstream tags; version is the commit date of the master/main branch"
  end

  def install
    pkgshare.install Dir["*"]
  end

  def caveats
    <<~EOS
      Example configurations were installed in:
        #{opt_pkgshare}

      Copy an example into ~/.config/camilladsp and adapt its devices,
      channels, filters, and pipeline before starting CamillaDSP.
    EOS
  end

  test do
    # pkgshare is the install destination for the upstream reference
    # configurations; it must exist and contain real, parseable artifacts
    # (not just non-empty files — they must be valid YAML documents).
    assert_predicate pkgshare, :directory?

    readme = pkgshare / "README.md"
    assert_path_exists readme
    assert_predicate readme, :file?
    refute_empty readme.read, "expected pkgshare/README.md to be non-empty"

    # At least one example YAML configuration must ship in pkgshare
    # (upstream publishes `alsaconfig.yml` and `pipewire.conf`).
    example_yamls = Dir[pkgshare / "*.yml"]
    refute_empty example_yamls, "expected at least one example *.yml in pkgshare"
    example_yamls.each do |yml|
      assert_predicate Pathname.new(yml), :file?
      refute_empty File.read(yml), "expected #{File.basename(yml)} to be non-empty"
    end

    # Happy contract: every shipped *.yml is a parseable YAML document
    # (real contract, not just presence). Catches a broken upstream
    # release that ships a truncated or corrupted config file.
    require "yaml"
    example_yamls.each do |yml|
      parsed = YAML.safe_load_file(
        yml,
        permitted_classes: [Symbol],
        aliases:           true,
      )
      assert_kind_of Hash, parsed,
                     "expected #{File.basename(yml)} to parse as a YAML mapping"
      refute_empty parsed,
                   "expected #{File.basename(yml)} to parse as a non-empty YAML mapping"
    end

    # Failure contract: a deliberately malformed YAML document is rejected
    # by the same parser that validates the shipped artifacts. This proves
    # the parser is doing real work (not silently accepting anything) and
    # pins the contract for future pkgshare contents.
    require "tempfile"
    Tempfile.create(["broken", ".yml"], testpath) do |bad|
      bad.write("this is: not: valid: yaml: [\n")
      bad.flush
      shell_output(<<~SH, 1)
        ruby -ryaml -e 'YAML.safe_load_file(
          #{bad.path.to_s.inspect},
          permitted_classes: [Symbol],
          aliases: true,
        )' 2>&1
      SH
    end

    # Failure contract: pkgshare must NOT contain executable files
    # (this formula ships data only; binaries belong to `camilladsp`).
    shell_output("test -z \"$(find #{pkgshare} -type f -perm -u+x 2>/dev/null)\"")
  end
end
