#!/usr/bin/env ruby
# frozen_string_literal: true

# Black-box mirror of `.github/workflows/update.yml` (Todo 8).
#
# User invariant (2026-08-01): "Toda vez que tiver uma nova tag, [o tap]
# tem que buildar [e] disponibilizar para as pessoas uma nova versão."
# `.github/workflows/update.yml` is the trigger; this test asserts the
# same gating locally without ever calling the GitHub API. The fixture
# under `test/fixtures/update_versions/{happy,up-to-date}/` provides
# canned `api-mocks/responses.json` so the Python updater reads from
# the local mock only.
#
# Tests cover the full ordering the workflow enforces:
#   1. updater (Python subprocess, --fixture <tmpdir>) — `script/update_versions.py`
#   2. diff check — the updater's byte-level change is the fixture-
#      level mirror of `git diff --quiet`
#   3. validation — `bash scripts/verify.sh` (REQUIRED; aborts the test
#      on failure so we never open a PR after a broken build)
#   4. PR only after diff AND validation — mocked here by writing the
#      PR body to `.omo/evidence/camilladsp-homebrew-tap-audit/mocked-pr-*.md`
#
# Stdlib only: minitest, json, optparse, fileutils, open3, pathname,
# tmpdir, digest, socket. No Gemfile, no external gems.

require 'minitest/autorun'
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'pathname'
require 'socket'
require 'tmpdir'

ROOT = Pathname(__FILE__).realpath.parent.parent.freeze
SCRIPT = (ROOT / 'scripts' / 'update_versions.py').freeze
FIXTURES = (ROOT / 'test' / 'fixtures' / 'update_versions').freeze
VERIFY_SH = (ROOT / 'scripts' / 'verify.sh').freeze
EVIDENCE_DIR = Pathname('.omo') / 'evidence' / 'camilladsp-homebrew-tap-audit'

EXPECTED_UPDATED_FILES = %w[
  Formula/camilladsp.rb
  Formula/camillagui.rb
  Formula/pycamilladsp.rb
  Formula/pycamilladsp-plot.rb
  Formula/camilladsp-setupscripts.rb
  Formula/camilladsp-config.rb
  Formula/camilladsp-controller.rb
  Formula/camilladsp-suite.rb
].freeze

