#!/usr/bin/env ruby
# frozen_string_literal: true

# Scope-fidelity check for the camilladsp Homebrew tap (Todo 5).
#
# Enforces the plan's anti-slop guardrails so a future contributor cannot
# silently weaken the contracts this tap has committed to. Every check
# here is reversible by editing this file (which then requires a PR and
# an updated `--baseline-file`); they are NOT defaults that can be
# disabled at the CI level.
#
# User invariant (2026-08-01): "Toda vez que tiver uma nova tag, [o tap]
# tem que buildar [e] disponibilizar para as pessoas uma nova versão."
# This invariant is enforced upstream by the CI workflows `audit.yml`
# (runs `brew style` + `brew install` + `brew test` on every push/PR)
# and `update.yml` (opens the update PR after `scripts/update_versions.py`
# pins real arch-specific SHA-256 values). The contract tests in this
# directory are the local safety net that mirrors what CI enforces, so
# the same invariant holds in a developer laptop or pre-commit hook.
#
# Checks:
#   1. The cask must NOT use `sha256 :no_check` (real arch-specific
#      hashes are required; this guard rail is upstream-driven).
#   2. The Brewfile must be canonical: `tap`, then `brew .../camilladsp-suite`,
#      then `cask .../camillagui`, in that order, with no duplicates.
#   3. No `brew bundle cleanup --force` may appear in any documentation
#      or caveats block; cleanup in this tap means only stopping and
#      uninstalling the camilladsp launchd service.
#   4. Every Python formula must declare `system_site_packages: false`.
#   5. Every launcher that wraps a Python script must exec the venv
#      interpreter (`#{libexec}/bin/python`); the global system Python
#      (`/usr/bin/python3`) and Homebrew-managed non-venv pythons
#      (`formula_opt_bin("python@3.14")`) are NOT allowed.
#   6. At least one audio test must explicitly disclaim real CoreAudio
#      hardware (the runner never captures or plays audio).
#   7. The README must not document behavior the implementation does not
#      have (e.g. claiming `:no_check` was removed only after a real pin,
#      when the cask already has the real pin).
#
# This file is also invoked from the F4 CI job as
# `ruby -Ilib -Itest test/scope_check.rb --baseline-file <path> --json-out <path>`,
# but it also runs standalone.
#
# Run:
#   ruby -Ilib -Itest test/scope_check.rb
#       Run every guardrail in standalone mode and exit non-zero on any
#       violation.
#   ruby -Ilib -Itest test/scope_check.rb --baseline-file <path>
#       Validate that the recorded baseline SHA is reachable from HEAD.
#   ruby -Ilib -Itest test/scope_check.rb --json-out <path>
#       Also write a machine-readable JSON report.
#
# Stdlib only: minitest, json, optparse, pathname, open3.

require 'minitest/autorun'
require 'json'
require 'open3'
require 'optparse'
require 'pathname'

SCHEMA_VERSION = 1
DEFAULT_REPO_ROOT = Pathname(__FILE__).realpath.parent.parent

# Capture every test run so the optional --json-out summary can report
# pass/fail/skip per method. We hook `Minitest::Test#run` once at load
# time and accumulate the post-run instance in a global array; the
# `Minitest.after_run` callback installed by `main` walks that array to
# produce the machine-readable summary.
SCOPE_CHECK_RUN_RESULTS = []

module Minitest
  class Test
    alias __scope_check_orig_run run

    def run(*args)
      result = __scope_check_orig_run(*args)
      SCOPE_CHECK_RUN_RESULTS << self
      result
    end
  end
end

# A future contributor can add NEW checks by adding a method to the
# `ScopeCheck` class below; the runner will pick them up automatically.

# Anti-slop phrases that MUST appear in at least one test do block.
# The runner must be able to grep for these and find them; the test do
# blocks are the only place we are willing to spend real-estate on the
# "we did NOT exercise CoreAudio" claim.
ANTI_SLOP_CORE_AUDIO_PHRASES = [
  'does not exercise CoreAudio',
  'does NOT exercise CoreAudio',
  'does not exercise coreaudio',
  'parse-only test',
  'parse-only contract test',
  'no CoreAudio hardware',
  'no real audio',
  'explicit anti-slop guardrail'
].freeze

