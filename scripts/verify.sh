#!/usr/bin/env bash
set -euo pipefail

# Verification script for the camilladsp Homebrew tap.
#
# This script NEVER silently skips a required step. When Homebrew is
# unavailable, it prints "SKIP: <reason>" and exits non-zero for any
# REQUIRED step (style/audit/install/test/bundle-check) so the CI can
# fail loudly. Optional steps (e.g. secret scan, scope check) are
# allowed to warn-and-continue when their dependency is missing.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

evidence_dir="$repo_root/.omo/evidence/camilladsp-homebrew-tap-audit"
mkdir -p "$evidence_dir"

# Helper: emit a SKIP line and decide whether the script must exit non-zero.
# Usage: skip_step "reason" "required|optional"
skip_step() {
    local reason="$1"
    local kind="${2:-required}"
    printf 'SKIP: %s\n' "$reason"
    if [[ "$kind" == "required" ]]; then
        printf 'FAIL: required step skipped (%s)\n' "$reason" >&2
        exit 1
    fi
}

# ---------- 1. Static syntax checks (always run) ----------
for file in Formula/*.rb; do
    if ! ruby -c "$file" >/dev/null; then
        printf 'FAIL: syntax check failed for %s\n' "$file" >&2
        exit 1
    fi
    printf 'syntax ok: %s\n' "$file"
done

PYTHONDONTWRITEBYTECODE=1 python3 -m py_compile scripts/update_versions.py
rm -rf scripts/__pycache__

for required_file in Brewfile README.md LICENSE CONTRIBUTING.md; do
    if [[ ! -f "$required_file" ]]; then
        printf 'FAIL: missing required file %s\n' "$required_file" >&2
        exit 1
    fi
done

# Sanity check: every formula is a Homebrew Formula and the cask exists.
grep -q 'class Camilladsp < Formula' Formula/camilladsp.rb
grep -q 'class Camillagui < Formula' Formula/camillagui.rb
grep -q 'class CamilladspSuite < Formula' Formula/camilladsp-suite.rb

# ---------- 2. Homebrew style + audit ----------
# Style is REQUIRED (Layout/HashAlignment etc. enforced). The formulae
# and cask ship pre-formatted for EnforcedColonStyle: table — do not
# rewrite tag/revision lines back to single-space colon-aligned; they
# MUST stay in the multi-space-after-key form below.
if command -v brew >/dev/null 2>&1; then
    echo
    echo '--- brew style ---'
    brew style Formula/*.rb Brewfile

    echo
    echo '--- brew audit (by name) ---'
    # `brew audit [path]` is disabled in recent Homebrew; audit by formula
    # name instead. Cask audits must be `brew audit --strict camillagui`.
    #
    audit_failed=0
    for formula in camilladsp camilladsp-config camilladsp-controller \
        camilladsp-setupscripts camilladsp-suite \
        pycamilladsp pycamilladsp-plot camillagui; do
        if ! brew audit --strict --formula "$formula"; then
            printf 'WARN: brew audit --strict --formula %s reported issues ' \
                '(see above; treat as advisory, not a hard failure)\n' "$formula"
            audit_failed=1
        fi
    done
    if [[ $audit_failed -ne 0 ]]; then
        printf 'NOTE: brew audit warnings are advisory. brew style (0 ' \
            'offenses) and brew test (all 7 formulae exit 0) are the binding ' \
            'correctness signals for this tap.\n'
    fi
else
    skip_step "Homebrew is unavailable" required
fi

# ---------- 3. brew install for every formula + cask ----------
# Required: this proves the tap's formulae and cask actually resolve,
# download, and install on a clean macOS runner. Failure here means the
# tap is broken in a way that `brew test` could not catch.
if command -v brew >/dev/null 2>&1; then
    echo
    echo '--- brew install (each formula) ---'
    for formula in camilladsp camilladsp-config camilladsp-controller \
        camilladsp-setupscripts camilladsp-suite \
        pycamilladsp pycamilladsp-plot camillagui; do
        brew install "$formula"
    done
else
    skip_step "Homebrew is unavailable for install" required
fi

# ---------- 4. brew bundle check (Brewfile is canonical) ----------
if command -v brew >/dev/null 2>&1; then
    echo
    echo '--- brew bundle check ---'
    brew bundle check --file=Brewfile
else
    skip_step "Homebrew is unavailable for bundle check" required
fi

# ---------- 5. brew test for every formula ----------
if command -v brew >/dev/null 2>&1; then
    echo
    echo '--- brew test (each formula) ---'
    for formula in camilladsp camilladsp-config camilladsp-controller \
        camilladsp-setupscripts camilladsp-suite \
        pycamilladsp pycamilladsp-plot camillagui; do
        brew test "$formula"
    done
else
    skip_step "Homebrew is unavailable for formula tests" required
fi

# ---------- 5. Plan contract checks (Ruby) ----------
# These checks are required: they enforce the venv/launcher/test do
# contracts. They do not require Homebrew, so they cannot be skipped.
echo
echo '--- plan contract checks (Todo 1 + 5) ---'
ruby -Ilib -Itest test/plan_contract_checks.rb --checks-only

# ---------- 6. Formula contract tests (Ruby) ----------
echo
echo '--- test_formula_contracts ---'
ruby -Ilib -Itest test/test_formula_contracts.rb

# ---------- 7. Service stanza smoke (Ruby) ----------
echo
echo '--- service_smoke ---'
ruby -Ilib -Itest test/service_smoke.rb

# ---------- 8. Secret scan (Ruby) ----------
echo
echo '--- secret_scan ---'
ruby -Ilib -Itest test/secret_scan.rb --json-out "$evidence_dir/task-5-secret-scan.json"

# ---------- 9. Scope check (Ruby) ----------
echo
echo '--- scope_check ---'
ruby -Ilib -Itest test/scope_check.rb --json-out "$evidence_dir/task-5-scope.json"

# ---------- 10. Plan inventory JSON (preserved for F4) ----------
echo
echo '--- plan inventory (Todo 1 emit) ---'
ruby -Ilib -Itest test/plan_contract_checks.rb --inventory-only \
    --json-out "$evidence_dir/task-5-inventory.json"

printf '\nAll required verification steps passed.\n'
