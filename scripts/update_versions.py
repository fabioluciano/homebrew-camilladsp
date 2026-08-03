#!/usr/bin/env python3
"""Update CamillaDSP release pins transactionally and deterministically."""

from __future__ import annotations

import hashlib
import json
import os
import re
import stat
import sys
import tempfile
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Callable, Mapping, cast

ROOT = Path(__file__).resolve().parents[1]
API = "https://api.github.com/repos/{repo}/releases/latest"
# Hard allowlist of hosts the updater is willing to write into formulae.
# Anything outside this set is rejected before the URL is interpolated into a
# Ruby string literal. Adding a new host requires an explicit decision here.
ALLOWED_URL_HOSTS = frozenset(
    {
        "github.com",
        "objects.githubusercontent.com",
        "files.pythonhosted.org",
        "pypi.org",
        "pypi.io",
    }
)
# Basename allowlist for the per-asset URL paths we expect from each release.
ENGINE_MACOS_BASENAMES = (
    "camilladsp-macos-aarch64.tar.gz",
    "camilladsp-macos-amd64.tar.gz",
)
GUI_BUNDLE_BASENAMES = (
    "bundle_macos_aarch64.tar.gz",
    "bundle_macos_intel.tar.gz",
)
# Annotated tag dereference: GitHub returns `object.type == "tag"` for an
# annotated tag, with `object.url` pointing at the tag object that must be
# fetched to reach the underlying commit. Cap recursion to prevent cycles.
TAG_DEREF_MAX_DEPTH = 5
EXPECTED_FILES = (
    Path("Formula/camilladsp.rb"),
    Path("Formula/camillagui.rb"),
    Path("Formula/pycamilladsp.rb"),
    Path("Formula/pycamilladsp-plot.rb"),
    Path("Formula/camilladsp-setupscripts.rb"),
    Path("Formula/camilladsp-config.rb"),
    Path("Formula/camilladsp-controller.rb"),
    Path("Formula/camilladsp-suite.rb"),
)
EXPECTED_FORMULA_FILES = {
    path.name for path in EXPECTED_FILES if path.parts[0] == "Formula"
}

Fetcher = Callable[[str], Mapping[str, object]]


class MockFetcher:
    """Read API responses from a fixture; it deliberately has no HTTP fallback."""

    def __init__(self, fixture_root: Path) -> None:
        mock_path = fixture_root / "api-mocks" / "responses.json"
        payload = json.loads(mock_path.read_text(encoding="utf-8"))
        self.responses = {item["url"]: item["body"] for item in payload}

    def __call__(self, url: str) -> Mapping[str, object]:
        try:
            return self.responses[url]
        except KeyError as exc:
            raise RuntimeError(f"Fixture has no API response for {url}") from exc


def github_json(url: str) -> Mapping[str, object]:
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "homebrew-camilladsp-updater",
    }
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request) as response:
        return json.load(response)


def pypi_json(url: str) -> Mapping[str, object]:
    request = urllib.request.Request(
        url, headers={"User-Agent": "homebrew-camilladsp-updater"}
    )
    with urllib.request.urlopen(request) as response:
        return json.load(response)


def download_sha256(url: str) -> str:
    headers = {"User-Agent": "homebrew-camilladsp-updater"}
    token = os.environ.get("GITHUB_TOKEN")
    if token and "github.com" in url:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, headers=headers)
    digest = hashlib.sha256()
    with urllib.request.urlopen(request) as response:
        while chunk := response.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def ensure_sha(value: object, description: str) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
        raise RuntimeError(f"Invalid SHA-256 for {description}")
    return value


def ensure_revision(value: object, description: str) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{40}", value):
        raise RuntimeError(f"Invalid Git revision for {description}")
    return value


# Characters that could break out of a Ruby string literal (`"`, `'`, `\`) or
# smuggle in a new line for log-injection style attacks (CR/LF/TAB/NUL).
URL_FORBIDDEN_CHARACTERS = "\"'\\\r\n\t\0"


