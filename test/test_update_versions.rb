#!/usr/bin/env ruby
# frozen_string_literal: true

# Todo 6 black-box coverage for the transactional updater.
#
# The user invariant ("every new tag must build and publish a new version") is
# enforced in CI by .github/workflows/update.yml (which runs this updater before
# opening its PR) and .github/workflows/audit.yml (which builds and tests every
# formula). These tests are the local mirror of that pipeline: they exercise the
# same updater boundary without importing Python or calling GitHub.
#
# The updater is driven as a black box through Open3.capture3("python3",
# "scripts/update_versions.py", "--fixture", <tmpdir>, ...) so this file has no
# Python import and no Rubocop dependency. Every fixture under
# test/fixtures/update_versions/ carries an api-mocks/responses.json file; the
# MockFetcher that the --fixture flag swaps in reads from it and refuses to fall
# back to the network.

require 'minitest/autorun'
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'pathname'
require 'tmpdir'

ROOT = Pathname(__FILE__).realpath.parent.parent.freeze
SCRIPT = (ROOT / 'scripts' / 'update_versions.py').freeze
FIXTURES = (ROOT / 'test' / 'fixtures' / 'update_versions').freeze
EXPECTED_FILES = %w[
  Formula/camilladsp.rb
  Formula/camillagui.rb
  Formula/pycamilladsp.rb
  Formula/pycamilladsp-plot.rb
  Formula/camilladsp-setupscripts.rb
  Formula/camilladsp-config.rb
  Formula/camilladsp-controller.rb
  Formula/camilladsp-suite.rb
].freeze