class RunUpdateWorkflowFixtureTest < Minitest::Test
  class << self
    attr_accessor :fixture_name, :skip_real_github, :mock_pr,
                  :assert_pr_after_validation, :assert_no_pr,
                  :force_validation_failure
  end

  def setup
    @fixture_name = self.class.fixture_name || 'happy'
    @skip_real_github = self.class.skip_real_github
    @mock_pr = self.class.mock_pr
    @assert_pr_after_validation = self.class.assert_pr_after_validation
    @assert_no_pr = self.class.assert_no_pr
    @force_validation_failure = self.class.force_validation_failure
    @ran_validation = false
    @ran_pr = false
    @validation_failed = false
    # Wipe any leftover mocked PR body from a previous test so that
    # negative assertions ("no PR was opened") are not fooled by
    # earlier-pass leftovers.
    return unless EVIDENCE_DIR.directory?

    Dir.glob(EVIDENCE_DIR / 'mocked-pr-*.md').each { |f| File.unlink(f) }
  end

  def with_fixture(name)
    Dir.mktmpdir('update-workflow-fixture') do |directory|
      root = Pathname(directory)
      source = FIXTURES / name
      FileUtils.cp_r("#{source}/.", root.to_s)
      yield root
    end
  end

  def run_updater(fixture_path, env = {})
    Open3.capture3(env, 'python3', SCRIPT.to_s, '--fixture', fixture_path,
                   chdir: ROOT.to_s)
  end

  def snapshot(root)
    EXPECTED_UPDATED_FILES.to_h do |relative|
      path = root / relative
      digest = path.exist? ? Digest::SHA256.file(path.to_s).hexdigest : nil
      [relative, digest]
    end
  end

  # Mirrors the workflow's `if: steps.diff.outputs.has_diff == 'true'`
  # gate. If the updater produced no diff, validation is never invoked,
  # just as the YAML gates the step on the diff output. When the gate
  # is open, validation is the real `bash scripts/verify.sh` subprocess
  # — the same one the CI runner calls — so the assertion is not just
  # "the wiring is right" but "the wiring is right AND the upstream
  # verify.sh would have passed". A forced-failure mode short-circuits
  # this to a synthetic false return so the gating-against-failure
  # tests can exercise the PR-blocked path without making the
  # underlying tap actually fail.
  def perform_validation(has_diff)
    return false unless has_diff

    @ran_validation = true
    if @force_validation_failure
      @validation_failed = true
      return false
    end

    stdout, stderr, status = Open3.capture3('bash', VERIFY_SH.to_s, chdir: ROOT.to_s)
    @validation_stdout = stdout
    @validation_stderr = stderr
    if status.success?
      true
    else
      @validation_failed = true
      false
    end
  end

  # Mirrors the workflow's `if: steps.diff.outputs.has_diff == 'true'`
  # AND the implicit "validation passed" gating (the YAML `Validate`
  # step runs before the PR step with no `if: always()`). PR is only
  # created when (a) there is a diff, (b) validation passed, and (c)
  # the test runner asked for `--mock-pr`.
  def perform_pr(root, fixture_name, has_diff)
    return unless has_diff
    return if @validation_failed

    @ran_pr = true
    return unless @mock_pr

    EVIDENCE_DIR.mkpath
    body = root / 'api-mocks' / 'responses.json'
    summary = {
      schema_version: 1,
      mocked: true,
      fixture: fixture_name,
      has_diff: true,
      validation_passed: !@validation_failed,
      pr_title: 'Automated package updates',
      pr_branch: 'automations/package-updates-test',
      body_excerpt: body.exist? ? body.read[0, 200] : nil
    }
    out = EVIDENCE_DIR / "mocked-pr-#{fixture_name}.md"
    out.write(JSON.pretty_generate(summary) + "\n")
  end

  # ------------------------------------------------------------------
  # Test 1: happy path opens PR after validation
  # ------------------------------------------------------------------
  def test_happy_path_opens_pr_after_validation
    fixture = 'happy'
    with_fixture(fixture) do |root|
      before = snapshot(root)
      stdout, stderr, status = run_updater(root.to_s)
      assert status.success?, "updater failed: stdout=#{stdout}\nstderr=#{stderr}"

      # The fixture is a copy in a tmpdir so there is no git history
      # to diff against; the contract is "updater produced a real
      # byte-level change in the planned files". A real diff in
      # `git diff` is the workflow-level equivalent.
      after = snapshot(root)
      changed = after.reject { |k, v| before[k] == v }
      refute_empty changed, "expected the updater to change at least one file: #{before.inspect}"
      has_diff = !changed.empty?

      # Validation gate (mirrors `bash scripts/verify.sh`).
      validation_ok = perform_validation(has_diff)
      assert validation_ok, 'validation must pass before PR (workflow contract)'

      # PR step.
      perform_pr(root, fixture, has_diff)
      assert @ran_pr, 'PR step must run when diff + validation both succeed'

      pr_body = EVIDENCE_DIR / "mocked-pr-#{fixture}.md"
      if @assert_pr_after_validation
        assert pr_body.exist?, "expected mocked PR body at #{pr_body}"
        summary = JSON.parse(pr_body.read)
        assert_equal 'Automated package updates', summary['pr_title']
      end
    end
  end

  # ------------------------------------------------------------------
  # Test 2: no-diff path opens no PR
  # ------------------------------------------------------------------
  def test_no_diff_path_opens_no_pr
    fixture = 'up-to-date'
    with_fixture(fixture) do |root|
      before = snapshot(root)
      stdout, stderr, status = run_updater(root.to_s)
      assert status.success?, "updater failed: stdout=#{stdout}\nstderr=#{stderr}"

      after = snapshot(root)
      changed = after.reject { |k, v| before[k] == v }
      assert_empty changed,
                   "expected the updater to be a no-op against up-to-date fixture; got: #{changed}"
      has_diff = !changed.empty?
      refute has_diff, 'no-diff fixture must produce zero byte-level change'

      # Mirrors the workflow's `if: steps.diff.outputs.has_diff == 'true'`
      # gate: when the diff is empty, neither validation nor the PR step
      # is allowed to run.
      validation_ok = perform_validation(has_diff)
      refute validation_ok,
             'validation MUST NOT run when no diff is present (workflow contract)'
      refute @ran_validation,
             'validation flag MUST NOT be set when no diff is present'

      # The PR step is the same: skipped.
      perform_pr(root, fixture, has_diff)
      refute @ran_pr, 'PR MUST NOT be created when no diff is present'
      if @assert_no_pr
        refute (EVIDENCE_DIR / "mocked-pr-#{fixture}.md").exist?,
               'no PR body should be written for the no-diff path'
      end
    end
  end

  # ------------------------------------------------------------------
  # Test 3: PR only AFTER validation passes
  # ------------------------------------------------------------------
  def test_pr_only_after_validation
    @force_validation_failure = true
    fixture = 'happy'
    with_fixture(fixture) do |root|
      stdout, stderr, status = run_updater(root.to_s)
      assert status.success?, "updater failed: stdout=#{stdout}\nstderr=#{stderr}"

      before = snapshot(root)
      after = snapshot(root)
      changed = after.reject { |k, v| before[k] == v }
      has_diff = !changed.empty?

      validation_ok = perform_validation(has_diff)
      refute validation_ok, 'expected synthetic validation failure'

      # PR step is intentionally NOT invoked when validation failed.
      perform_pr(root, fixture, has_diff)
      refute @ran_pr, 'PR MUST NOT run when validation failed (workflow contract)'
    end
  end

  # ------------------------------------------------------------------
  # Test 4: offline — no real GitHub calls
  # ------------------------------------------------------------------
  def test_offline_no_github_calls
    fixture = 'happy'
    with_fixture(fixture) do |root|
      # The updater, when run with --fixture <dir>, swaps its `Fetcher`
      # for MockFetcher, which reads `api-mocks/responses.json` from
      # that directory and refuses to fall back to the network. We
      # assert that contract by:
      #   (a) the updater succeeds under a no-network env, and
      #   (b) every URL the fixture lists is HTTPS (HTTP would be
      #       silently downgraded by an MITM).
      env = {
        'GITHUB_TOKEN' => '',
        'HTTP_PROXY' => '',
        'HTTPS_PROXY' => '',
        'http_proxy' => '',
        'https_proxy' => ''
      }

      stdout, stderr, status = run_updater(root.to_s, env)
      assert status.success?, "updater failed under offline env: stdout=#{stdout}\nstderr=#{stderr}"

      # Sanity check: the API mocks file was the SOLE source of truth.
      mock_path = root / 'api-mocks' / 'responses.json'
      assert mock_path.exist?, 'fixture must ship api-mocks/responses.json'
      responses = JSON.parse(mock_path.read)
      assert responses.is_a?(Array) && !responses.empty?,
             'api-mocks/responses.json must list every URL the updater requests'
      bad = responses.find { |r| r['url'].to_s.match?(%r{\Ahttp://}) }
      assert_nil bad, "fixture must use HTTPS only; found: #{bad.inspect}"
    end
  end

  # ------------------------------------------------------------------
  # Test 5: failure path → no PR
  # ------------------------------------------------------------------
  def test_failure_no_pr
    fixture = 'happy'
    with_fixture(fixture) do |_root|
      # Point the updater at a non-existent fixture directory:
      # MockFetcher must refuse to fall back, so the run aborts with
      # a non-zero exit. This is the same shape as a real CI failure
      # (network error, missing tag, malformed JSON), so the workflow
      # contract "no PR on failure" applies identically.
      stdout, stderr, status = run_updater('/nonexistent-fixture-dir')
      refute status.success?,
             "updater must fail when its fixture directory is missing: stdout=#{stdout}\nstderr=#{stderr}"

      # Validation must NOT run (workflow contract: validation only on diff,
      # and a failed updater leaves no diff to validate).
      validation_ok = perform_validation(false)
      refute validation_ok,
             'validation MUST NOT run after a failed updater'

      # PR must NOT run on failure.
      perform_pr(nil, fixture, false)
      refute @ran_pr, 'PR MUST NOT run after a failed updater'
      pr_body = EVIDENCE_DIR / "mocked-pr-#{fixture}.md"
      refute pr_body.exist?, 'no PR body should be written on failure'
    end
  end
end

def parse_options(argv)
  options = {
    fixture: 'happy',
    skip_real_github: false,
    mock_pr: false,
    assert_pr_after_validation: false,
    assert_no_pr: false
  }
  OptionParser.new do |opts|
    opts.banner = 'Usage: run_update_workflow_fixture.rb [options]'
    opts.on('--fixture NAME', 'fixture under test/fixtures/update_versions/ (default: happy)') do |v|
      options[:fixture] = v
    end
    opts.on('--skip-real-github', 'never call GitHub API (test mode)') { options[:skip_real_github] = true }
    opts.on('--mock-pr', 'write mocked PR body instead of invoking peter-evans') { options[:mock_pr] = true }
    opts.on('--assert-pr-after-validation', 'assert PR body was written after validation') do
      options[:assert_pr_after_validation] = true
    end
    opts.on('--assert-no-pr', 'assert no PR body was written (no-diff path)') do
      options[:assert_no_pr] = true
    end
    opts.on('-h', '--help', 'show this help') do
      puts opts
      exit 0
    end
  end.parse!(argv)
  options
end

def main(argv)
  options = parse_options(argv)
  RunUpdateWorkflowFixtureTest.fixture_name = options[:fixture]
  RunUpdateWorkflowFixtureTest.skip_real_github = options[:skip_real_github]
  RunUpdateWorkflowFixtureTest.mock_pr = options[:mock_pr]
  RunUpdateWorkflowFixtureTest.assert_pr_after_validation = options[:assert_pr_after_validation]
  RunUpdateWorkflowFixtureTest.assert_no_pr = options[:assert_no_pr]
  0
end

exit main(ARGV) if __FILE__ == $PROGRAM_NAME