def validate_release_url(url: object, description: str) -> str:
    """Validate an upstream URL before it is interpolated into a Ruby formula.

    Rejects:
    * non-string or empty URLs
    * control characters (CR/LF/TAB/NUL) and quote/backslash characters that
      could close a Ruby string literal or smuggle in a new line
    * non-HTTPS schemes
    * hosts outside the hard allowlist in ALLOWED_URL_HOSTS

    Returns the validated URL on success.
    """
    if not isinstance(url, str) or not url:
        raise RuntimeError(f"{description}: URL must be a non-empty string")
    if any(c in url for c in URL_FORBIDDEN_CHARACTERS):
        raise RuntimeError(
            f"{description}: URL contains forbidden characters "
            "(quote, backslash, or control character)"
        )
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "https":
        raise RuntimeError(
            f"{description}: URL scheme must be https, got {parsed.scheme!r}"
        )
    host = parsed.netloc.lower()
    if host not in ALLOWED_URL_HOSTS:
        raise RuntimeError(
            f"{description}: URL host {host!r} is not in the allowlist "
            f"{sorted(ALLOWED_URL_HOSTS)}"
        )
    print(
        f"validated release URL for {description}: https://{host}{parsed.path}",
        file=sys.stderr,
    )
    return url


def assert_asset_basename(url: str, allowed: tuple[str, ...], description: str) -> None:
    """Reject URLs whose path does not end with one of the allowed basenames."""
    parsed = urllib.parse.urlparse(url)
    basename = parsed.path.rsplit("/", 1)[-1]
    if basename not in allowed:
        raise RuntimeError(
            f"{description}: asset basename {basename!r} is not in the allowlist "
            f"{list(allowed)}"
        )


def _deref_tag(fetch: Fetcher, ref_obj: object, depth: int = 0) -> str:
    """Dereference a GitHub refs/tags response to its underlying commit SHA.

    Handles annotated tags by recursing into the tag object via its `url`.
    A lightweight tag returns `object.type == "commit"` (or omits the field
    entirely in some API responses), which is treated as the terminal case.
    Both the refs response and the tag object response wrap their payload in
    an `object` envelope, so we always look at `ref_obj["object"]` if present
    before falling back to the top-level mapping.
    """
    if depth > TAG_DEREF_MAX_DEPTH:
        raise RuntimeError(
            f"Annotated tag dereference exceeded max depth "
            f"({TAG_DEREF_MAX_DEPTH}); possible cycle"
        )
    if not isinstance(ref_obj, Mapping):
        raise RuntimeError(
            f"Tag dereference at depth {depth} returned a non-object response"
        )
    inner = ref_obj.get("object")
    target = inner if isinstance(inner, Mapping) else ref_obj
    obj_type = target.get("type")
    if obj_type == "tag":
        tag_url = target.get("url")
        if not isinstance(tag_url, str) or not tag_url:
            raise RuntimeError(
                f"Annotated tag at depth {depth} has no object URL to dereference"
            )
        nested = fetch(tag_url)
        return _deref_tag(fetch, nested, depth + 1)
    if obj_type in (None, "commit"):
        sha = target.get("sha")
        return ensure_revision(sha, f"tag object (type={obj_type!r}) at depth {depth}")
    raise RuntimeError(f"Unexpected tag object type {obj_type!r} at depth {depth}")


def substitute_exact(
    text: str,
    pattern: str,
    replacement: str | Callable[[re.Match[str]], str],
    label: str,
) -> str:
    matches = list(re.finditer(pattern, text, flags=re.MULTILINE | re.DOTALL))
    if len(matches) != 1:
        raise RuntimeError(
            f"{label}: expected exactly one substitution, found {len(matches)}"
        )
    return re.sub(pattern, replacement, text, count=1, flags=re.MULTILINE | re.DOTALL)


def replace_line_once(text: str, pattern: str, replacement: str, label: str) -> str:
    return substitute_exact(text, pattern, replacement, label)


