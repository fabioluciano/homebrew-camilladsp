#!/usr/bin/env ruby
# frozen_string_literal: true

# Cross-validates the user-facing documentation against the actual tap
# surface for Todo 9 ("Alinhar documentação e executar verificação
# cruzada final"). The test reads `README.md`, `CONTRIBUTING.md`, and
# `Brewfile` as plain text and asserts:
#
#   1. README's package table lists exactly the 8 tap packages, in the
#      canonical order (engine, cask, two Python libs, controller,
#      config, setup scripts, suite).
#   2. README's CLI rows map 1:1 onto the `camilladsp-suite`
#      `depends_on` list (no extra CLI rows; no missing CLI rows).
#   3. README's version column matches the version (or tag) extracted
#      from each `Formula/*.rb`.
#   4. README's GUI SHA-256 sums match the pinned sums in the formula.
#   5. No token-like example (GitHub PAT, AWS key, password=, token=,
#      Bearer, PEM header) survives in any of the user-facing docs.
#   6. The GUI formula does not use `sha256 :no_check`.
#   7. Controller docs claim `-d` is OPTIONAL and at-least-one of
#      `-s` or `-a` is required.
#   8. README mentions `tccutil reset Microphone` (canonical remedy).
#
# Stdlib only: minitest, json, optparse, fileutils, digest, pathname.
# No Gemfile, no external gems.

require 'minitest/autorun'
require 'digest'
require 'fileutils'
require 'json'
require 'optparse'
require 'pathname'

DEFAULT_REPO_ROOT = Pathname(__FILE__).realpath.parent.parent.freeze
EXPECTED_PACKAGE_ORDER = %w[
  camilladsp
  camillagui
  pycamilladsp
  pycamilladsp-plot
  camilladsp-controller
  camilladsp-config
  camilladsp-setupscripts
  camilladsp-suite
].freeze

EXPECTED_CASK_SHAS = {
  'arm' => '09da0b654aefaa1c983f0208524d9abf768e8a13ae4670d69bc65c17fd4b4f63',
  'intel' => '4540c78bc05b86977276bea5188f9308d4ccaad954ca8260b47d2b1b6c74d641'
}.freeze

EXPECTED_GUI_SHAS = {
  'arm' => '09da0b654aefaa1c983f0208524d9abf768e8a13ae4670d69bc65c17fd4b4f63',
  'intel' => '4540c78bc05b86977276bea5188f9308d4ccaad954ca8260b47d2b1b6c74d641'
}.freeze

# Suite's CLI dependents — what the Brewfile ultimately installs. The
# suite aggregates exactly these six; the cask is installed separately.
EXPECTED_SUITE_CLI = %w[
  camilladsp
  camilladsp-config
  camilladsp-controller
  camilladsp-setupscripts
  pycamilladsp
  pycamilladsp-plot
].freeze

# Allowlist of "false positive" lines that may mention a credential
# pattern. Today: only the docs that explicitly warn AGAINST using
# `sha256 :no_check`, and the cask stanza that documents why the tap
# no longer does so. The scanner is intentionally strict so any new
# literal that LOOKS like a secret fails the build.
CREDENTIAL_ALLOWLIST_PATTERNS = [
  /no `?`?sha256 :no_check`?`?/i,
  /NOT use `?`?sha256 :no_check`?`?/i,
  /does not use `?`?sha256 :no_check`?`?/i,
  /cask does not use `?`?sha256 :no_check`?`?/i,
  /\bno_check\b.*\b(removed|replaced|forbidden|prohibited)\b/i
].freeze