class ScopeCheck < Minitest::Test
  class << self
    attr_accessor :repo_root
  end

  def setup
    @repo_root = self.class.repo_root
    @formula_dir = @repo_root / 'Formula'
    @cask_dir = @repo_root / 'Casks'
  end

  # --- 1. cask must NOT use :no_check -----------------------------
  def test_cask_has_no_no_check
    cask = @cask_dir / 'camillagui.rb'
    flunk("cask missing: #{cask}") unless cask.exist?
    text = File.read(cask.to_s, encoding: 'utf-8')
    refute_includes text, 'sha256 :no_check',
                    'cask must NOT use `sha256 :no_check`; the upstream assets have ' \
                    'real arch-specific SHA-256 values that must be pinned'
  end

  # --- 2. Brewfile canonical order ---------------------------------
  def test_brewfile_canonical
    brewfile = @repo_root / 'Brewfile'
    flunk("Brewfile missing: #{brewfile}") unless brewfile.exist?
    text = File.read(brewfile.to_s, encoding: 'utf-8')
    lines = text.split("\n").map(&:strip).reject { |l| l.empty? || l.start_with?('#') }
    expected = [
      'tap "fabioluciano/camilladsp"',
      'brew "fabioluciano/camilladsp/camilladsp-suite"',
      'cask "fabioluciano/camilladsp/camillagui"'
    ]
    assert_equal expected, lines,
                 "Brewfile must be canonical (tap, brew suite, cask) in that order.\n" \
                 "  expected: #{expected}\n  actual:   #{lines}"
    # No duplicate entries
    assert_equal lines.length, lines.uniq.length,
                 "Brewfile contains duplicates: #{lines}"
  end

  # --- 3. no `brew bundle cleanup --force` in docs/caveats ---------
  def test_no_cleanup_force_in_docs
    offenders = []
    allowance_markers = [
      'do not use',
      'do not run',
      'do not invoke',
      'must not use',
      'must not run',
      'should not use',
      'prohibit',
      'prohibits'
    ]
    command_token = 'brew bundle cleanup --force'

    is_prohibition = lambda { |paragraph|
      lower = paragraph.downcase
      allowance_markers.any? { |marker| lower.include?(marker) }
    }

    scan_text = lambda do |path_name, text|
      lines = text.split("\n")
      lines.each_with_index do |line, idx|
        line_number = idx + 1
        next unless line.include?(command_token)

        window_start = [0, line_number - 6].max
        window_end = [lines.length, line_number + 5].min
        window = lines[window_start...window_end].join("\n")
        next if is_prohibition.call(window)

        offenders << "#{path_name}:#{line_number}: #{line.strip}"
      end
    end

    if @formula_dir.directory?
      @formula_dir.glob('*.rb').each do |path|
        scan_text.call(path.basename.to_s, File.read(path.to_s, encoding: 'utf-8'))
      end
    end
    if @cask_dir.directory?
      @cask_dir.glob('*.rb').each do |path|
        scan_text.call(path.basename.to_s, File.read(path.to_s, encoding: 'utf-8'))
      end
    end
    [@repo_root / 'README.md', @repo_root / 'CONTRIBUTING.md'].each do |path|
      next unless path.exist?

      scan_text.call(path.basename.to_s, File.read(path.to_s, encoding: 'utf-8'))
    end
    assert_empty offenders,
                 'positive form of `brew bundle cleanup --force` found in ' \
                 "docs/caveats: #{offenders}"
  end

  # --- 4. every Python formula has system_site_packages: false ----
  def test_python_formulae_isolate_venv
    offenders = []
    return unless @formula_dir.directory?

    @formula_dir.glob('*.rb').sort.each do |path|
      text = File.read(path.to_s, encoding: 'utf-8')
      next unless text.include?('Language::Python::Virtualenv')

      offenders << "#{path.basename}: uses system_site_packages: true" if text.include?('system_site_packages: true')
      unless text.include?('system_site_packages: false')
        offenders << "#{path.basename}: uses Language::Python::Virtualenv but does " \
                      'NOT explicitly set system_site_packages: false'
      end
    end
    assert_empty offenders,
                 "Python formulae must declare system_site_packages: false: #{offenders}"
  end

  # --- 5. every launcher uses the venv interpreter -----------------
  def test_launchers_use_venv_python
    offenders = []
    return unless @formula_dir.directory?

    launcher_re = %r{\(bin\s*/\s*["']([^"']+)["']\)\.write}m
    @formula_dir.glob('*.rb').sort.each do |path|
      text = File.read(path.to_s, encoding: 'utf-8')
      next unless text.include?('Language::Python::Virtualenv')

      text.to_enum(:scan, launcher_re).each do
        m = Regexp.last_match
        line_number = text[0...m.begin(0)].count("\n") + 1
        launcher_name = m[1]
        window = text[m.end(0)..(m.end(0) + 800)]
        exec_match = window.match(/exec\s+["']([^"']+)["']/)
        if exec_match.nil?
          offenders << "#{path.basename}:#{line_number}: launcher " \
                        "#{launcher_name.inspect} has no `exec` line"
          next
        end
        exec_line = exec_match[1]
        if exec_line.include?('/usr/bin/python')
          offenders << "#{path.basename}:#{line_number}: launcher " \
                        "#{launcher_name.inspect} uses global Python: #{exec_line.inspect}"
        end
        if exec_line.include?('formula_opt_bin')
          offenders << "#{path.basename}:#{line_number}: launcher " \
                        "#{launcher_name.inspect} uses formula_opt_bin " \
                        "(NOT the venv): #{exec_line.inspect}"
        end
        if exec_line.include?('python@3.14')
          offenders << "#{path.basename}:#{line_number}: launcher " \
                        "#{launcher_name.inspect} uses Homebrew python@3.14 " \
                        "(NOT the venv): #{exec_line.inspect}"
        end
        next if exec_line.include?('#{libexec}/bin/python')

        offenders << "#{path.basename}:#{line_number}: launcher " \
                      "#{launcher_name.inspect} does not exec the venv python: " \
                      "#{exec_line.inspect}"
      end
    end
    assert_empty offenders,
                 "Python launchers must exec the venv python: #{offenders}"
  end

  # --- 6. at least one audio test does NOT claim real CoreAudio ---
  def test_audio_test_claims_parse_only
    offenders = []
    found = false
    return unless @formula_dir.directory?

    @formula_dir.glob('*.rb').sort.each do |path|
      text = File.read(path.to_s, encoding: 'utf-8')
      m = text.match(/test do\s*(.*?)\n  end\b/m)
      next if m.nil?

      block = m[1]
      ANTI_SLOP_CORE_AUDIO_PHRASES.each do |phrase|
        if block.include?(phrase)
          found = true
          break
        end
      end
      if block.include?('captures real audio') || block.include?('real CoreAudio was exercised')
        offenders << "#{path.basename}: test do claims real CoreAudio was exercised"
      end
    end
    assert found,
           'at least one test do block must explicitly disclaim real CoreAudio ' \
           "hardware (one of: #{ANTI_SLOP_CORE_AUDIO_PHRASES})"
    assert_empty offenders, "audio test drift: #{offenders}"
  end

  # --- 7. README does not document behavior not implemented --------
  def test_readme_does_not_lie
    readme = @repo_root / 'README.md'
    flunk("README.md missing: #{readme}") unless readme.exist?
    text = File.read(readme.to_s, encoding: 'utf-8')
    offenders = []
    text.split("\n").each_with_index do |line, idx|
      line_number = idx + 1
      next unless line.include?(':no_check')

      lower = line.downcase
      if lower.include?('no `:no_check`') ||
         lower.include?('not use `:no_check`') ||
         lower.include?('no `sha256 :no_check`') ||
         lower.include?('without `:no_check`') ||
         lower.include?('initially uses `:no_check`') ||
         lower.include?('initially used `:no_check`') ||
         lower.include?('is replaced with') ||
         lower.include?('is replaced by') ||
         lower.include?('running `scripts/update_versions.py` replaces')
        next
      end

      offenders << "README.md:#{line_number} mentions `:no_check` in a positive " \
                   'form; the cask already ships real arch-specific hashes'
    end
    if text =~ /audio (?:was|is) exercised/i
      offenders << 'README claims audio was exercised; the runner has no ' \
                   'CoreAudio hardware, so this is a real contract drift'
    end
    assert_empty offenders, "README claims unverified: #{offenders}"
  end