def validate_scope(root: Path) -> None:
    formulae = {path.name for path in (root / "Formula").glob("*.rb")}
    if formulae != EXPECTED_FORMULA_FILES:
        raise RuntimeError(
            "Unexpected updater scope: expected Formula/*.rb to be "
            f"{sorted(EXPECTED_FORMULA_FILES)}, found {sorted(formulae)}"
        )


def release(fetch: Fetcher, repo: str) -> Mapping[str, object]:
    result = fetch(API.format(repo=repo))
    tag = result.get("tag_name")
    if not isinstance(tag, str) or not tag:
        raise RuntimeError(f"Release for {repo} has no tag_name")
    return result


def validate_tag(fetch: Fetcher, repo: str, tag: str) -> str:
    url = f"https://api.github.com/repos/{repo}/git/refs/tags/{urllib.parse.quote(tag, safe='')}"
    ref = fetch(url)
    obj = ref.get("object") if isinstance(ref, Mapping) else None
    return _deref_tag(fetch, obj)


def release_assets(
    fetch: Fetcher, repo: str, names: tuple[str, ...]
) -> tuple[str, dict[str, tuple[str, str]]]:
    data = release(fetch, repo)
    tag = str(data["tag_name"])
    validate_tag(fetch, repo, tag)
    raw_assets = data.get("assets")
    if not isinstance(raw_assets, list):
        raise RuntimeError(f"Release {repo}@{tag} has no asset list")
    assets_by_name = {
        asset.get("name"): asset
        for asset in raw_assets
        if isinstance(asset, Mapping) and isinstance(asset.get("name"), str)
    }
    result: dict[str, tuple[str, str]] = {}
    for name in names:
        asset = assets_by_name.get(name)
        if not isinstance(asset, Mapping):
            raise RuntimeError(f"Missing asset {name!r} in {repo} release {tag}")
        url = asset.get("browser_download_url")
        if not isinstance(url, str) or not url:
            raise RuntimeError(
                f"Asset {name!r} in {repo} release {tag} has no download URL"
            )
        validate_release_url(url, f"asset {repo}@{tag}/{name}")
        digest = asset.get("digest") or asset.get("sha256")
        if isinstance(digest, str) and digest.startswith("sha256:"):
            digest = digest.removeprefix("sha256:")
        if digest is None:
            if isinstance(fetch, MockFetcher):
                raise RuntimeError(
                    f"Asset {name!r} in {repo} release {tag} has no SHA-256 digest"
                )
            digest = download_sha256(url)
        result[name] = (url, ensure_sha(digest, f"asset {repo}@{tag}/{name}"))
    return tag.removeprefix("v"), result


def update_version(text: str, version: str, path: Path) -> str:
    pattern = r"^([ \t]*version[ \t]+)(['\"])[^'\"]+\2"
    if not re.search(pattern, text, flags=re.MULTILINE):
        return text
    return replace_line_once(
        text,
        pattern,
        rf"\g<1>\g<2>{version}\g<2>",
        f"{path}: version",
    )


def update_core(root: Path, fetch: Fetcher) -> tuple[str, str]:
    arm_name = "camilladsp-macos-aarch64.tar.gz"
    intel_name = "camilladsp-macos-amd64.tar.gz"
    version, assets = release_assets(
        fetch, "HEnquist/camilladsp", (arm_name, intel_name)
    )
    assert_asset_basename(
        assets[arm_name][0], ENGINE_MACOS_BASENAMES, f"engine asset {arm_name}"
    )
    assert_asset_basename(
        assets[intel_name][0], ENGINE_MACOS_BASENAMES, f"engine asset {intel_name}"
    )
    path = root / "Formula/camilladsp.rb"
    text = update_version(path.read_text(encoding="utf-8"), version, path)
    text = replace_line_once(
        text,
        r'(^[ \t]*url[ \t]+["\'])(?:[^"\']*/)?camilladsp-macos-aarch64\.tar\.gz(["\'])\n([ \t]*sha256[ \t]+["\'])[0-9a-f]+(["\'])',
        rf"\g<1>{assets[arm_name][0]}\g<2>\n\g<3>{assets[arm_name][1]}\g<4>",
        f"{path}: ARM asset",
    )
    text = replace_line_once(
        text,
        r'(^[ \t]*url[ \t]+["\'])(?:[^"\']*/)?camilladsp-macos-amd64\.tar\.gz(["\'])\n([ \t]*sha256[ \t]+["\'])[0-9a-f]+(["\'])',
        rf"\g<1>{assets[intel_name][0]}\g<2>\n\g<3>{assets[intel_name][1]}\g<4>",
        f"{path}: Intel asset",
    )
    return version, text


