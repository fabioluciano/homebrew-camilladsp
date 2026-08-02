#!/usr/bin/env ruby
# frozen_string_literal: true

# Plan contract checks for the camilladsp Homebrew tap (audit plan, Todo 1 + 5).
#
# Offline and deterministic: reads only files inside the tap repository.
#
# Modes:
#   --inventory-only --json-out <path>
#       Verify the tap contains exactly 7 formulae and 1 cask, then emit a
#       JSON matrix mapping each package to its upstream repository/component,
#       executables, dependencies, license, architectures and install mode.
#       The Todo 5 contract checks (Python isolation, launcher venv
#       interpreter, test do shape, Brewfile canonical order) are ALSO
#       run and their results are merged into the JSON report under
#       `contracts`. Exit 0 only if every check passes; this preserves
#       the Todo 1 contract and adds the new ones in a single pass.
#   --repo-root <path>
#       Override the repository root. Used by fixture runs: when the fixture
#       lacks an expected package, the checker exits 1 and names the missing
#       package.
#   --checks-only
#       Run only the new contract checks (skip the package matrix emit).
#       Useful for F4 invocation where the inventory JSON was already
#       produced by a previous Todo 1 run.
#
# Stdlib only: minitest, json, optparse, pathname, digest/sha2.

require 'minitest/autorun'
require 'json'
require 'optparse'
require 'pathname'

SCHEMA_VERSION = 2 # bumped from 1 to record the new contract checks

EXPECTED_FORMULAE = %w[
  camilladsp
  camilladsp-config
  camilladsp-controller
  camilladsp-setupscripts
  camilladsp-suite
  pycamilladsp
  pycamilladsp-plot
].freeze

EXPECTED_CASKS = ['camillagui'].freeze

# Canonical Brewfile order (Todo 4 finding).
EXPECTED_BREWFILE = [
  'tap "fabioluciano/camilladsp"',
  'brew "fabioluciano/camilladsp/camilladsp-suite"',
  'cask "fabioluciano/camilladsp/camillagui"'
].freeze

# Human-readable upstream component labels (curated; the remaining matrix
# fields are extracted from the formula/cask files themselves).
UPSTREAM_COMPONENTS = {
  'camilladsp' => 'CamillaDSP engine (Rust CLI)',
  'camilladsp-config' => 'Reference configurations and examples',
  'camilladsp-controller' => 'Automatic source-format controller',
  'camilladsp-setupscripts' => 'Setup-script templates and renderer',
  'camilladsp-suite' => 'Meta-formula aggregating the CLI packages',
  'pycamilladsp' => 'Python client library for the websocket API',
  'pycamilladsp-plot' => 'Config validator and plotting tools',
  'camillagui' => 'CamillaGUI backend/frontend bundle'
}.freeze

