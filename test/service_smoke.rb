#!/usr/bin/env ruby
# frozen_string_literal: true

# Service-stanza contract test for the camilladsp Homebrew tap (Todo 5).
#
# Validates the `service do` block of `Formula/camilladsp.rb` by parsing
# the formula source. We do NOT start launchd: the test is bounded and
# hermetic. The contract pinned here is the one Homebrew generates for
# `brew services start`: every flag, working directory and persistence
# flag must match the documented upstream contract, otherwise a service
# restart would either ignore the statefile or load it as a device YAML.
#
# Run:
#   ruby -Ilib -Itest test/service_smoke.rb
#       Validate the service stanza of the camilladsp formula in this tap.
#   ruby -Ilib -Itest test/service_smoke.rb --json-out <path>
#       Also write a machine-readable summary.
#
# Stdlib only: minitest, json, optparse, pathname.

require 'minitest/autorun'
require 'json'
require 'optparse'
require 'pathname'

SCHEMA_VERSION = 1
DEFAULT_REPO_ROOT = Pathname(__FILE__).realpath.parent.parent

# Documented upstream contract: see CONTRIBUTING.md and
# `.omo/notepads/camilladsp-homebrew-tap-audit/learnings.md` Todo 2.
#
# Engine `-p, --port` enables the websocket server (required when `-w`
# is set so the GUI can connect). `-w, --wait` starts the server without
# a config file (the GUI uploads one). `-s, --statefile` is the state
# file (NOT a device YAML). The statefile is persisted in `var/` so it
# survives package upgrades and is not world-readable.
EXPECTED_RUN = [
  'opt_bin/camilladsp',
  '-p',
  '1234',
  '-w',
  '-s',
  'var/camilladsp/statefile.yml'
].freeze
EXPECTED_WORKING_DIR = 'var/camilladsp'
EXPECTED_KEEP_ALIVE = true
# `run_type` defaults to "background" if absent. The engine is a long-lived
# websocket server, so background is the right choice. We allow the stanza
# to either omit it (defaulting to background) or declare it explicitly.
ALLOWED_RUN_TYPES = [nil, 'background', 'interval', 'cron'].freeze

class ServiceContractTest < Minitest::Test
  class << self
    attr_accessor :repo_root
  end

  def setup
    @repo_root = self.class.repo_root
    @formula_path = @repo_root / 'Formula' / 'camilladsp.rb'
    return if @formula_path.exist?

    raise Minitest::Skip, "missing formula: #{@formula_path}"
  end

  def extract_service_block(text)
    m = text.match(/^\s*service\s+do\s*\n(.*?)\n\s*end\b/m)
    flunk("#{@formula_path}: no `service do ... end` block found") if m.nil?
    m[1]
  end

  def tokenize_run_array(block)
    m = block.match(/run\s*\[(.*?)\]\s*$/m)
    flunk('service do block has no `run [...]` array') if m.nil?
    raw = m[1]
    elements = raw.split(',').map(&:strip)
    normalized = []
    elements.each do |elem|
      next if elem.empty?

      elem = elem.gsub(%r{\bopt_bin\s*/\s*["']([^"']+)["']}, 'opt_bin/\1')
      elem = elem.gsub(%r{#{Regexp.escape('#{var}')}/([^"'\s]+)}, 'var/\1')
      elem = elem.tr(%q("'), '')
      normalized << elem
    end
    normalized
  end

  def test_run_array_matches_contract
    text = File.read(@formula_path.to_s, encoding: 'utf-8')
    block = extract_service_block(text)
    actual = tokenize_run_array(block)
    assert_equal EXPECTED_RUN, actual,
                 "camilladsp `service do run [...]` drifted from contract.\n" \
                 "  expected: #{EXPECTED_RUN}\n  actual:   #{actual}"
  end

  def test_working_dir_is_var_camilladsp
    text = File.read(@formula_path.to_s, encoding: 'utf-8')
    block = extract_service_block(text)
    m = block.match(%r{working_dir\s+["'](#\{var\}/[^"']+)["']})
    flunk('service do block has no `working_dir "#{var}/..."` line') if m.nil?
    working_dir = m[1]
    normalized = working_dir.sub('#{var}/', 'var/')
    assert_equal EXPECTED_WORKING_DIR, normalized,
                 "working_dir drifted from contract.\n" \
                 "  expected: #{EXPECTED_WORKING_DIR}\n  actual:   #{normalized}"
  end

  def test_keep_alive_is_true
    text = File.read(@formula_path.to_s, encoding: 'utf-8')
    block = extract_service_block(text)
    m = block.match(/keep_alive\s+(true|false)/)
    flunk('service do block has no `keep_alive` setting') if m.nil?
    assert_equal(EXPECTED_KEEP_ALIVE ? 'true' : 'false', m[1],
                 'keep_alive drifted from contract ' \
                 "(engine must restart on crash: expected #{EXPECTED_KEEP_ALIVE})")
  end

  def test_run_type_is_sensible
    text = File.read(@formula_path.to_s, encoding: 'utf-8')
    block = extract_service_block(text)
    m = block.match(/run_type\s+["']([^"']+)["']/)
    run_type = m ? m[1] : nil
    assert_includes ALLOWED_RUN_TYPES, run_type,
                    "run_type #{run_type.inspect} is not in the allowed set #{ALLOWED_RUN_TYPES}"
  end

  def test_log_paths_present
    text = File.read(@formula_path.to_s, encoding: 'utf-8')
    block = extract_service_block(text)
    log_regex = %r{log_path\s+(?:#\{var\}/log/camilladsp\.log|var\s*/\s*["']log/camilladsp\.log["'])}
    error_regex = %r{error_log_path\s+(?:#\{var\}/log/camilladsp\.error\.log|var\s*/\s*["']log/camilladsp\.error\.log["'])}
    assert_match log_regex, block,
                 'service do block must declare `log_path` under var/log'
    assert_match error_regex, block,
                 'service do block must declare `error_log_path` under var/log'
  end

  def test_no_statefile_as_device_yaml
    text = File.read(@formula_path.to_s, encoding: 'utf-8')
    block = extract_service_block(text)
    run = tokenize_run_array(block)
    # The positional configfile (if any) must not be the statefile path.
    run[1..].each do |token|
      next unless token.include?('statefile')
      next if token == '-s'
      next if token == 'var/camilladsp/statefile.yml'

      flunk("statefile path appears outside the `-s` slot: #{token.inspect}")
    end
  end
end

def parse_options(argv)
  options = {
    json_out: nil,
    repo_root: ENV['TAP_REPO_ROOT'] ? Pathname(ENV['TAP_REPO_ROOT']) : DEFAULT_REPO_ROOT
  }
  OptionParser.new do |opts|
    opts.banner = 'Usage: service_smoke.rb [options]'
    opts.on('--json-out PATH', 'write a machine-readable summary to PATH') { |p| options[:json_out] = Pathname(p) }
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
  ServiceContractTest.repo_root = repo_root
  0
end

exit main(ARGV) if __FILE__ == $PROGRAM_NAME