def update_gui(root: Path, fetch: Fetcher) -> tuple[str, str]:
    arm_name = "bundle_macos_aarch64.tar.gz"
    intel_name = "bundle_macos_intel.tar.gz"
    version, assets = release_assets(
        fetch, "HEnquist/camillagui-backend", (arm_name, intel_name)
    )
    assert_asset_basename(
        assets[arm_name][0], GUI_BUNDLE_BASENAMES, f"GUI bundle {arm_name}"
    )
    assert_asset_basename(
        assets[intel_name][0], GUI_BUNDLE_BASENAMES, f"GUI bundle {intel_name}"
    )
    path = root / "Formula/camillagui.rb"
    text = update_version(path.read_text(encoding="utf-8"), version, path)
    text = replace_line_once(
        text,
        r'(^[ \t]*url[ \t]+["\'])(?:[^"\']*/)?bundle_macos_aarch64\.tar\.gz(["\'])\n([ \t]*sha256[ \t]+["\'])[0-9a-f]+(["\'])',
        rf"\g<1>{assets[arm_name][0]}\g<2>\n\g<3>{assets[arm_name][1]}\g<4>",
        f"{path}: ARM asset",
    )
    text = replace_line_once(
        text,
        r'(^[ \t]*url[ \t]+["\'])(?:[^"\']*/)?bundle_macos_intel\.tar\.gz(["\'])\n([ \t]*sha256[ \t]+["\'])[0-9a-f]+(["\'])',
        rf"\g<1>{assets[intel_name][0]}\g<2>\n\g<3>{assets[intel_name][1]}\g<4>",
        f"{path}: Intel asset",
    )
    return version, text


def tagged_source(
    root: Path, fetch: Fetcher, repo: str, label: str
) -> tuple[str, str, Mapping[str, object]]:
    data = release(fetch, repo)
    tag = str(data["tag_name"])
    revision = validate_tag(fetch, repo, tag)
    return tag.removeprefix("v"), tag, {"revision": revision}


def update_tagged_formula(
    root: Path, fetch: Fetcher, repo: str, filename: str
) -> tuple[str, str]:
    version, tag, metadata = tagged_source(root, fetch, repo, filename)
    path = root / "Formula" / filename
    text = path.read_text(encoding="utf-8")
    text = replace_line_once(
        text,
        r"(?P<prefix>^(?:[ \t]*)|,[ \t]*)tag[ \t]*:[ \t]+(['\"])[^'\"]+\2",
        rf"\g<1>tag:      \g<2>{tag}\g<2>",
        f"{path}: tag",
    )
    text = replace_line_once(
        text,
        r"(?P<prefix>^(?:[ \t]*)|,[ \t]*)revision:[ \t]+(['\"])[0-9a-f]+\2",
        rf"\g<1>revision: \g<2>{metadata['revision']}\g<2>",
        f"{path}: revision",
    )
    text = update_resources(path, text, fetch)
    return version, text


