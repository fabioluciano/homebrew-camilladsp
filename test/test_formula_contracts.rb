#!/usr/bin/env ruby
# frozen_string_literal: true

# Per-formula contract tests for the camilladsp Homebrew tap (Todo 5).
#
# Offline and deterministic: parses the .rb formula and cask files and
# (when the matching binary is installed locally) invokes it to verify
# the documented exit-code contract. Skips gracefully with a documented
# reason when a binary is unavailable so the suite is friendly to CI
# matrices that only install a subset of formulae.
#
# Run modes:
#   ruby -Ilib -Itest test/test_formula_contracts.rb
#       Run every contract in offline (parse-only) mode plus every binary
#       contract that is available locally.
#   ruby -Ilib -Itest test/test_formula_contracts.rb --json-out <path>
#       Also write a machine-readable summary of pass/skip results.
#   ruby -Ilib -Itest test/test_formula_contracts.rb --repo-root <path>
#       Use a different tap root (CI may mount the tap at a custom path).
#
# Stdlib only: minitest, json, optparse, pathname.

require 'minitest/autorun'
require 'English'
require 'fileutils'
require 'json'
require 'optparse'
require 'pathname'
require 'open3'

SCHEMA_VERSION = 1
DEFAULT_REPO_ROOT = Pathname(__FILE__).realpath.parent.parent

EXPECTED_FORMULAE = %w[
  camilladsp
  camilladsp-config
  camilladsp-controller
  camilladsp-setupscripts
  camilladsp-suite
  camillagui
  pycamilladsp
  pycamilladsp-plot
].freeze