end

class BaselineCheck < Minitest::Test
  class << self
    attr_accessor :baseline_sha, :baseline_file
  end

  def test_baseline_sha_is_ancestor
    sha = self.class.baseline_sha
    source = 'inline --baseline-sha'
    if sha.nil? || sha.empty?
      baseline_file = self.class.baseline_file
      if baseline_file && baseline_file.exist?
        sha = File.read(baseline_file.to_s, encoding: 'utf-8').strip
        source = "file #{baseline_file}"
      end
    end
    return if sha.nil? || sha.empty?
    return unless sha.match?(/\A[0-9a-f]{40}\z/)

    _, err, status = Open3.capture3('git', 'merge-base', '--is-ancestor', sha, 'HEAD')
    assert_equal 0, status.exitstatus,
                 "baseline SHA #{sha} (from #{source}) is NOT an ancestor " \
                 'of HEAD; the recorded baseline has been rewritten, which ' \
                 "invalidates every artifact checksum downstream\n" \
                 "git stderr: #{err}"
  end
end

def parse_options(argv)
  options = {
    json_out: nil,
    repo_root: ENV['TAP_REPO_ROOT'] ? Pathname(ENV['TAP_REPO_ROOT']) : DEFAULT_REPO_ROOT,
    baseline_file: nil,
    baseline_sha: nil
  }
  OptionParser.new do |opts|
    opts.banner = 'Usage: scope_check.rb [options]'
    opts.on('--repo-root PATH', 'tap repository root') { |p| options[:repo_root] = Pathname(p) }
    opts.on('--baseline-file PATH', 'recorded baseline SHA from a file (F4 fallback)') do |p|
      options[:baseline_file] = Pathname(p)
    end
    opts.on('--baseline-sha SHA', 'baseline SHA inline (40-hex). Preferred; avoids tracked baseline files.') do |v|
      options[:baseline_sha] = v
    end
    opts.on('--json-out PATH', 'write a machine-readable summary to PATH') { |p| options[:json_out] = Pathname(p) }
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
  ScopeCheck.repo_root = repo_root
  # Resolve the baseline SHA in priority order: --baseline-sha, then
  # --baseline-file, then inline `git rev-list --max-parents=0 HEAD`.
  # Inline derivation is the safe default: it never reads a tracked
  # file whose contents would create a circular dependency with the
  # commit that contains the file.
  baseline_sha = options[:baseline_sha]
  baseline_sha = nil unless baseline_sha && baseline_sha.match?(/\A[0-9a-f]{40}\z/)
  if baseline_sha.nil? && options[:baseline_file] && options[:baseline_file].exist?
    baseline_sha = File.read(options[:baseline_file].to_s, encoding: 'utf-8').strip
    baseline_sha = nil unless baseline_sha.match?(/\A[0-9a-f]{40}\z/)
  end
  baseline_sha = `git rev-list --max-parents=0 HEAD 2>/dev/null | head -n 1`.strip if baseline_sha.nil?
  abort 'no baseline SHA resolved' unless baseline_sha.match?(/\A[0-9a-f]{40}\z/)
  BaselineCheck.baseline_sha = baseline_sha
  BaselineCheck.baseline_file = options[:baseline_file]
  json_out_path = options[:json_out]
  if json_out_path
    Minitest.after_run do
      checks = SCOPE_CHECK_RUN_RESULTS.map do |instance|
        name = "#{instance.class.name}##{instance.name}"
        if instance.skipped?
          { name: name, status: 'skip', message: instance.skip_message || '' }
        elsif instance.failure
          failure = instance.failure
          message = failure.respond_to?(:message) ? failure.message.to_s : failure.to_s
          { name: name, status: 'fail', message: message }
        else
          { name: name, status: 'pass', message: '' }
        end
      end
      any_failed = SCOPE_CHECK_RUN_RESULTS.any? { |i| !i.passed? && !i.skipped? }
      summary = {
        schema_version: SCHEMA_VERSION,
        result: any_failed ? 'fail' : 'pass',
        checks: checks
      }
      json_out_path = Pathname(json_out_path)
      json_out_path.dirname.mkpath
      json_out_path.write(JSON.pretty_generate(summary))
    end
  end
  0
end

exit main(ARGV) if __FILE__ == $PROGRAM_NAME