CREDENTIAL_REGEXES = {
  github_pat: /gh[ps]_[A-Za-z0-9]{36}/,
  aws_access_key: /AKIA[0-9A-Z]{16}/,
  password_literal: /(?<![A-Za-z0-9_])password\s*[:=]\s*['"]([^'"\\\n]{4,})['"]/i,
  token_literal: %r{(?<![A-Za-z0-9_])token\s*[:=]\s*['"]([A-Za-z0-9._/+=-]{20,})['"]}i,
  bearer_header: /Bearer\s+[A-Za-z0-9._-]{20,}/,
  pem_private_key: /-----BEGIN [A-Z ]+PRIVATE KEY-----/
}.freeze

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
].to_set.freeze

def placeholder?(text)
  stripped = text.to_s.strip.strip(%q("'))
  return true if PLACEHOLDER_LITERALS.include?(stripped)
  return true if stripped.chars.all? { |ch| 'x*X.-_<>'.include?(ch) }

  false
end

def line_is_allowlisted?(line)
  CREDENTIAL_ALLOWLIST_PATTERNS.any? { |pattern| line =~ pattern }
end

class TestDocsInventory < Minitest::Test
  class << self
    attr_accessor :readme_path, :brewfile_path, :suite_path
  end

  def setup
    repo_root = Pathname(__FILE__).realpath.parent.parent
    @readme_path = (self.class.readme_path || (repo_root / 'README.md')).to_s
    @brewfile_path = (self.class.brewfile_path || (repo_root / 'Brewfile')).to_s
    @suite_path = (self.class.suite_path || (repo_root / 'Formula' / 'camilladsp-suite.rb')).to_s
    @formula_dir = (Pathname(@readme_path).realpath.parent / 'Formula').to_s
    @readme = File.read(@readme_path, encoding: 'utf-8')
    @brewfile = File.read(@brewfile_path, encoding: 'utf-8')
    @suite_text = File.read(@suite_path, encoding: 'utf-8')
  end

  # --- 1. README's packages table is in canonical order -------------

  def extract_package_table_rows(readme)
    # A markdown table row looks like:
    #   | `camilladsp` | CamillaDSP engine 4.1.3 | Native binary ... |
    # We pick the FIRST contiguous run of pipe-prefixed lines that
    # contains every expected package name. That is the "Packages"
    # table by construction (other tables — Maintenance, Sources —
    # are downstream and use different column shapes).
    rows = []
    readme.each_line do |line|
      stripped = line.strip
      next unless stripped.start_with?('|')

      cells = stripped.split('|').map(&:strip)
      next if cells.length < 2
      # Skip separator lines (| --- | --- |)
      next if cells.all? { |c| c.match?(/\A:?-+:?\z/) }

      # Skip header rows that don't look like package rows.
      rows << cells
    end
    rows
  end

  def package_name_in_cell(cell)
    # The first column of a package row is `name` (backticked). Pull it out.
    m = cell.match(/`([^`]+)`/)
    m ? m[1] : nil
  end

  def test_readme_lists_eight_packages
    rows = extract_package_table_rows(@readme)
    package_rows = rows.select { |cells| EXPECTED_PACKAGE_ORDER.include?(package_name_in_cell(cells[1].to_s)) }
    actual = package_rows.map { |cells| package_name_in_cell(cells[1].to_s) }
    assert_equal EXPECTED_PACKAGE_ORDER, actual,
                 "README's package table must list exactly the 8 packages in canonical order.\n" \
                 "  expected: #{EXPECTED_PACKAGE_ORDER}\n  actual:   #{actual}"
  end

  # --- 2. README's CLI rows match the suite's depends_on ------------

  def readme_cli_packages
    rows = extract_package_table_rows(@readme)
    package_rows = rows.select { |cells| EXPECTED_PACKAGE_ORDER.include?(package_name_in_cell(cells[1].to_s)) }
    package_rows.map { |cells| package_name_in_cell(cells[1].to_s) } - %w[camillagui camilladsp-suite]
  end

  def test_readme_inventory_matches_brewfile_and_suite
    brewfile_lines = @brewfile.split("\n").map(&:strip)
                              .reject { |l| l.empty? || l.start_with?('#') }
    assert_equal(
      ['tap "fabioluciano/camilladsp"',
       'brew "fabioluciano/camilladsp/camilladsp-suite"',
       'brew "fabioluciano/camilladsp/camillagui"'],
      brewfile_lines,
      "Brewfile must be canonical: tap + brew suite + brew gui, no duplicates.\n" \
      "  actual: #{brewfile_lines.inspect}"
    )

    suite_depends_on = @suite_text.scan(/^\s*depends_on\s+["']([^"']+)["']/m).flatten.sort
    assert_equal EXPECTED_SUITE_CLI.sort, suite_depends_on,
                 "camilladsp-suite must depends_on exactly the 6 CLI formulae.\n" \
                 "  expected: #{EXPECTED_SUITE_CLI.sort}\n  actual:   #{suite_depends_on}"

    readme_cli = readme_cli_packages.sort
    assert_equal EXPECTED_SUITE_CLI.sort, readme_cli,
                 "README's CLI rows (engine + 5 non-suite CLI packages) must match the suite's depends_on.\n" \
                 "  expected: #{EXPECTED_SUITE_CLI.sort}\n  actual:   #{readme_cli}"
  end

  # --- 3. README's version column matches the formula/cask ----------

  def extract_formula_version(path)
    text = File.read(path, encoding: 'utf-8')
    # Top-level `version "X.Y.Z"` is the canonical pin for asset-based
    # formulae (camilladsp). For git-tag-based formulae the pin is the
    # `tag:` argument on the `url` line. For formulae without a top-level
    # version (inferred from URL), extract from the first download URL.
    if (m = text.match(/^\s*version\s+["']([^"']+)["']/m))
      return m[1]
    end
    if (m = text.match(/url\s+["'][^"']+["'],\s*tag:\s*["']([^"']+)["']/m))
      return m[1]
    end
    if (m = text.match(%r{/releases/download/v([^/]+)/}m))
      return m[1]
    end

    nil
  end

  def extract_cask_version(path)
    text = File.read(path, encoding: 'utf-8')
    if (m = text.match(/^\s*version\s+["']([^"']+)["']/m))
      return m[1]
    end

    nil
  end

  def normalize_version(version)
    return nil if version.nil?

    version.to_s.sub(/\Av/i, '').sub(/[.,;:]$/, '')
  end

  def readme_version_for(package_name)
    rows = extract_package_table_rows(@readme)
    row = rows.find { |cells| package_name_in_cell(cells[1].to_s) == package_name }
    return nil if row.nil?

    # Version is in the SECOND cell (description column), as a bare
    # token. Look for the first token that looks like a version
    # (X.Y.Z or YYYY.MM.DD or vX.Y.Z). Tolerant on both styles.
    cell = row[2].to_s
    if (m = cell.match(/\b(v?\d{4}\.\d{1,2}\.\d{1,2})\b/))
      return m[1]
    end
    if (m = cell.match(/\b(v?\d+\.\d+\.\d+)\b/))
      return m[1]
    end

    nil
  end

  def test_no_uncommitted_or_drifted_versions
    formula_to_path = {
      'camilladsp' => "#{@formula_dir}/camilladsp.rb",
      'camilladsp-config' => "#{@formula_dir}/camilladsp-config.rb",
      'camilladsp-controller' => "#{@formula_dir}/camilladsp-controller.rb",
      'camilladsp-setupscripts' => "#{@formula_dir}/camilladsp-setupscripts.rb",
      'camilladsp-suite' => "#{@formula_dir}/camilladsp-suite.rb",
      'camillagui' => "#{@formula_dir}/camillagui.rb",
      'pycamilladsp' => "#{@formula_dir}/pycamilladsp.rb",
      'pycamilladsp-plot' => "#{@formula_dir}/pycamilladsp-plot.rb"
    }
    formula_to_path.each do |package, path|
      formula_version = extract_formula_version(path)
      readme_version = readme_version_for(package)
      refute_nil formula_version, "#{path}: could not extract version"
      refute_nil readme_version,
                 "README's row for `#{package}` is missing a version (formula pin is #{formula_version})"
      assert_equal normalize_version(formula_version), normalize_version(readme_version),
                   "README version for `#{package}` drifted from formula pin.\n" \
                   "  formula: #{formula_version}\n  readme:  #{readme_version}"
    end
  end

  # --- 4. README's GUI SHAs match the formula ------------------------

  def test_gui_hashes_match_readme
    gui_text = File.read("#{@formula_dir}/camillagui.rb", encoding: 'utf-8')
    sha_matches = gui_text.scan(/sha256\s+["']([0-9a-f]{64})["']/).flatten
    assert sha_matches.length >= 2, 'camillagui formula must declare sha256 values for ARM and Intel'

    arm_actual = sha_matches[0]
    intel_actual = sha_matches[1]
    assert_equal EXPECTED_GUI_SHAS['arm'], arm_actual,
                 "camillagui ARM sha256 in formula drifted from the pinned release asset.\n" \
                 "  expected: #{EXPECTED_GUI_SHAS['arm']}\n  actual:   #{arm_actual}"
    assert_equal EXPECTED_GUI_SHAS['intel'], intel_actual,
                 "camillagui Intel sha256 in formula drifted from the pinned release asset.\n" \
                 "  expected: #{EXPECTED_GUI_SHAS['intel']}\n  actual:   #{intel_actual}"

    assert_includes @readme, EXPECTED_GUI_SHAS['arm'],
                    "README must mention the pinned ARM sha256 (#{EXPECTED_GUI_SHAS['arm']})"
    assert_includes @readme, EXPECTED_GUI_SHAS['intel'],
                    "README must mention the pinned Intel sha256 (#{EXPECTED_GUI_SHAS['intel']})"
  end

  # --- 5. No secret-like examples in any user-facing doc ------------

  def scan_for_credentials(text, source_label)
    hits = []
    text.each_line.with_index(1) do |line, idx|
      next if line_is_allowlisted?(line)

      CREDENTIAL_REGEXES.each do |name, regex|
        line.scan(regex) do |match|
          matched = match[0].is_a?(String) ? match[0] : match
          next if placeholder?(matched)

          hits << { source: source_label, line: idx, pattern: name, match: matched.to_s }
        end
      end
    end
    hits
  end

  def test_no_secret_examples_in_docs
    files = [
      [@readme_path, 'README.md'],
      [Pathname(@readme_path).realpath.parent / 'CONTRIBUTING.md', 'CONTRIBUTING.md'],
      [@brewfile_path, 'Brewfile']
    ]
    hits = []
    files.each do |path, label|
      next unless File.exist?(path)

      text = File.read(path, encoding: 'utf-8')
      hits.concat(scan_for_credentials(text, label))
    end
    assert_empty hits,
                 "user-facing docs must not contain credential-shaped examples.\n" \
                 "  hits: #{hits.map do |h|
                   "#{h[:source]}:#{h[:line]} [#{h[:pattern]}] #{h[:match].inspect}"
                 end.join("\n  ")}"
  end

  # --- 6. GUI formula does NOT use :no_check ------------------------

  def test_no_check_assertion_correct
    gui_text = File.read("#{@formula_dir}/camillagui.rb", encoding: 'utf-8')
    refute_includes gui_text, 'sha256 :no_check',
                    'camillagui formula must NOT use `sha256 :no_check`; the upstream assets have ' \
                    'real arch-specific SHA-256 values that must be pinned'
  end

  # --- 7. Controller docs are consistent with the contract --------

  def controller_section(text)
    # Naive section extractor: take everything from the first
    # "## Controller" or "## Controller\n" header to the next "## "
    # header. Good enough for a single-page README + CONTRIBUTING.
    lines = text.split("\n")
    start_idx = lines.index { |l| l.start_with?('## Controller') }
    return '' if start_idx.nil?

    end_idx = lines[(start_idx + 1)..].index { |l| l.start_with?('## ') }
    end_idx = lines.length if end_idx.nil?
    lines[start_idx...start_idx + end_idx + 1].join("\n")
  end

  def test_controller_docs_match_contract
    contributing_path = Pathname(@readme_path).realpath.parent / 'CONTRIBUTING.md'
    contributing = File.exist?(contributing_path.to_s) ? File.read(contributing_path.to_s, encoding: 'utf-8') : ''
    combined = controller_section(@readme) + "\n" + controller_section(contributing)
    refute_empty combined,
                 'no `## Controller` section found in README.md or CONTRIBUTING.md'

    # `-p` is documented as required. We slice the controller section
    # into a "Required" sub-section (everything between the first
    # "Required arguments" or "Required" heading and the next heading
    # or the "Optional" heading) and require `-p` to appear there.
    required_section = required_controller_section(combined)
    refute_empty required_section,
                 'controller docs must have a `Required arguments` sub-section'
    assert_match(/-p\b/, required_section,
                 'controller `Required arguments` must list `-p`')

    # At least one of `-s` or `-a` is documented as required.
    assert_match(/-s\b/, required_section,
                 'controller `Required arguments` must list `-s`')
    assert_match(/-a\b/, required_section,
                 'controller `Required arguments` must list `-a`')
    assert_match(/at least one of\s+`?-s`?\s+or\s+`?-a`?/i, combined,
                 'controller docs must state that at least one of -s or -a is required')

    # `-d` is documented as OPTIONAL. It must NOT appear in the
    # "Required" sub-section; it should be in the "Optional" sub-section
    # (or at least, the line that mentions `-d` must not be marked
    # required).
    optional_section = optional_controller_section(combined)
    refute_empty optional_section,
                 'controller docs must have an `Optional arguments` sub-section'
    assert_match(/-d\b/, optional_section,
                 'controller `Optional arguments` must mention `-d`')
    refute_match(/-p\b/, optional_section,
                 'controller `Optional arguments` must NOT list `-p` (it is required)')

    # `-d` is not marked as required anywhere (the test catches the
    # edge case of a docs update that re-promotes `-d` to required).
    refute_match(/^-d\b[^\n]*\b(required|mandatory)\b/m, combined,
                 'controller docs must NOT mark `-d` as required; it is the optional macOS CoreAudio listener')

    # `-d` IS mentioned (the contract is 'optional but supported on macOS').
    assert_match(/-d\b/, combined, 'controller docs must mention `-d` even if optional')
  end

  def required_controller_section(combined)
    slice_sub_section(combined, /\brequired\s+(arguments|flags)\b/i)
  end

  def optional_controller_section(combined)
    slice_sub_section(combined, /\boptional\s+(arguments|flags)\b/i)
  end

  def slice_sub_section(combined, header_regex)
    lines = combined.split("\n")
    start_idx = lines.index { |l| l =~ header_regex }
    return '' if start_idx.nil?

    # Walk forward until the next "## " header or a sibling "Required"/"Optional"
    # header, whichever comes first.
    end_idx = lines.length
    lines[(start_idx + 1)..].each_with_index do |l, i|
      stripped = l.strip
      next if stripped.empty?

      if stripped.start_with?('##')
        end_idx = start_idx + 1 + i
        break
      end
      if stripped =~ /\A(required|optional)\s+(arguments|flags)\b/i
        end_idx = start_idx + 1 + i
        break
      end
    end
    lines[start_idx...end_idx].join("\n")
  end

  # --- 8. Microphone remedy is documented in the README -----------

  def test_microphone_remedy_documented
    assert_match(/tccutil reset Microphone/, @readme,
                 'README must document `tccutil reset Microphone` as the canonical macOS microphone-permission remedy')
  end
end

require 'set'

def parse_options(argv)
  options = {
    readme: nil,
    brewfile: nil,
    suite: nil
  }
  OptionParser.new do |opts|
    opts.banner = 'Usage: test_docs_inventory.rb [options]'
    opts.on('--readme PATH', 'path to README.md (default: repo root)') { |p| options[:readme] = p }
    opts.on('--brewfile PATH', 'path to Brewfile (default: repo root)') { |p| options[:brewfile] = p }
    opts.on('--suite PATH', 'path to camilladsp-suite formula (default: Formula/)') { |p| options[:suite] = p }
    opts.on('-h', '--help', 'show this help') do
      puts opts
      exit 0
    end
  end.parse!(argv)
  options
end

def main(argv)
  options = parse_options(argv)
  TestDocsInventory.readme_path = options[:readme] if options[:readme]
  TestDocsInventory.brewfile_path = options[:brewfile] if options[:brewfile]
  TestDocsInventory.suite_path = options[:suite] if options[:suite]
  0
end

exit main(ARGV) if __FILE__ == $PROGRAM_NAME