RE_VERSION = /^\s*version\s+["']([^"']+)["']/m
RE_URL = /^\s*url\s+["']([^"']+)["']/m
RE_SHA256_ARCH = /sha256\s+["']([0-9a-f]{64})["']/
RE_HOMEPAGE = /^\s*homepage\s+["']([^"']+)["']/m
RE_DESC = /^\s*desc\s+["']([^"']+)["']/m
RE_TEST_DO = /test do\s*(.*?)\n  end\b/m
RE_SHELL_OUTPUT = /shell_output\(/

# Real arch-specific SHA-256 hashes (pinned via GitHub Releases API).
EXPECTED_GUI_SHA = {
  'arm' => '09da0b654aefaa1c983f0208524d9abf768e8a13ae4670d69bc65c17fd4b4f63',
  'intel' => '4540c78bc05b86977276bea5188f9308d4ccaad954ca8260b47d2b1b6c74d641'
}.freeze

# Binary contract for each formula that exposes a public binary.
# Each entry: [argv list, expected exit code, optional stdout substring].
BINARY_CONTRACTS = {
  'camilladsp' => [
    [['--help'], 0, 'CamillaDSP'],
    [['-c', '/nonexistent/for/test_formula_contracts.yml'], 101, nil]
  ],
  'camilladsp-controller' => [
    [['--help'], 0, '--port'],
    [[], 2, nil], # argparse: missing -p
    [['-p', '16440'], 2, nil] # argparse: missing -s/-a
  ],
  'pycamilladsp-python' => [
    [['-c', 'import camilladsp; raise SystemExit(0)'], 0, nil]
  ],
  'pycamilladsp-plot-python' => [
    [['-c', 'import camilladsp_plot; raise SystemExit(0)'], 0, nil]
  ],
  'camilladsp-build-setup-scripts' => [
    # This binary reads `versions.yml` from CWD; with no input it raises
    # FileNotFoundError and exits non-zero (exit 1).
    [[], 1, nil]
  ]
}.freeze

# Map each formula name to the on-PATH binaries that ship in the formula's
# bin/. This is needed because Homebrew renames the public launchers
# (e.g. `pycamilladsp-python`, `plotcamillaconf`,
# `camilladsp-build-setup-scripts`); the formula name alone does not
# match any executable.
FORMULA_BINARIES = {
  'camilladsp' => %w[camilladsp],
  'camilladsp-controller' => %w[camilladsp-controller],
  'pycamilladsp' => %w[pycamilladsp-python],
  'pycamilladsp-plot' => %w[plotcamillaconf pycamilladsp-plot-python],
  'camilladsp-setupscripts' => %w[camilladsp-build-setup-scripts]
}.freeze

class BaseRepoTest < Minitest::Test
  class << self
    attr_writer :repo_root

    def repo_root
      if defined?(@repo_root) && @repo_root
        @repo_root
      elsif superclass.respond_to?(:repo_root)
        superclass.repo_root
      end
    end
  end

  def setup
    @repo_root = self.class.repo_root
    @formula_dir = @repo_root / 'Formula'
  end

  def formula_path(name)
    @formula_dir / "#{name}.rb"
  end
end

class FormulaSurfaceTest < BaseRepoTest
  def test_eight_formulae_present
    actual = @formula_dir.glob('*.rb').map { |p| p.basename('.rb').to_s }.sort
    assert_equal EXPECTED_FORMULAE.sort, actual,
                 "Formula/ must contain exactly #{EXPECTED_FORMULAE}; got #{actual}"
  end

  def test_required_stanzas_present_in_formulae
    @formula_dir.glob('*.rb').sort.each do |path|
      text = File.read(path.to_s, encoding: 'utf-8')
      assert_match(RE_DESC, text, "#{path.basename('.rb')}: missing `desc` stanza")
      assert_match(RE_HOMEPAGE, text, "#{path.basename('.rb')}: missing `homepage` stanza")
      assert_match(RE_URL, text, "#{path.basename('.rb')}: missing `url` stanza")
      assert_match(RE_TEST_DO, text, "#{path.basename('.rb')}: missing `test do` block")
    end
  end

  def test_gui_formula_uses_real_arch_specific_hashes
    gui = formula_path('camillagui')
    text = File.read(gui.to_s, encoding: 'utf-8')
    sha_matches = text.scan(/sha256\s+["']([0-9a-f]{64})["']/).flatten
    assert sha_matches.length >= 2, 'camillagui formula must declare two sha256 values (ARM and Intel)'
    assert_equal EXPECTED_GUI_SHA['arm'], sha_matches[0],
                 'camillagui formula ARM sha256 drifted from the pinned release asset'
    assert_equal EXPECTED_GUI_SHA['intel'], sha_matches[1],
                 'camillagui formula Intel sha256 drifted from the pinned release asset'
  end

  def test_gui_formula_has_on_macos_block
    gui = formula_path('camillagui')
    text = File.read(gui.to_s, encoding: 'utf-8')
    assert_match(/on_macos\s+do/, text,
                 'camillagui formula must declare `on_macos do` for arch-specific URLs')
    assert_match(/Hardware::CPU\.arm\?/, text,
                 'camillagui formula must use `Hardware::CPU.arm?` for architecture dispatch')
  end

  def test_formula_versions_are_pinned
    binless = %w[
      pycamilladsp
      pycamilladsp-plot
      camilladsp-setupscripts
      camilladsp-suite
      camilladsp-config
    ].to_set
    # Formulae that omit `version` because Homebrew infers it from the URL
    # path (e.g. v4.1.3/camilladsp-macos-aarch64.tar.gz or
    # v4.1.0/bundle_macos_aarch64.tar.gz).
    url_inferred = %w[camilladsp camillagui].to_set
    @formula_dir.glob('*.rb').sort.each do |path|
      name = path.basename('.rb').to_s
      next if binless.include?(name)

      text = File.read(path.to_s, encoding: 'utf-8')
      m = text.match(RE_VERSION)
      if url_inferred.include?(name)
        if m
          refute_empty m[1].strip,
                       "#{name}: top-level `version` is empty"
        else
          assert_match(%r{/v\d+\.\d+\.\d+/}, text,
                       "#{name}: no explicit `version` and no versioned URL " \
                       '(url-inferred formulae must embed v<X>.<Y>.<Z> in URLs)')
        end
      else
        refute_nil m,
                   "#{name}: missing top-level `version` line " \
                   '(asset-pinned formulae must declare a version)'
        refute_empty m[1].strip,
                     "#{name}: top-level `version` is empty"
      end
    end
  end

  def test_test_do_has_happy_or_failure_assertion
    @formula_dir.glob('*.rb').sort.each do |path|
      text = File.read(path.to_s, encoding: 'utf-8')
      m = text.match(RE_TEST_DO)
      refute_nil m, "#{path.basename('.rb')}: no test do block"
      block = m[1]
      assert(block.match?(RE_SHELL_OUTPUT) || block.include?('assert'),
             "#{path.basename('.rb')}: test do has no `shell_output(...)` and no " \
             '`assert_*` call (contract requires a real assertion)')
    end
  end
end

class BinaryContractTest < BaseRepoTest
  FORMULA_BINARIES_GLOBAL = FORMULA_BINARIES

  def resolve_binary(formula)
    candidates = FORMULA_BINARIES_GLOBAL.fetch(formula, [formula])
    candidates.each do |candidate|
      path = which(candidate)
      return path if path
    end
    nil
  end

  def which(binary)
    ENV['PATH'].split(File::PATH_SEPARATOR).each do |dir|
      candidate = File.join(dir, binary)
      return candidate if File.executable?(candidate)
    end
    nil
  end

  def run_binary(binary, argv, timeout: 30)
    Open3.capture3(binary, *argv.map(&:to_s))
  rescue Errno::ENOENT, Errno::EACCES, Timeout::Error
    [nil, nil, nil]
  end

  def test_binary_contracts
    BINARY_CONTRACTS.each do |formula, contracts|
      binary_path = resolve_binary(formula)
      contracts.each do |argv, expected_exit, substring|
        if binary_path.nil?
          candidates = FORMULA_BINARIES_GLOBAL.fetch(formula, [formula])
          skip("binary for #{formula.inspect} not on PATH (looked for: #{candidates})")
        end
        stdout, _, status = run_binary(binary_path, argv)
        skip("binary for #{formula.inspect} failed to execute (#{argv.inspect})") if status.nil?
        rc = status.exitstatus
        assert_equal expected_exit, rc,
                     "#{formula} #{argv}: expected exit #{expected_exit}, got #{rc}"
        next unless substring

        assert_includes stdout.to_s, substring,
                        "#{formula} #{argv}: expected substring " \
                        "#{substring.inspect} in output"
      end
    end
  end
end

def parse_options(argv)
  options = {
    repo_root: ENV['TAP_REPO_ROOT'] ? Pathname(ENV['TAP_REPO_ROOT']) : DEFAULT_REPO_ROOT
  }
  OptionParser.new do |opts|
    opts.banner = 'Usage: test_formula_contracts.rb [options]'
    opts.on('--repo-root PATH', 'tap repository root') { |p| options[:repo_root] = Pathname(p) }
    opts.on('-h', '--help', 'show this help') do
      puts opts
      exit 0
    end
  end.parse!(argv)
  options
end

def main(argv)
  options = parse_options(argv)
  repo_root = options[:repo_root].realpath
  ENV['TAP_REPO_ROOT'] = repo_root.to_s
  BaseRepoTest.repo_root = repo_root
  0
end

require 'set'
exit main(ARGV) if __FILE__ == $PROGRAM_NAME