RE_VERSION = /^\s*version\s+["']([^"']+)["']/m
RE_HOMEPAGE = /^\s*homepage\s+["']([^"']+)["']/m
RE_URL = /^\s*url\s+["']([^"']+)["']/m
RE_LICENSE_ANY_OF = /license\s+any_of:\s*\[([^\]]+)\]/
RE_LICENSE_ALL_OF = /license\s+all_of:\s*\[([^\]]+)\]/
RE_LICENSE_SIMPLE = /^\s*license\s+["']([^"']+)["']/m
RE_SHA256_SIMPLE = /sha256\s+["']([0-9a-f]{64})["']/
RE_SHA256_ARCH = /sha256\s+arm:\s*["']([0-9a-f]{64})["'],\s*\n?\s*intel:\s*["']([0-9a-f]{64})["']/
RE_DEPENDS = /^\s*depends_on\s+(?:["']([^"']+)["']|(:\w+))/m
RE_RESOURCE = /^\s*resource\s+["']([^"']+)["']\s+do/m
RE_BIN_INSTALL = /bin\.install\s+["']([^"']+)["']/
RE_BIN_WRITE = %r{\(bin\s*/\s*["']([^"']+)["']\)\.write}
RE_BIN_SYMLINK = /bin\.install_symlink\s+.*?["']([^"']+)["']/
RE_CASK_BINARY = /binary\s+["']([^"']+)["'](?:\s*,\s*target:\s*["']([^"']+)["'])?/
RE_CASK_ARCH = /arch\s+arm:\s*["']([^"']+)["']\s*,\s*intel:\s*["']([^"']+)["']/
RE_TEST_DO = /test do\s*(.*?)\n  end\b/m
RE_SHELL_OUTPUT = /shell_output\(/
RE_VENV_LAUNCHER = %r{\(bin\s*/\s*["']([^"']+)["']\)\.write}m

def github_repo(homepage)
  return nil if homepage.nil? || homepage.empty?

  match = homepage.match(%r{github\.com/([^/]+/[^/]+)})
  match && match[1]
end

def extract_license(text)
  [RE_LICENSE_ANY_OF, RE_LICENSE_ALL_OF].each do |pattern|
    next unless (m = text.match(pattern))

    joiner = pattern == RE_LICENSE_ANY_OF ? ' OR ' : ' AND '
    entries = m[1].scan(/["']([^"']+)["']/).flatten(1)
    next if entries.empty?

    return entries.length > 1 ? [entries.join(joiner)] : entries
  end
  if (m = text.match(RE_LICENSE_SIMPLE))
    return [m[1]]
  end

  []
end

def extract_executables(text, is_cask)
  executables = []
  if is_cask
    text.scan(RE_CASK_BINARY) do |source, target|
      executables << (target && !target.empty? ? target : File.basename(source))
    end
    return executables
  end
  text.scan(RE_BIN_INSTALL) { executables << File.basename(Regexp.last_match(1)) }
  text.scan(RE_BIN_WRITE) { executables << Regexp.last_match(1) }
  text.scan(RE_BIN_SYMLINK) { executables << File.basename(Regexp.last_match(1)) }
  executables
end

def classify_install_mode(text, is_cask)
  return 'cask: upstream binary bundle (tar.gz), binary linked into prefix/bin' if is_cask
  return 'formula: python virtualenv in libexec with launcher wrapper(s) in bin' if text.include?('virtualenv_create')
  if text.include?('depends_on') && !text.include?('pkgshare') && !text.include?('bin.install')
    return 'formula: meta-package (dependencies only, marker file in share)'
  end
  return 'formula: git checkout installed as shared data under pkgshare' if text.include?('pkgshare.install')
  if text.include?('.tar.gz') && text.include?('bin.install')
    return 'formula: upstream prebuilt binary tarball per macOS architecture'
  end

  'formula: git checkout'
end

def extract_package(path, is_cask)
  text = File.read(path.to_s, encoding: 'utf-8')
  name = path.basename('.rb').to_s
  homepage = (m = text.match(RE_HOMEPAGE)) ? m[1] : nil
  url = (m = text.match(RE_URL)) ? m[1] : nil
  version = (m = text.match(RE_VERSION)) ? m[1] : nil
  arch_match = text.match(RE_CASK_ARCH)

  architectures = arch_match || text.include?('Hardware::CPU.arm?') ? %w[arm64 x86_64] : ['universal']

  sha256_arch = text.match(RE_SHA256_ARCH)
  sha256 = if sha256_arch
             { 'arm' => sha256_arch[1], 'intel' => sha256_arch[2] }
           else
             text.scan(RE_SHA256_SIMPLE).map(&:first)
           end

  dependencies = []
  text.scan(RE_DEPENDS) do |dep, sym|
    dependencies << (dep.nil? || dep.empty? ? sym : dep)
  end
  dependencies = dependencies.uniq.sort

  python_resources = text.scan(RE_RESOURCE).map(&:first)

  license = is_cask ? ['not-declared (cask DSL has no license stanza)'] : extract_license(text)

  {
    'type' => is_cask ? 'cask' : 'formula',
    'upstream' => {
      'repository' => github_repo(homepage),
      'component' => UPSTREAM_COMPONENTS.fetch(name, 'unknown'),
      'homepage' => homepage
    },
    'url' => url,
    'version' => version,
    'sha256' => sha256,
    'executables' => extract_executables(text, is_cask),
    'dependencies' => dependencies,
    'python_resources' => python_resources,
    'license' => license,
    'architectures' => architectures,
    'install_mode' => classify_install_mode(text, is_cask)
  }
end

def build_inventory(repo_root)
  errors = []
  formula_dir = repo_root / 'Formula'
  cask_dir = repo_root / 'Casks'

  formulae = formula_dir.directory? ? formula_dir.glob('*.rb').map { |p| p.basename('.rb').to_s }.sort : []
  casks = cask_dir.directory? ? cask_dir.glob('*.rb').map { |p| p.basename('.rb').to_s }.sort : []

  (EXPECTED_FORMULAE - formulae).each do |name|
    errors << "missing package: formula #{name} (expected Formula/#{name}.rb)"
  end
  (formulae - EXPECTED_FORMULAE).each do |name|
    errors << "unexpected package: formula #{name}"
  end
  (EXPECTED_CASKS - casks).each do |name|
    errors << "missing package: cask #{name} (expected Casks/#{name}.rb)"
  end
  (casks - EXPECTED_CASKS).each do |name|
    errors << "unexpected package: cask #{name}"
  end

  packages = {}
  if formula_dir.directory?
    formula_dir.glob('*.rb').sort.each do |path|
      packages[path.basename('.rb').to_s] = extract_package(path, false)
    end
  end
  if cask_dir.directory?
    cask_dir.glob('*.rb').sort.each do |path|
      packages[path.basename('.rb').to_s] = extract_package(path, true)
    end
  end

  matrix = {
    'schema_version' => SCHEMA_VERSION,
    'mode' => 'inventory-only',
    'expected' => { 'formulae' => EXPECTED_FORMULAE, 'casks' => EXPECTED_CASKS },
    'formulae_count' => formulae.length,
    'casks_count' => casks.length,
    'packages' => packages
  }
  [matrix, errors]
end

# ---------------------------------------------------------------------------
# Todo 5 contract checks. Each function returns [passed, failed] arrays of
# strings so the caller can merge the results into the JSON report. The
# checks are intentionally split so a future contributor can add a new check
# by adding one function and listing it in `CONTRACT_CHECKS` below.
# ---------------------------------------------------------------------------

def check_python_system_site_packages(repo_root)
  passed = []
  failed = []
  formula_dir = repo_root / 'Formula'
  return [passed, failed] unless formula_dir.directory?

  formula_dir.glob('*.rb').sort.each do |path|
    text = File.read(path.to_s, encoding: 'utf-8')
    next unless text.include?('Language::Python::Virtualenv')

    if text.include?('system_site_packages: true')
      failed << "#{path.basename('.rb')}: uses `system_site_packages: true` (must be false)"
    elsif text.include?('system_site_packages: false')
      passed << "#{path.basename('.rb')}: system_site_packages: false"
    else
      failed << "#{path.basename('.rb')}: uses Language::Python::Virtualenv but does NOT " \
                'explicitly set `system_site_packages: false`'
    end
  end
  [passed, failed]
end

def check_launchers_use_venv_python(repo_root)
  passed = []
  failed = []
  formula_dir = repo_root / 'Formula'
  return [passed, failed] unless formula_dir.directory?

  formula_dir.glob('*.rb').sort.each do |path|
    text = File.read(path.to_s, encoding: 'utf-8')
    next unless text.include?('Language::Python::Virtualenv')

    text.to_enum(:scan, RE_VENV_LAUNCHER).each do
      m = Regexp.last_match
      line_number = text[0...m.begin(0)].count("\n") + 1
      launcher_name = m[1]
      window = text[m.end(0)..(m.end(0) + 800)]
      exec_match = window.match(/exec\s+["']([^"']+)["']/)
      if exec_match.nil?
        failed << "#{path.basename('.rb')}:#{line_number}: launcher #{launcher_name.inspect} has no `exec` line"
        next
      end
      exec_line = exec_match[1]
      ok = true
      if exec_line.include?('/usr/bin/python')
        failed << "#{path.basename('.rb')}:#{line_number}: launcher #{launcher_name.inspect} uses global Python"
        ok = false
      end
      if exec_line.include?('formula_opt_bin')
        failed << "#{path.basename('.rb')}:#{line_number}: launcher #{launcher_name.inspect} uses formula_opt_bin"
        ok = false
      end
      if exec_line.include?('python@3.14')
        failed << "#{path.basename('.rb')}:#{line_number}: launcher #{launcher_name.inspect} uses Homebrew python@3.14"
        ok = false
      end
      unless exec_line.include?('#{libexec}/bin/python')
        failed << "#{path.basename('.rb')}:#{line_number}: launcher #{launcher_name.inspect} does not exec the venv python"
        ok = false
      end
      passed << "#{path.basename('.rb')}: launcher #{launcher_name.inspect} exec the venv python" if ok
    end
  end
  [passed, failed]
end

def check_test_do_has_assertion(repo_root)
  passed = []
  failed = []
  formula_dir = repo_root / 'Formula'
  return [passed, failed] unless formula_dir.directory?

  formula_dir.glob('*.rb').sort.each do |path|
    text = File.read(path.to_s, encoding: 'utf-8')
    m = text.match(RE_TEST_DO)
    if m.nil?
      failed << "#{path.basename('.rb')}: no test do block"
      next
    end
    block = m[1]
    if block.match?(RE_SHELL_OUTPUT) || block.include?('assert')
      passed << "#{path.basename('.rb')}: test do has assertion or shell_output failure"
    else
      failed << "#{path.basename('.rb')}: test do has no `shell_output(...)` and no " \
                '`assert_*` call (contract requires a real assertion)'
    end
  end
  [passed, failed]
end

def check_brewfile_canonical(repo_root)
  passed = []
  failed = []
  brewfile = repo_root / 'Brewfile'
  unless brewfile.exist?
    failed << 'Brewfile missing'
    return [passed, failed]
  end
  text = File.read(brewfile.to_s, encoding: 'utf-8')
  lines = text.split("\n").map(&:strip).reject { |l| l.empty? || l.start_with?('#') }
  if lines == EXPECTED_BREWFILE
    passed << 'Brewfile: canonical (tap, brew suite, cask)'
  else
    failed << "Brewfile drifted from canonical order.\n  " \
              "expected: #{EXPECTED_BREWFILE}\n  actual:   #{lines}"
  end
  failed << "Brewfile contains duplicates: #{lines}" if lines.length != lines.uniq.length
  [passed, failed]
end

CONTRACT_CHECKS = [
  ['python_system_site_packages', method(:check_python_system_site_packages)],
  ['launchers_use_venv_python', method(:check_launchers_use_venv_python)],
  ['test_do_has_assertion', method(:check_test_do_has_assertion)],
  ['brewfile_canonical', method(:check_brewfile_canonical)]
].freeze

def run_contract_checks(repo_root)
  summary = {
    'schema_version' => SCHEMA_VERSION,
    'mode' => 'contract-checks',
    'checks' => {}
  }
  total_passed = 0
  total_failed = 0
  failures = []
  checks_dict = {}
  CONTRACT_CHECKS.each do |name, fn|
    passed, failed = fn.call(repo_root)
    total_passed += passed.length
    total_failed += failed.length
    checks_dict[name] = { 'passed' => passed, 'failed' => failed }
    failures.concat(failed)
  end
  summary['checks'] = checks_dict
  summary['total_passed'] = total_passed
  summary['total_failed'] = total_failed
  summary['all_passed'] = total_failed.zero?
  summary['failures'] = failures
  summary
end

# Minitest-based assertion layer. Each contract check has a test method
# that runs the matching function and asserts the result is empty on the
# `failed` side. The test class also exposes a `contract_summary` accessor
# so the JSON emit step can read the live result without re-running.
class PlanContractTest < Minitest::Test
  class << self
    attr_accessor :repo_root, :cli_errors, :contract_summary, :inventory_matrix
  end

  def setup
    self.class.repo_root ||= Pathname(__FILE__).realpath.parent.parent
    self.class.cli_errors ||= []
    self.class.contract_summary ||= {}
  end

  def test_inventory_inventory_only_mode
    matrix, errors = build_inventory(self.class.repo_root)
    self.class.inventory_matrix = matrix
    assert(errors.empty?, "inventory errors: #{errors.inspect}")
  end

  def test_python_system_site_packages
    passed, failed = check_python_system_site_packages(self.class.repo_root)
    assert(failed.empty?, "system_site_packages failures: #{failed.inspect}")
    refute_empty(passed, 'expected at least one formula using system_site_packages: false')
  end

  def test_launchers_use_venv_python
    passed, failed = check_launchers_use_venv_python(self.class.repo_root)
    assert(failed.empty?, "launcher venv python failures: #{failed.inspect}")
    refute_empty(passed, 'expected at least one launcher to use the venv python')
  end

  def test_test_do_has_assertion
    _, failed = check_test_do_has_assertion(self.class.repo_root)
    assert(failed.empty?, "test do assertion failures: #{failed.inspect}")
  end

  def test_brewfile_canonical
    _, failed = check_brewfile_canonical(self.class.repo_root)
    assert(failed.empty?, "Brewfile canonical failures: #{failed.inspect}")
  end
end

def parse_options(argv)
  options = {
    inventory_only: false,
    checks_only: false,
    json_out: nil,
    repo_root: Pathname(__FILE__).realpath.parent.parent
  }
  parser = OptionParser.new do |opts|
    opts.banner = 'Usage: plan_contract_checks.rb [options]'
    opts.on('--inventory-only', 'run the offline inventory check (Todo 1 default)') { options[:inventory_only] = true }
    opts.on('--checks-only', 'run only the Todo 5 contract checks (no inventory emit)') { options[:checks_only] = true }
    opts.on('--json-out PATH', 'write the inventory matrix JSON to this path') { |p| options[:json_out] = Pathname(p) }
    opts.on('--repo-root PATH', 'tap repository root') { |p| options[:repo_root] = Pathname(p) }
    opts.on('-h', '--help', 'show this help') do
      puts opts
      exit 0
    end
  end
  parser.parse!(argv)
  options
end

def main(argv)
  options = parse_options(argv)

  # When no mode flag is provided, default to --checks-only so the
  # standalone invocation `ruby -Ilib -Itest test/plan_contract_checks.rb`
  # works as a contract-check pass (the Todo 1 default --inventory-only
  # requires an explicit flag and writes JSON).
  options[:checks_only] = true if !options[:inventory_only] && !options[:checks_only] && argv.empty?

  unless options[:inventory_only] || options[:checks_only]
    warn 'error: either --inventory-only or --checks-only is required (the Todo 1 default is --inventory-only)'
    return 1
  end

  repo_root = options[:repo_root].realpath
  PlanContractTest.repo_root = repo_root

  # Rebuild the structured report after the test run so JSON emit matches
  # what the contract layer would have produced.
  matrix, inventory_errors = build_inventory(repo_root) if options[:inventory_only]
  contract_summary = run_contract_checks(repo_root)
  errors = []
  errors.concat(inventory_errors) if options[:inventory_only]
  errors.concat(contract_summary['failures'])

  if options[:json_out]
    payload = options[:inventory_only] ? matrix.dup : {}
    payload['contracts'] = contract_summary
    options[:json_out].parent.mkpath
    options[:json_out].write(JSON.pretty_generate(payload) + "\n")
  end

  unless errors.empty?
    errors.each { |error| warn "FAIL: #{error}" }
    return 1
  end

  if options[:checks_only]
    puts 'OK: contract checks pass ' \
         "(#{contract_summary['total_passed']} passed, " \
         "#{contract_summary['total_failed']} failed) in #{repo_root}"
  else
    puts "OK: #{matrix['formulae_count']} formulae + #{matrix['casks_count']} cask(s) " \
         "in #{repo_root} (#{contract_summary['total_passed']} contract checks pass)"
  end
  0
end

exit main(ARGV) if __FILE__ == $PROGRAM_NAME
