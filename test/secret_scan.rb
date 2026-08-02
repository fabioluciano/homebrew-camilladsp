#!/usr/bin/env ruby
# frozen_string_literal: true

# Credential scan for the camilladsp Homebrew tap (Todo 5).
#
# Statically scans the tap repository (Formula, Casks, scripts, workflows
# and the docs) for any credential patterns that would leak a real secret
# into the published tap. Exits non-zero with the file:line of every hit
# so the CI can fail loudly.
#
# Excluded paths (intentionally not scanned):
#   * ``node_modules/`` -- third-party JS dependencies
#   * ``.venv/``        -- local Python virtual environments
#   * ``.git/``         -- git metadata
#   * ``.omo/``         -- orchestration evidence/notepads
#   * ``test/fixtures/``-- test fixtures (intentional placeholder secrets)
#
# Patterns detected (each is documented inline):
#   * ``gh[ps]_[A-Za-z0-9]{36}``    -- GitHub personal access / OAuth tokens
#   * ``AKIA[0-9A-Z]{16}``          -- AWS access key IDs
#   * ``password\s*=\s*['"][^'"]+['"]``  -- literal password assignments
#   * ``token\s*=\s*['"][^'"]+['"]``      -- literal token assignments
#   * ``Bearer [A-Za-z0-9._-]{20,}`` -- HTTP Authorization bearer tokens
#   * ``-----BEGIN ... PRIVATE KEY-----`` -- PEM private keys
#   * ``eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+``
#         -- JWT three-segment base64 (header.payload.signature)
#   * ``.env`` references to real-looking keys
#         -- ``.env`` filenames paired with ``key=``/``secret=``/``token=``
#
# False positives in fixtures/literals are tolerable ONLY if documented;
# the patterns above are intentionally tight to keep noise low.
#
# Run:
#   ruby -Ilib -Itest test/secret_scan.rb
#       Scan the tap root and print any hits.
#   ruby -Ilib -Itest test/secret_scan.rb --json-out <path>
#       Also write a machine-readable JSON report.
#
# Stdlib only: minitest, json, optparse, pathname, digest/sha2.

require 'minitest/autorun'
require 'json'
require 'optparse'
require 'pathname'

SCHEMA_VERSION = 1
DEFAULT_REPO_ROOT = Pathname(__FILE__).realpath.parent.parent

# Paths that the scanner is allowed to inspect.
INCLUDED_GLOBS = [
  'Formula/*.rb',
  'Casks/*.rb',
  'scripts/*',
  '.github/workflows/*',
  '*.md',
  '*.yml',
  '*.yaml'
].freeze

# Path substrings that the scanner explicitly skips.
EXCLUDED_SUBSTRINGS = %w[
  node_modules
  .venv
  .git
  .omo
  test/fixtures
  __pycache__
  .ruff_cache
  .DS_Store
].freeze