def update_resources(path: Path, text: str, fetch: Fetcher) -> str:
    resource_pattern = r'^  resource ["\']([^"\']+)["\'] do\s*\n(.*?)(?=^  end\b)'
    resource_names = [
        match.group(1)
        for match in re.finditer(resource_pattern, text, flags=re.MULTILINE | re.DOTALL)
        if re.search(r"^[ \t]*sha256[ \t]+", match.group(2), flags=re.MULTILINE)
    ]
    for name in resource_names:
        data = fetch(f"https://pypi.org/pypi/{urllib.parse.quote(name)}/json")
        urls = data.get("urls")
        if not isinstance(urls, list):
            raise RuntimeError(f"PyPI resource {name!r} has no release files")
        source = next(
            (
                item
                for item in urls
                if isinstance(item, Mapping) and item.get("packagetype") == "sdist"
            ),
            None,
        )
        if source is None:
            raise RuntimeError(f"PyPI resource {name!r} has no source distribution")
        source = cast(Mapping[str, object], source)
        url = source.get("url")
        digests = source.get("digests")
        digest = digests.get("sha256") if isinstance(digests, Mapping) else None
        sha = ensure_sha(digest, f"PyPI resource {name}")
        if not isinstance(url, str) or not url:
            raise RuntimeError(f"PyPI resource {name!r} has no source URL")
        validate_release_url(url, f"PyPI resource {name}")
        escaped = re.escape(name)
        block_pattern = rf"(^  resource [\"']{escaped}[\"'] do\s*\n)(.*?)(?=^  end\b)"

        def replace_block(match: re.Match[str]) -> str:
            body = match.group(2)
            body = replace_line_once(
                body,
                r"(^[ \t]*url[ \t]+)(['\"])[^'\"]+\2",
                rf"\g<1>\g<2>{url}\g<2>",
                f"{path}: resource {name} URL",
            )
            body = replace_line_once(
                body,
                r"(^[ \t]*sha256[ \t]+)(['\"])[0-9a-f]+\2",
                rf"\g<1>\g<2>{sha}\g<2>",
                f"{path}: resource {name} SHA-256",
            )
            return match.group(1) + body

        text = substitute_exact(
            text, block_pattern, replace_block, f"{path}: resource {name} block"
        )
    return text


def update_branch_formula(
    root: Path, fetch: Fetcher, repo: str, branch: str, filename: str
) -> tuple[str, str]:
    url = f"https://api.github.com/repos/{repo}/commits/{branch}"
    commit = fetch(url)
    sha = ensure_revision(commit.get("sha"), f"branch {repo}/{branch}")
    commit_data = commit.get("commit")
    committer = (
        commit_data.get("committer") if isinstance(commit_data, Mapping) else None
    )
    date = committer.get("date") if isinstance(committer, Mapping) else None
    if not isinstance(date, str) or len(date) < 10:
        raise RuntimeError(f"Branch {repo}/{branch} has no commit date")
    version = date[:10].replace("-", ".")
    path = root / "Formula" / filename
    text = update_version(path.read_text(encoding="utf-8"), version, path)
    text = replace_line_once(
        text,
        r"(?P<prefix>^(?:[ \t]*)|,[ \t]*)revision:[ \t]+(['\"])[0-9a-f]+\2",
        rf"\g<1>revision: \g<2>{sha}\g<2>",
        f"{path}: revision",
    )
    text = update_resources(path, text, fetch)
    return version, text


def update_suite(root: Path, fetch: Fetcher, core_version: str) -> tuple[str, str]:
    tag = f"v{core_version}"
    path = root / "Formula/camilladsp-suite.rb"
    revision = validate_tag(fetch, "HEnquist/camilladsp", tag)
    text = path.read_text(encoding="utf-8")
    text = replace_line_once(
        text,
        r"(?P<prefix>^(?:[ \t]*)|,[ \t]*)tag[ \t]*:[ \t]+(['\"])[^'\"]+\2",
        rf"\g<1>tag:      \g<2>{tag}\g<2>",
        f"{path}: tag",
    )
    text = replace_line_once(
        text,
        r"(?P<prefix>^(?:[ \t]*)|,[ \t]*)revision[ \t]*:[ \t]+(['\"])[0-9a-f]+\2",
        rf"\g<1>revision: \g<2>{revision}\g<2>",
        f"{path}: revision",
    )
    return core_version, text


def snapshot_tree(root: Path) -> dict[Path, tuple[bytes, int, str]]:
    snapshot: dict[Path, tuple[bytes, int, str]] = {}
    for path in root.rglob("*"):
        if path.is_file() and ".git" not in path.parts and ".omo" not in path.parts:
            data = path.read_bytes()
            snapshot[path.relative_to(root)] = (
                data,
                path.stat().st_mode,
                sha256_bytes(data),
            )
    return snapshot