class UpdateVersionsTest < Minitest::Test
  def with_fixture(name = 'happy')
    Dir.mktmpdir('update-versions') do |directory|
      root = Pathname(directory)
      FileUtils.cp_r("#{FIXTURES / name}/.", root.to_s)
      yield root
    end
  end

  def run_updater(root, env = {})
    Open3.capture3(env, 'python3', SCRIPT.to_s, '--fixture', root.to_s, chdir: ROOT.to_s)
  end

  def snapshot(root, missing: [])
    EXPECTED_FILES.to_h do |relative|
      path = root / relative
      digest = if missing.include?(relative) || !path.exist?
                 nil
               else
                 Digest::SHA256.file(path.to_s).hexdigest
               end
      [relative, digest]
    end
  end

  def api_responses(root)
    path = root / 'api-mocks' / 'responses.json'
    [path, JSON.parse(path.read)]
  end

  def remove_response(root, url)
    path, responses = api_responses(root)
    responses.reject! { |response| response['url'] == url }
    path.write("#{JSON.pretty_generate(responses)}\n")
  end

  def test_formula_hashes_urls_revisions_and_shas_are_updated
    with_fixture do |root|
      stdout, stderr, status = run_updater(root)
      assert status.success?, "stdout=#{stdout}\nstderr=#{stderr}"

      gui = File.read((root / 'Formula/camillagui.rb').to_s)
      refute_match(/^\s*version\s+/, gui, 'camillagui formula has no top-level version line')
      assert_includes gui, "'3333333333333333333333333333333333333333333333333333333333333333'"
      assert_includes gui, "'4444444444444444444444444444444444444444444444444444444444444444'"

      core = File.read((root / 'Formula/camilladsp.rb').to_s)
      assert_includes core, 'releases/download/v2.0.0/camilladsp-macos-aarch64.tar.gz'
      assert_includes core, 'releases/download/v2.0.0/camilladsp-macos-amd64.tar.gz'
      assert_includes core, "sha256 '1111111111111111111111111111111111111111111111111111111111111111'"
      assert_includes core, "sha256 '2222222222222222222222222222222222222222222222222222222222222222'"
    end
  end

  def test_python_resources_urls_and_sha256_are_updated
    with_fixture do |root|
      stdout, stderr, status = run_updater(root)
      assert status.success?, "stdout=#{stdout}\nstderr=#{stderr}"
      text = File.read((root / 'Formula/pycamilladsp.rb').to_s)
      assert_includes text, 'packages/new/pyyaml-2.0.0.tar.gz'
      assert_includes text, 'abababababababababababababababababababababababababababababababab'
      assert_includes text, 'packages/new/websocket_client-2.0.0.tar.gz'
      assert_includes text, 'cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd'
    end
  end

  def test_zero_substitutions_returns_one_and_preserves_snapshot
    with_fixture do |root|
      gui_path = root / 'Formula/camillagui.rb'
      gui = File.read(gui_path.to_s).sub(/^[[:space:]]*sha256.*$/, '  # no checksum stanza')
      gui_path.write(gui)
      before = snapshot(root)
      _, stderr, status = run_updater(root)
      refute status.success?
      assert_equal 1, status.exitstatus
      assert_includes stderr, 'expected exactly one substitution, found 0'
      assert_equal before, snapshot(root)
    end
  end

  def test_multiple_substitutions_returns_one_and_preserves_snapshot
    with_fixture do |root|
      gui_path = root / 'Formula/camillagui.rb'
      gui = File.read(gui_path.to_s)
      # Insert a second url+sha256 pair for the same ARM asset BEFORE the
      # existing one, so the updater's regex finds 2 matches and aborts.
      duplicate = "  url 'https://github.com/HEnquist/camillagui-backend/releases/download/v1.0.0/bundle_macos_aarch64.tar.gz'\n" \
                  "  sha256 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'\n"
      gui_path.write(gui.sub(/^  url.*bundle_macos_aarch64/, "#{duplicate}\\0"))
      before = snapshot(root)
      _, stderr, status = run_updater(root)
      refute status.success?
      assert_equal 1, status.exitstatus
      assert_includes stderr, 'expected exactly one substitution, found 2'
      assert_equal before, snapshot(root)
    end
  end

  def test_missing_asset_returns_one_and_preserves_snapshot
    with_fixture do |root|
      path, responses = api_responses(root)
      response = responses.find { |item| item['url'].end_with?('/camillagui-backend/releases/latest') }
      response['body']['assets'].delete_if { |asset| asset['name'] == 'bundle_macos_intel.tar.gz' }
      path.write("#{JSON.pretty_generate(responses)}\n")
      before = snapshot(root)
      _, stderr, status = run_updater(root)
      refute status.success?
      assert_includes stderr, "Missing asset 'bundle_macos_intel.tar.gz'"
      assert_equal before, snapshot(root)
    end
  end

  def test_nonexistent_branch_returns_one_and_preserves_snapshot
    with_fixture do |root|
      remove_response(root, 'https://api.github.com/repos/HEnquist/camilladsp-config/commits/master')
      before = snapshot(root)
      _, stderr, status = run_updater(root)
      refute status.success?
      assert_includes stderr, 'Fixture has no API response'
      assert_equal before, snapshot(root)
    end
  end

  def test_nonexistent_tag_returns_one_and_preserves_snapshot
    with_fixture do |root|
      path, responses = api_responses(root)
      response = responses.find { |item| item['url'].end_with?('/pycamilladsp/releases/latest') }
      response['body']['tag_name'] = 'v9.9.9'
      path.write("#{JSON.pretty_generate(responses)}\n")
      before = snapshot(root)
      _, stderr, status = run_updater(root)
      refute status.success?
      assert_includes stderr, 'Fixture has no API response'
      assert_equal before, snapshot(root)
    end
  end

  # Up-to-date fixture: every URL, revision, version, and SHA-256 in the
  # fixtures already matches what api-mocks/responses.json returns. Running the
  # updater must produce zero changes and zero diff.
  def test_up_to_date_fixture_produces_no_changes
    with_fixture('up-to-date') do |root|
      before = snapshot(root)
      stdout, stderr, status = run_updater(root)
      assert status.success?, "stdout=#{stdout}\nstderr=#{stderr}"
      assert_equal before, snapshot(root), 'up-to-date fixture must stay byte-identical'
    end
  end

  # True re-run idempotency: the same fixture is updated once (producing a diff)
  # and then the updater is run a second time on the now-updated state. The
  # second run must succeed and produce zero diff. This is the contract that
  # makes the updater safe to run from CI on every push.
  def test_idempotency_running_twice_produces_no_diff_second_time
    with_fixture do |root|
      first_stdout, first_stderr, first_status = run_updater(root)
      assert first_status.success?, "first run failed: stdout=#{first_stdout}\nstderr=#{first_stderr}"
      after_first = snapshot(root)
      refute_equal snapshot_for_unmutated_fixture, after_first,
                   'first run must change the fixture'
      second_stdout, second_stderr, second_status = run_updater(root)
      assert second_status.success?,
             "second run failed: stdout=#{second_stdout}\nstderr=#{second_stderr}"
      assert_equal after_first, snapshot(root),
                   'second run must leave the fixture byte-identical'
    end
  end

  def test_atomic_mid_write_failure_restores_every_file
    with_fixture do |root|
      before = snapshot(root)
      _, stderr, status = run_updater(root, 'UPDATE_VERSIONS_FAIL_AFTER_WRITES' => '2')
      refute status.success?
      assert_equal 1, status.exitstatus
      assert_includes stderr, 'simulated mid-write failure'
      assert_equal before, snapshot(root)
    end
  end

  def test_rogue_extra_formula_file_fails_scope_check
    with_fixture do |root|
      File.write((root / 'Formula/sneaky.rb').to_s, "class Sneaky < Formula\nend\n")
      before = snapshot(root)
      _, stderr, status = run_updater(root)
      refute status.success?
      assert_includes stderr, 'Unexpected updater scope'
      assert_equal before, snapshot(root)
    end
  end

  def test_rogue_extra_cask_file_fails_scope_check
    with_fixture do |root|
      File.write((root / 'Formula/sneaky.rb').to_s, %(class Sneaky < Formula\nend\n))
      before = snapshot(root)
      _, stderr, status = run_updater(root)
      refute status.success?
      assert_includes stderr, 'Unexpected updater scope'
      assert_equal before, snapshot(root)
    end
  end

  def test_missing_expected_formula_file_fails_scope_check
    with_fixture do |root|
      File.unlink((root / 'Formula/camilladsp-config.rb').to_s)
      _, stderr, status = run_updater(root)
      refute status.success?
      assert_includes stderr, 'Unexpected updater scope'
      refute (root / 'Formula/camilladsp-config.rb').exist?,
             'failed scope check must not recreate deleted files'
    end
  end

  # MockFetcher is the offline-only API surface the updater loads when --fixture
  # is passed. If someone ever sneaks a real HTTP fallback into MockFetcher (or
  # wires urllib.request through it), the fixture-driven test suite would
  # silently start making real network calls. This static guard catches that
  # regression by asserting the class body never references an HTTP client.
  def test_mock_fetcher_makes_no_real_network_calls
    source = File.read(SCRIPT.to_s)
    class_match = source.match(/^class MockFetcher:.*?^(?=\S)/m)
    refute_nil class_match, 'MockFetcher class not found in scripts/update_versions.py'
    body = class_match[0]
    refute_match(/urlopen|urllib\.request|http\.client|httpx|requests\.|aiohttp/, body,
                 'MockFetcher must not make real HTTP calls; fixtures are the only API surface')
  end

  # Supply-chain hardening: a non-HTTPS release asset URL must be rejected
  # before the updater writes it into a Ruby formula. The fixture is mutated
  # to swap the engine ARM asset URL to http:// and the test asserts the
  # updater exits non-zero without touching any file on disk.
  def test_rejects_http_url
    with_fixture do |root|
      path, responses = api_responses(root)
      response = responses.find do |item|
        item['url'].end_with?('/camilladsp/releases/latest')
      end
      response['body']['assets'][0]['browser_download_url'] =
        'http://github.com/HEnquist/camilladsp/releases/download/' \
        'v2.0.0/camilladsp-macos-aarch64.tar.gz'
      path.write("#{JSON.pretty_generate(responses)}\n")
      before = snapshot(root)
      _, stderr, status = run_updater(root)
      refute status.success?, "updater must reject non-HTTPS URLs, stderr=#{stderr}"
      assert_equal 1, status.exitstatus
      assert_includes stderr, 'URL scheme must be https'
      assert_equal before, snapshot(root),
                   'failed URL validation must not touch any file on disk'
    end
  end

  # Supply-chain hardening: a release asset URL pointing at a host outside
  # the allowlist (here, evil.example.com) must be rejected before it is
  # written into a Ruby formula. Same isolation contract as the HTTP test.
  def test_rejects_non_allowlisted_host
    with_fixture do |root|
      path, responses = api_responses(root)
      response = responses.find do |item|
        item['url'].end_with?('/camilladsp/releases/latest')
      end
      response['body']['assets'][0]['browser_download_url'] =
        'https://evil.example.com/camilladsp-macos-aarch64.tar.gz'
      path.write("#{JSON.pretty_generate(responses)}\n")
      before = snapshot(root)
      _, stderr, status = run_updater(root)
      refute status.success?, "updater must reject off-allowlist hosts, stderr=#{stderr}"
      assert_equal 1, status.exitstatus
      assert_includes stderr, 'not in the allowlist'
      assert_equal before, snapshot(root),
                   'failed host validation must not touch any file on disk'
    end
  end

  # Supply-chain hardening: a URL containing a double-quote character would
  # close the Ruby string literal in the formula and inject arbitrary Ruby.
  # The updater must reject any URL that contains ", ', \, CR, LF, TAB, or
  # NUL.
  def test_rejects_url_with_double_quote
    with_fixture do |root|
      path, responses = api_responses(root)
      response = responses.find do |item|
        item['url'].end_with?('/camilladsp/releases/latest')
      end
      response['body']['assets'][0]['browser_download_url'] =
        'https://github.com/HEnquist/camilladsp/releases/download/' \
        'v2.0.0/camilladsp-macos-aarch64.tar.gz"; system \'evil\'; "'
      path.write("#{JSON.pretty_generate(responses)}\n")
      before = snapshot(root)
      _, stderr, status = run_updater(root)
      refute status.success?, "updater must reject URLs with forbidden characters, stderr=#{stderr}"
      assert_equal 1, status.exitstatus
      assert_includes stderr, 'forbidden characters'
      assert_equal before, snapshot(root),
                   'failed character validation must not touch any file on disk'
    end
  end

  # Tag dereference: GitHub returns object.type=="tag" for an annotated tag,
  # with object.url pointing at the tag object that must be fetched to reach
  # the underlying commit. The fixture simulates this: the refs response
  # points at a synthetic tag object URL, which in turn wraps a commit. The
  # formula must end up pinned to the commit SHA, not the tag-object SHA.
  def test_derefs_annotated_tag_to_commit
    with_fixture do |root|
      path, responses = api_responses(root)
      tag_url = responses.find do |item|
        item['url'].end_with?('/pycamilladsp/git/refs/tags/v2.0.0')
      end
      tag_sha = 'cccccccccccccccccccccccccccccccccccccccc'
      commit_sha = '9999999999999999999999999999999999999999'
      tag_object_url = 'https://api.github.com/repos/HEnquist/pycamilladsp/git/tags/ccc-tag-object'
      tag_url['body'] = {
        'object' => {
          'type' => 'tag',
          'sha' => tag_sha,
          'url' => tag_object_url
        }
      }
      responses << {
        'url' => tag_object_url,
        'body' => {
          'tag' => 'v2.0.0',
          'sha' => tag_sha,
          'object' => {
            'type' => 'commit',
            'sha' => commit_sha
          }
        }
      }
      path.write("#{JSON.pretty_generate(responses)}\n")
      stdout, stderr, status = run_updater(root)
      assert status.success?, "updater must dereference annotated tags, stdout=#{stdout}\nstderr=#{stderr}"
      text = File.read((root / 'Formula/pycamilladsp.rb').to_s)
      assert_includes text, "revision: '#{commit_sha}'",
                      'formula must pin the underlying commit SHA, not the tag-object SHA'
      refute_includes text, "revision: '#{tag_sha}'",
                      'formula must not retain the annotated tag-object SHA'
    end
  end

  private

  # Snapshot of the happy fixture as it lives under test/fixtures. Used by
  # test_idempotency_running_twice_produces_no_diff_second_time to assert that
  # the first run actually changes something before the second run is checked.
  def snapshot_for_unmutated_fixture
    fixture_root = FIXTURES / 'happy'
    EXPECTED_FILES.to_h do |relative|
      path = fixture_root / relative
      [relative, Digest::SHA256.file(path.to_s).hexdigest]
    end
  end
end