# Patterns: name -> compiled regex. The `password` / `token` patterns are
# intentionally tight (require non-trivial value, exclude obvious var names).
PATTERNS = {
  'github_pat' => /gh[ps]_[A-Za-z0-9]{36}/,
  'aws_access_key' => /AKIA[0-9A-Z]{16}/,
  'password_literal' => /(?<![A-Za-z0-9_])password\s*[:=]\s*['"]([^'"\\\n]{4,})['"]/i,
  'token_literal' => %r{(?<![A-Za-z0-9_])token\s*[:=]\s*['"]([A-Za-z0-9._/+=-]{20,})['"]}i,
  'bearer_header' => /Bearer\s+[A-Za-z0-9._-]{20,}/,
  'pem_private_key' => /-----BEGIN [A-Z ]+PRIVATE KEY-----/,
  'jwt_three_segment' => /eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/,
  'env_with_key_pair' => %r{\.env["']?\s*[)\],]?\s*$|^\s*(?:export\s+)?[A-Z][A-Z0-9_]*(?:KEY|SECRET|TOKEN|PASSWORD)\s*=\s*[A-Za-z0-9._/+=-]{8,}}m
}.freeze

# Lines that are KNOWN to contain a placeholder token (e.g. `ghp_xxx`,
# `xxxxxxxxxxxx`, `your-token-here`). The scanner ignores these as
# documentation noise; a future contributor can still use them in docs
# without tripping CI.
PLACEHOLDER_LITERALS = %w[
  ghp_xxx
  ghs_xxx
  gho_xxx
  your-token-here
  your_token_here
  changeme
  <your-token>
  <token>
  REDACTED
  EXAMPLE
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
].to_set.freeze

def placeholder?(match_text)
  stripped = match_text.strip.strip(%q("'))
  return true if PLACEHOLDER_LITERALS.include?(stripped)
  return true if stripped.chars.all? { |ch| 'x*X.-_<>'.include?(ch) }
  return true if stripped.chars.uniq.length <= 2 # single-char repeated strings

  false
end

def excluded?(path)
  posix = path.to_s.tr('\\', '/')
  EXCLUDED_SUBSTRINGS.any? { |excluded| posix.include?(excluded) }
end

def iter_target_files(repo_root)
  targets = Set.new
  INCLUDED_GLOBS.each do |pattern|
    targets.merge(repo_root.glob(pattern))
  end
  targets.select { |p| p.file? && !excluded?(p) }.sort
end

def scan_file(path, repo_root)
  hits = []
  text = File.read(path.to_s, encoding: 'utf-8', invalid: :replace, undef: :replace)
  text.split("\n").each_with_index do |line, idx|
    line_number = idx + 1
    PATTERNS.each do |name, regex|
      line.scan(regex) do |match|
        matched = match[0].is_a?(String) ? match[0] : match
        matched_str = matched.to_s
        next if placeholder?(matched_str)

        if %w[password_literal token_literal].include?(name)
          value = match.is_a?(Array) ? match[1] : matched_str
          next if value =~ /\A[A-Z_]+\z/ && value.include?('_')
          next if value.start_with?('$') || value.start_with?('ENV')
        end
        rel = path.relative_path_from(repo_root).to_s
        hits << {
          'file' => rel,
          'line' => line_number,
          'pattern' => name,
          'match' => matched_str
        }
      end
    end
  end
  hits
rescue SystemCallError => e
  [{ 'file' => path.to_s, 'line' => 0, 'pattern' => 'io_error', 'match' => e.message }]
end

def scan(repo_root)
  targets = iter_target_files(repo_root)
  all_hits = []
  files_scanned = 0
  targets.each do |path|
    all_hits.concat(scan_file(path, repo_root))
    files_scanned += 1
  end
  {
    'schema_version' => SCHEMA_VERSION,
    'repo_root' => repo_root.to_s,
    'files_scanned' => files_scanned,
    'hits' => all_hits,
    'clean' => all_hits.empty?
  }
end

class SecretScanTest < Minitest::Test
  class << self
    attr_accessor :repo_root, :report, :json_out
  end

  def setup
    @repo_root = self.class.repo_root
    @report ||= scan(@repo_root)
  end

  def test_no_secret_hits
    hits = @report['hits']
    return if hits.empty?

    flunk("secret scan found potential credentials: #{hits.inspect}")
  end
end

def parse_options(argv)
  options = {
    json_out: nil,
    repo_root: ENV['TAP_REPO_ROOT'] ? Pathname(ENV['TAP_REPO_ROOT']) : DEFAULT_REPO_ROOT
  }
  OptionParser.new do |opts|
    opts.banner = 'Usage: secret_scan.rb [options]'
    opts.on('--repo-root PATH', 'tap repository root') { |p| options[:repo_root] = Pathname(p) }
    opts.on('--json-out PATH', 'write a machine-readable JSON report') { |p| options[:json_out] = Pathname(p) }
    opts.on('-h', '--help', 'show this help') do
      puts opts
      exit 0
    end
  end.parse!(argv)
  options
end

def main(argv)
  require 'set'
  options = parse_options(argv)
  repo_root = options[:repo_root].realpath
  SecretScanTest.repo_root = repo_root
  report = scan(repo_root)

  if options[:json_out]
    options[:json_out].parent.mkpath
    options[:json_out].write(JSON.pretty_generate(report) + "\n")
  end

  hits = report['hits']
  unless hits.empty?
    warn 'FAIL: secret scan found potential credentials:'
    hits.each do |hit|
      warn "  #{hit['file']}:#{hit['line']} [#{hit['pattern']}] #{hit['match'].inspect}"
    end
    return 1
  end

  puts "OK: secret scan clean (#{report['files_scanned']} files scanned, 0 hits)"
  0
end

exit main(ARGV) if __FILE__ == $PROGRAM_NAME