def restore_tree(root: Path, snapshot: dict[Path, tuple[bytes, int, str]]) -> None:
    current = {
        path.relative_to(root)
        for path in root.rglob("*")
        if path.is_file() and ".git" not in path.parts and ".omo" not in path.parts
    }
    for relative in current - snapshot.keys():
        (root / relative).unlink()
    for relative, (data, mode, _) in snapshot.items():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.chmod(mode | stat.S_IWUSR)
        path.write_bytes(data)
        path.chmod(mode)


def write_atomic(path: Path, text: str) -> None:
    with tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=path.parent, delete=False
    ) as temp:
        temp.write(text)
        temp.flush()
        os.fsync(temp.fileno())
        temporary = Path(temp.name)
    temporary.chmod(path.stat().st_mode)
    os.replace(temporary, path)


def run(root: Path, fetch: Fetcher) -> int:
    validate_scope(root)
    planned: dict[Path, str] = {}
    core_version, planned[Path("Formula/camilladsp.rb")] = update_core(root, fetch)
    gui_version, planned[Path("Formula/camillagui.rb")] = update_gui(root, fetch)
    versions = [
        ("pycamilladsp", "pycamilladsp.rb"),
        ("pycamilladsp-plot", "pycamilladsp-plot.rb"),
        ("camilladsp-setupscripts", "camilladsp-setupscripts.rb"),
    ]
    for repo, filename in versions:
        _, planned[Path("Formula") / filename] = update_tagged_formula(
            root, fetch, f"HEnquist/{repo}", filename
        )
    _, planned[Path("Formula/camilladsp-config.rb")] = update_branch_formula(
        root, fetch, "HEnquist/camilladsp-config", "master", "camilladsp-config.rb"
    )
    _, planned[Path("Formula/camilladsp-controller.rb")] = update_branch_formula(
        root,
        fetch,
        "HEnquist/camilladsp-controller",
        "main",
        "camilladsp-controller.rb",
    )
    _, planned[Path("Formula/camilladsp-suite.rb")] = update_suite(
        root, fetch, core_version
    )

    before = snapshot_tree(root)
    if set(planned) != set(EXPECTED_FILES):
        raise RuntimeError(f"Updater planned an unexpected file set: {sorted(planned)}")
    fail_after = int(os.environ.get("UPDATE_VERSIONS_FAIL_AFTER_WRITES", "-1"))
    try:
        for index, (relative, text) in enumerate(planned.items(), start=1):
            if fail_after >= 0 and index > fail_after:
                raise RuntimeError("simulated mid-write failure")
            write_atomic(root / relative, text)
        after = snapshot_tree(root)
        changed = {path for path in after if before.get(path) != after.get(path)}
        if not changed.issubset(set(EXPECTED_FILES)):
            raise RuntimeError(
                f"Unexpected files changed: {sorted(changed - set(EXPECTED_FILES))}"
            )
        if any(
            sha256_bytes(after[path][0]) != sha256_bytes(text.encode())
            for path, text in planned.items()
        ):
            raise RuntimeError("post-write SHA-256 does not match the planned content")
    except Exception:
        restore_tree(root, before)
        raise

    print(f"Updated CamillaDSP to {core_version}")
    print(f"Updated CamillaGUI to {gui_version}")
    print("Updated Python formulas, branch formulae, and suite")
    return 0


def main(argv: list[str]) -> int:
    fixture = None
    if argv[:1] == ["--fixture"]:
        if len(argv) != 2:
            raise RuntimeError("usage: update_versions.py [--fixture FIXTURE_ROOT]")
        fixture = Path(argv[1]).resolve()
    elif argv:
        raise RuntimeError("usage: update_versions.py [--fixture FIXTURE_ROOT]")
    root = fixture or ROOT
    fetch: Fetcher = MockFetcher(root) if fixture else github_json
    return run(root, fetch)


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except Exception as exc:
        print(f"update failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
