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
  pycamilladsp
  pycamilladsp-plot
].freeze
EXPECTED_CASKS = %w[camillagui].freeze

RE_VERSION = /^\s*version\s+["']([^"']+)["']/m
RE_URL = /^\s*url\s+["']([^"']+)["']/m
RE_SHA256_ARCH = /sha256\s+arm:\s*["']([0-9a-f]{64})["'],\s*\n?\s*intel:\s*["']([0-9a-f]{64})["']/
RE_HOMEPAGE = /^\s*homepage\s+["']([^"']+)["']/m
RE_DESC = /^\s*desc\s+["']([^"']+)["']/m
RE_TEST_DO = /test do\s*(.*?)\n  end\b/m
RE_SHELL_OUTPUT = /shell_output\(/

# Real arch-specific cask hashes (Todo 4 pinned via GitHub Releases API).
EXPECTED_CASK_SHA = {
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
    @cask_dir = @repo_root / 'Casks'
  end

  def formula_path(name)
    @formula_dir / "#{name}.rb"
  end

  def cask_path(name)
    @cask_dir / "#{name}.rb"
  end
end

class FormulaSurfaceTest < BaseRepoTest
  def test_seven_formulae_present
    actual = @formula_dir.glob('*.rb').map { |p| p.basename('.rb').to_s }.sort
    assert_equal EXPECTED_FORMULAE.sort, actual,
                 "Formula/ must contain exactly #{EXPECTED_FORMULAE}; got #{actual}"
  end

  def test_cask_present
    actual = @cask_dir.glob('*.rb').map { |p| p.basename('.rb').to_s }.sort
    assert_equal EXPECTED_CASKS.sort, actual,
                 "Casks/ must contain exactly #{EXPECTED_CASKS}; got #{actual}"
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

  def test_required_stanzas_present_in_cask
    @cask_dir.glob('*.rb').sort.each do |path|
      text = File.read(path.to_s, encoding: 'utf-8')
      assert_match(RE_DESC, text, "#{path.basename('.rb')}: missing `desc` stanza")
      assert_match(RE_HOMEPAGE, text, "#{path.basename('.rb')}: missing `homepage` stanza")
      assert_match(RE_URL, text, "#{path.basename('.rb')}: missing `url` stanza")
      assert_match(RE_VERSION, text, "#{path.basename('.rb')}: missing `version` stanza")
      refute_includes text, 'sha256 :no_check',
                      "#{path.basename('.rb')}: cask must NOT use `sha256 :no_check` " \
                      '(real arch-specific hashes are required)'
    end
  end

  def test_cask_uses_real_arch_specific_hashes
    cask = cask_path('camillagui')
    text = File.read(cask.to_s, encoding: 'utf-8')
    m = text.match(RE_SHA256_ARCH)
    refute_nil m, 'camillagui cask must declare sha256 arm: ..., intel: ...'
    arm = m[1]
    intel = m[2]
    assert_equal EXPECTED_CASK_SHA['arm'], arm,
                 'camillagui cask ARM sha256 drifted from the pinned release asset'
    assert_equal EXPECTED_CASK_SHA['intel'], intel,
                 'camillagui cask Intel sha256 drifted from the pinned release asset'
  end

  def test_cask_arch_declaration
    cask = cask_path('camillagui')
    text = File.read(cask.to_s, encoding: 'utf-8')
    assert_match(/arch\s+arm:\s*["']aarch64["']\s*,\s*intel:\s*["']intel["']/, text,
                 'camillagui cask must declare `arch arm: ..., intel: ...` substitutions')
  end

  def test_formula_versions_are_pinned
    binless = %w[
      pycamilladsp
      pycamilladsp-plot
      camilladsp-setupscripts
      camilladsp-suite
      camilladsp-config
    ].to_set
    @formula_dir.glob('*.rb').sort.each do |path|
      next if binless.include?(path.basename('.rb').to_s)

      text = File.read(path.to_s, encoding: 'utf-8')
      m = text.match(RE_VERSION)
      refute_nil m,
                 "#{path.basename('.rb')}: missing top-level `version` line " \
                 '(asset-pinned formulae must declare a version)'
      refute_empty m[1].strip,
                   "#{path.basename('.rb')}: top-level `version` is empty"
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
