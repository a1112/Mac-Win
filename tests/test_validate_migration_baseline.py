import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import textwrap
from types import SimpleNamespace
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
VALIDATOR_PATH = ROOT / "tools" / "validate_migration_baseline.py"
GIT_METADATA_PATH = ROOT / "tools" / "migration_git_metadata.py"
MANIFEST_PATH = ROOT / "migration" / "baseline.json"
README_PATH = ROOT / "README.md"
MIGRATION_DOCUMENT_PATH = ROOT / "docs" / "migration-baseline.md"
WORKFLOW_PATH = ROOT / ".github" / "workflows" / "migration-baseline.yml"
WORKFLOW_RELATIVE_PATH = ".github/workflows/migration-baseline.yml"

SOURCE_COMMIT = "db12d5ebc5ba0d5a29c9464d07c1a86ffbc47527"
BASELINE_TAG = "mw-migration-baseline-db12d5e"
TAG_MESSAGE = "Mac-Win migration source baseline db12d5e"
MAX_TAG_OBJECT_BYTES = 16_384
TAG_CREATION_GATE_STATEMENT = (
    "After the merge commit passes all three required jobs—the `repository-contract` "
    "job, Apple Silicon `macos-15` / `arm64`, and Intel `macos-15-intel` / "
    f"`x86_64`—create the annotated tag directly at the frozen source with `git "
    f"tag --no-sign -a {BASELINE_TAG} {SOURCE_COMMIT} -m \"{TAG_MESSAGE}\"`."
)
TAG_FAILURE_GATE_STATEMENT = (
    "If any of the three required jobs fails, is cancelled, or is unavailable, "
    "do not create or publish the baseline tag."
)
README_FREEZE_STATEMENT = (
    f"Mac-Win is frozen at {SOURCE_COMMIT} for migration evidence. "
    "New SwiftUI, Bridge, and legacy launcher product features are not accepted."
)
README_ASSET_INVENTORY_LINK_STATEMENT = (
    "See [Migration asset inventory and ownership boundary]"
    "(docs/migration-asset-inventory.md)."
)
README_CANONICAL = f"""# Mac-Win

{README_FREEZE_STATEMENT}

See [Migration baseline and evidence boundary](docs/migration-baseline.md).

{README_ASSET_INVENTORY_LINK_STATEMENT}
"""
MIGRATION_DOCUMENT_CANONICAL = f"""# Mac-Win migration baseline

## Baseline identity and freeze

Mac-Win is frozen at `{SOURCE_COMMIT}` for migration evidence.

New SwiftUI, Bridge, and legacy launcher product features are not accepted.

The immutable annotated baseline tag is `{BASELINE_TAG}`.

## Authoritative macOS evidence

Required runner and architecture: `macos-15` / `arm64`.

Required runner and architecture: `macos-15-intel` / `x86_64`.

Required host/test command: `swift --version`.

Required host/test command: `sw_vers`.

Required host/test command: `uname -m`.

Required host/test command: `sysctl -n machdep.cpu.brand_string`.

Required host/test command: `swift test --package-path MacWinManager`.

Windows output is not macOS evidence.

The authoritative macOS evidence is the GitHub Actions run URL plus the logs and job summary for both required runner and architecture jobs.

Known failures must be recorded in MW-MIG-001 with the affected runner, observed architecture, command, exit status, and CI run URL; they must not be converted into passing expectations.

Tag evidence must record both the annotated tag object ID and its peeled commit ID before MW-MIG-001 closes.

## Tag verification procedure

Before tag creation, run `python tools/validate_migration_baseline.py`; this pre-tag check intentionally does not require the tag and is not tag evidence.

{TAG_CREATION_GATE_STATEMENT}

{TAG_FAILURE_GATE_STATEMENT}

Before publication, run `python tools/validate_migration_baseline.py --require-tag`; this post-tag check requires a local annotated tag that directly references and peels to `{SOURCE_COMMIT}`.

Publish only the verified tag with `git push origin refs/tags/{BASELINE_TAG}` and record the tag object ID plus peeled commit ID as the authoritative tag evidence.

## Rollback and ownership

Before tag publication, rollback is a normal revert of the migration-baseline change; a failed or unavailable target keeps MW-MIG-001 open and prevents tag publication.

After publication, `{BASELINE_TAG}` must not be moved or deleted; corrections use a new superseding annotated tag and an explicit issue record.

MW-MIG-002 is the next owner after MW-MIG-001 completes.

Asset migration and CompatForge publication are explicitly excluded from MW-MIG-001.
"""
MIGRATION_DOCUMENT_REQUIRED_STATEMENTS = tuple(
    block.rstrip("\n")
    for block in MIGRATION_DOCUMENT_CANONICAL.split("\n\n")
    if block and not block.startswith("#")
)
CHECKOUT_ACTION = "actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683"
WORKFLOW_CANONICAL = """name: Migration baseline

on:
  pull_request:
    branches:
      - main
  push:
    branches:
      - main

permissions:
  contents: read

jobs:
  repository-contract:
    name: Repository contract
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    steps:
      - name: Check out repository
        uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683
        with:
          persist-credentials: false
          fetch-depth: 0
      - name: Validate repository contract
        shell: bash
        run: |
          set -euo pipefail
          python -B -m unittest discover -s tests -p "test_*.py" -v
          python -B tools/validate_migration_baseline.py --require-tag
          python -B tools/generate_migration_asset_inventory.py --check
          python -B tools/validate_migration_asset_inventory.py

  swift-evidence:
    name: Swift evidence (${{ matrix.runner }} / ${{ matrix.architecture }})
    strategy:
      fail-fast: false
      matrix:
        include:
          - runner: macos-15
            architecture: arm64
          - runner: macos-15-intel
            architecture: x86_64
    runs-on: ${{ matrix.runner }}
    timeout-minutes: 30
    env:
      DEVELOPER_DIR: /Applications/Xcode_16.2.app/Contents/Developer
    steps:
      - name: Check out repository
        uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683
        with:
          persist-credentials: false
          fetch-depth: 0
      - name: Record and verify host facts
        shell: bash
        env:
          EVIDENCE_RUNNER: ${{ matrix.runner }}
          EXPECTED_ARCHITECTURE: ${{ matrix.architecture }}
        run: |
          set -euo pipefail
          {
            echo "## Swift evidence: ${EVIDENCE_RUNNER} / ${EXPECTED_ARCHITECTURE}"
            echo
            echo "### swift --version"
          } | tee -a "$GITHUB_STEP_SUMMARY"
          swift --version | tee -a "$GITHUB_STEP_SUMMARY"
          echo "### sw_vers" | tee -a "$GITHUB_STEP_SUMMARY"
          sw_vers | tee -a "$GITHUB_STEP_SUMMARY"
          observed_architecture="$(uname -m)"
          {
            echo "### uname -m"
            echo "$observed_architecture"
          } | tee -a "$GITHUB_STEP_SUMMARY"
          cpu_brand="$(sysctl -n machdep.cpu.brand_string)"
          {
            echo "### sysctl -n machdep.cpu.brand_string"
            echo "$cpu_brand"
          } | tee -a "$GITHUB_STEP_SUMMARY"
          if [[ "$observed_architecture" != "$EXPECTED_ARCHITECTURE" ]]; then
            echo "Architecture mismatch: expected ${EXPECTED_ARCHITECTURE}, observed ${observed_architecture}." | tee -a "$GITHUB_STEP_SUMMARY"
            exit 1
          fi
      - name: Test Swift package
        shell: bash
        run: |
          set -uo pipefail
          summary_path="$GITHUB_STEP_SUMMARY"
          export -n summary_path
          unset GITHUB_STEP_SUMMARY
          swift_output_file="$(mktemp "${RUNNER_TEMP}/mac-win-swift-test.XXXXXX")"
          swift_summary_copy_file=""
          trap 'rm -f "$swift_output_file"; if [[ -n "$swift_summary_copy_file" ]]; then rm -f "$swift_summary_copy_file"; fi' EXIT
          swift_summary_copy_file="$(mktemp "${RUNNER_TEMP}/mac-win-swift-summary.XXXXXX")"
          {
            echo "### swift test --package-path MacWinManager"
            echo
          } >> "$summary_path"
          set +e
          swift test --package-path MacWinManager 2>&1 | tee "$swift_output_file"
          swift_pipeline_status=("${PIPESTATUS[@]}")
          swift_status=${swift_pipeline_status[0]}
          swift_tee_status=${swift_pipeline_status[1]}
          set -e
          swift_output_bytes="$(wc -c < "$swift_output_file" | tr -d '[:space:]')"
          swift_summary_raw_limit_bytes=262144
          swift_summary_copy_limit_bytes=524288
          swift_summary_copy_bytes=0
          swift_summary_copy_status="omitted; raw output limit exceeded; not truncated"
          swift_summary_limit_exceeded=0
          swift_capture_failed=0
          swift_format_failed=0
          swift_base64_status=-1
          swift_indent_status=-1
          if (( swift_tee_status != 0 )); then
            swift_summary_copy_status="omitted; complete log capture failed; not truncated"
            swift_capture_failed=1
          fi
          if (( swift_capture_failed != 0 )); then
            :
          elif (( swift_output_bytes > swift_summary_raw_limit_bytes )); then
            swift_summary_limit_exceeded=1
          else
            set +e
            base64 < "$swift_output_file" | sed 's/^/    /' > "$swift_summary_copy_file"
            swift_format_pipeline_status=("${PIPESTATUS[@]}")
            set -e
            swift_base64_status=${swift_format_pipeline_status[0]}
            swift_indent_status=${swift_format_pipeline_status[1]}
            if (( swift_base64_status != 0 || swift_indent_status != 0 )); then
              swift_summary_copy_status="omitted; Markdown-safe formatting failed; not truncated"
              swift_format_failed=1
            else
              swift_summary_copy_bytes="$(wc -c < "$swift_summary_copy_file" | tr -d '[:space:]')"
            fi
            if (( swift_format_failed == 0 && swift_summary_copy_bytes > swift_summary_copy_limit_bytes )); then
              swift_summary_copy_status="omitted; Markdown-safe copy limit exceeded; not truncated"
              swift_summary_limit_exceeded=1
            elif (( swift_format_failed == 0 )); then
              swift_summary_copy_status="complete; Markdown-safe base64 indented code; not truncated"
            fi
          fi
          {
            echo "- Swift test exit status: ${swift_status}"
            echo "- Swift test log capture exit status: ${swift_tee_status}"
            echo "- Swift test base64 formatter exit status: ${swift_base64_status}"
            echo "- Swift test indent formatter exit status: ${swift_indent_status}"
            echo "- Swift test raw output bytes: ${swift_output_bytes}"
            echo "- Swift test raw output limit bytes: ${swift_summary_raw_limit_bytes}"
            echo "- Swift test Markdown-safe copy bytes: ${swift_summary_copy_bytes}"
            echo "- Swift test Markdown-safe copy limit bytes: ${swift_summary_copy_limit_bytes}"
            echo "- Swift test summary copy status: ${swift_summary_copy_status}"
            echo
          } >> "$summary_path"
          if (( swift_summary_limit_exceeded != 0 )); then
            exit 1
          fi
          if (( swift_capture_failed != 0 )); then
            exit 1
          fi
          if (( swift_format_failed != 0 )); then
            exit 1
          fi
          cat "$swift_summary_copy_file" >> "$summary_path"
          echo >> "$summary_path"
          exit "$swift_status"
"""
WORKFLOW_SHA256 = hashlib.sha256(WORKFLOW_CANONICAL.encode("utf-8")).hexdigest()

GIT_SIGNING_POLLUTION = {
    "GIT_CONFIG_COUNT": "3",
    "GIT_CONFIG_KEY_0": "commit.gpgSign",
    "GIT_CONFIG_VALUE_0": "true",
    "GIT_CONFIG_KEY_1": "tag.gpgSign",
    "GIT_CONFIG_VALUE_1": "true",
    "GIT_CONFIG_KEY_2": "gpg.program",
    "GIT_CONFIG_VALUE_2": "codex-no-such-gpg-program",
}

GIT_HOSTILE_REPOSITORY_POLLUTION = {
    "git_dir": "decoy-git-dir",
    "Git_Work_Tree": "decoy-worktree",
    "GIT_COMMON_DIR": "decoy-common-dir",
    "git_index_file": "decoy-index",
    "GIT_OBJECT_DIRECTORY": "decoy-objects",
    "git_alternate_object_directories": "decoy-alternates",
    "GIT_NAMESPACE": "decoy-namespace",
    "Git_Config_Count": "2",
    "GIT_CONFIG_KEY_0": "core.hooksPath",
    "git_config_value_0": "decoy-hooks",
    "git_config_key_1": "core.attributesFile",
    "GIT_CONFIG_VALUE_1": "decoy-attributes",
    "Git_Config_Global": "decoy-global-config",
    "GIT_CONFIG_SYSTEM": "decoy-system-config",
    "git_config_parameters": "'core.fsmonitor'='decoy-monitor'",
}

CANONICAL = {
    "schemaVersion": 1,
    "repository": "a1112/Mac-Win",
    "sourceCommit": "db12d5ebc5ba0d5a29c9464d07c1a86ffbc47527",
    "tag": "mw-migration-baseline-db12d5e",
    "swiftPackagePath": "MacWinManager",
    "evidenceTargets": [
        {"runner": "macos-15", "architecture": "arm64"},
        {"runner": "macos-15-intel", "architecture": "x86_64"},
    ],
    "frozenFeatureAreas": ["SwiftUI", "Bridge", "legacy-launcher"],
}
HOSTILE_JSON_INPUTS = (
    ("deep nesting", ("[" * 3000 + "0" + "]" * 3000).encode("ascii")),
    ("oversized integer", ("9" * 5000).encode("ascii")),
)
HOSTILE_KEYS = (
    "line\nbreak",
    "escape\x1b[31m",
    "lone-surrogate-\ud800",
    "k" * 10_000,
)
GIT_CHECK_ATTR_BLOCKED_VARIABLES = frozenset(
    {
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_COMMON_DIR",
        "GIT_INDEX_FILE",
        "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_NAMESPACE",
        "GIT_TEMPLATE_DIR",
        "GIT_CONFIG_COUNT",
        "GIT_CONFIG_GLOBAL",
        "GIT_CONFIG_SYSTEM",
        "GIT_CONFIG_NOSYSTEM",
        "GIT_CONFIG_PARAMETERS",
    }
)
GITATTRIBUTES_CANONICAL = b"""/patches/*.patch whitespace=-blank-at-eol
migration/*.json text eol=lf
migration/**/*.json text eol=lf
/docs/migration-asset-inventory.md text eol=lf
"""


def assert_canonical_json_presentation(test_case, raw, expected):
    content_without_crlf = raw.replace(b"\r\n", b"")
    test_case.assertNotIn(
        b"\r",
        content_without_crlf,
        "canonical JSON contains a lone CR or CRCRLF",
    )
    if b"\r\n" in raw:
        test_case.assertNotIn(
            b"\n",
            content_without_crlf,
            "canonical JSON mixes LF and CRLF line endings",
        )
    test_case.assertEqual(raw.replace(b"\r\n", b"\n"), expected)


def sanitized_git_test_environment():
    environment = os.environ.copy()
    for key in tuple(environment):
        upper_key = key.upper()
        if upper_key in GIT_CHECK_ATTR_BLOCKED_VARIABLES or re.fullmatch(
            r"GIT_CONFIG_(?:KEY|VALUE)_\d+", upper_key
        ):
            del environment[key]
    environment.update(
        {
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_NO_LAZY_FETCH": "1",
            "GIT_NO_REPLACE_OBJECTS": "1",
            "GIT_TERMINAL_PROMPT": "0",
        }
    )
    return environment


def run_sanitized_git(root, *arguments, text=True):
    resolved_root = Path(root).resolve(strict=True)
    return subprocess.run(
        [
            "git",
            "-c",
            f"safe.directory={resolved_root}",
            *arguments,
        ],
        cwd=resolved_root,
        env=sanitized_git_test_environment(),
        capture_output=True,
        text=text,
        shell=False,
        check=False,
    )


def fixture_git_environment(source=None):
    """Preserve process facilities without inheriting ambient Git policy."""
    environment = dict(os.environ if source is None else source)
    for key in tuple(environment):
        if key.upper().startswith("GIT_"):
            del environment[key]
    environment.update(
        {
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0",
        }
    )
    return environment


def clone_git_test_environment(source=None, *, assume_different_owner=False):
    """Isolate clone fixtures while optionally retaining the ownership probe."""
    environment = fixture_git_environment(source)
    environment.update(
        {
            "GIT_NO_LAZY_FETCH": "1",
            "GIT_NO_REPLACE_OBJECTS": "1",
        }
    )
    if assume_different_owner:
        environment["GIT_TEST_ASSUME_DIFFERENT_OWNER"] = "1"
    return environment


def run_fixture_git(
    root,
    *arguments,
    configuration=(),
    environment=None,
    input_bytes=None,
):
    """Run one fixture Git command without ambient repositories, hooks, or signing."""
    repository = Path(root)
    repository.mkdir(parents=True, exist_ok=True)
    resolved_root = repository.resolve(strict=True)
    command = [
        "git",
        "-c",
        f"safe.directory={resolved_root}",
        "-c",
        f"core.hooksPath={os.devnull}",
        *configuration,
        *arguments,
    ]
    return subprocess.run(
        command,
        cwd=resolved_root,
        env=fixture_git_environment(environment),
        input=input_bytes,
        capture_output=True,
        text=input_bytes is None,
        shell=False,
        check=False,
    )


def run_git_check_attr(relative_path, root=ROOT):
    return run_sanitized_git(
        root,
        "check-attr",
        "eol",
        "--",
        relative_path,
    )


def assert_migration_attribute_contract(test_case, root):
    committed = run_sanitized_git(
        root,
        "cat-file",
        "blob",
        "HEAD:.gitattributes",
        text=False,
    )
    test_case.assertEqual(committed.returncode, 0, committed.stderr)
    test_case.assertEqual(committed.stdout, GITATTRIBUTES_CANONICAL)

    with tempfile.TemporaryDirectory() as temporary_directory:
        isolated = Path(temporary_directory).resolve()
        initialized = run_sanitized_git(isolated, "init", "-q")
        test_case.assertEqual(initialized.returncode, 0, initialized.stderr)
        (isolated / ".gitattributes").write_bytes(committed.stdout)

        for relative_path in (
            "migration/baseline.json",
            "migration/assets/recipes.json",
            "docs/migration-asset-inventory.md",
        ):
            with test_case.subTest(relative_path=relative_path):
                result = run_git_check_attr(relative_path, root=isolated)
                test_case.assertEqual(result.returncode, 0, result.stderr)
                test_case.assertEqual(
                    result.stdout.strip(),
                    f"{relative_path}: eol: lf",
                )


def load_validator():
    if not VALIDATOR_PATH.is_file():
        raise AssertionError(f"validator is missing: {VALIDATOR_PATH}")

    spec = importlib.util.spec_from_file_location(
        "validate_migration_baseline", VALIDATOR_PATH
    )
    if spec is None or spec.loader is None:
        raise AssertionError("validator module could not be loaded")

    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def overwrite_hardlink_preserving_bound_identity(test_case, bound, sibling, raw):
    """Overwrite one hardlink while preserving every currently bound stat field."""
    before = bound.lstat()
    test_case.assertEqual(len(raw), before.st_size)
    with sibling.open("r+b") as stream:
        stream.write(raw)
        stream.truncate()
    os.utime(
        sibling,
        ns=(before.st_atime_ns, before.st_mtime_ns),
    )
    after = bound.lstat()
    test_case.assertEqual(
        (
            before.st_dev,
            before.st_ino,
            stat.S_IFMT(before.st_mode),
            before.st_size,
            before.st_mtime_ns,
        ),
        (
            after.st_dev,
            after.st_ino,
            stat.S_IFMT(after.st_mode),
            after.st_size,
            after.st_mtime_ns,
        ),
    )


class MigrationBaselineManifestTests(unittest.TestCase):
    def assertInvalid(self, manifest, diagnostic):
        validator = load_validator()
        with self.assertRaises(validator.BaselineValidationError) as caught:
            validator.validate_manifest(manifest)
        self.assertEqual(str(caught.exception), diagnostic)

    def assertRawInvalid(self, raw, diagnostic):
        validator = load_validator()
        with self.assertRaises(validator.BaselineValidationError) as caught:
            validator.parse_manifest_bytes(raw)
        self.assertEqual(str(caught.exception), diagnostic)

    def runIsolatedValidator(self, raw):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tools = root / "tools"
            migration = root / "migration"
            tools.mkdir()
            migration.mkdir()
            validator_path = tools / VALIDATOR_PATH.name
            shutil.copyfile(VALIDATOR_PATH, validator_path)
            shutil.copyfile(GIT_METADATA_PATH, tools / GIT_METADATA_PATH.name)
            (migration / "baseline.json").write_bytes(raw)

            environment = os.environ.copy()
            bytecode_variables = {"PYTHONDONTWRITEBYTECODE", "PYTHONPYCACHEPREFIX"}
            for key in tuple(environment):
                if key.upper() in bytecode_variables:
                    del environment[key]
            result = subprocess.run(
                [sys.executable, str(validator_path)],
                cwd=root,
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(list(root.rglob("__pycache__")), [])
            self.assertEqual(list(root.rglob("*.pyc")), [])
            return result

    def assertEntrypointInvalid(self, raw, diagnostic):
        result = self.runIsolatedValidator(raw)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertEqual(
            result.stderr,
            f"migration baseline validation failed: {diagnostic}\n",
        )
        self.assertNotIn("Traceback", result.stderr)

    def assertGitAttribute(self, result, relative_path, value):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.strip(),
            f"{relative_path}: eol: {value}",
        )

    def runGitFixture(self, root, *arguments):
        result = run_sanitized_git(root, *arguments)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def test_validator_module_exists(self):
        self.assertTrue(VALIDATOR_PATH.is_file(), "validator module is missing")

    def test_accepts_exact_canonical_manifest_object(self):
        validator = load_validator()
        validator.validate_manifest(copy.deepcopy(CANONICAL))

    def test_manifest_file_is_exact_canonical_serialization(self):
        self.assertTrue(MANIFEST_PATH.is_file(), "canonical manifest is missing")
        expected = (json.dumps(CANONICAL, indent=2) + "\n").encode("utf-8")
        raw = MANIFEST_PATH.read_bytes()
        assert_canonical_json_presentation(self, raw, expected)

        validator = load_validator()
        self.assertEqual(validator.load_manifest(MANIFEST_PATH), CANONICAL)

    def test_canonical_serialization_accepts_only_uniform_lf_or_crlf(self):
        expected = (json.dumps(CANONICAL, indent=2) + "\n").encode("utf-8")
        for raw in (expected, expected.replace(b"\n", b"\r\n")):
            with self.subTest(raw=raw):
                assert_canonical_json_presentation(self, raw, expected)

    def test_canonical_serialization_rejects_invalid_newline_presentations(self):
        expected = (json.dumps(CANONICAL, indent=2) + "\n").encode("utf-8")
        first_newline_end = expected.index(b"\n") + 1
        mutants = {
            "first newline CRLF, remainder LF": expected.replace(
                b"\n", b"\r\n", 1
            ),
            "first newline LF, remainder CRLF": (
                expected[:first_newline_end]
                + expected[first_newline_end:].replace(b"\n", b"\r\n")
            ),
            "lone CR": expected.replace(b"\n", b"\r", 1),
            "CRCRLF": expected.replace(b"\n", b"\r\r\n", 1),
        }
        for name, raw in mutants.items():
            with self.subTest(name=name):
                with self.assertRaises(AssertionError):
                    assert_canonical_json_presentation(self, raw, expected)

    def test_migration_json_attributes_have_lf_semantics(self):
        assert_migration_attribute_contract(self, ROOT)

    def test_migration_attribute_contract_ignores_info_override(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            repository = Path(temporary_directory).resolve()
            self.runGitFixture(repository, "init", "-q")
            (repository / ".gitattributes").write_bytes(GITATTRIBUTES_CANONICAL)
            self.runGitFixture(repository, "add", ".gitattributes")
            self.runGitFixture(
                repository,
                "-c",
                "user.name=Mac-Win Attribute Tests",
                "-c",
                "user.email=attribute-tests@example.invalid",
                "-c",
                "commit.gpgSign=false",
                "commit",
                "-q",
                "-m",
                "fixture",
            )
            (repository / ".git" / "info" / "attributes").write_text(
                "migration/*.json eol=crlf\n"
                "migration/**/*.json eol=crlf\n",
                encoding="utf-8",
                newline="\n",
            )

            overridden = run_git_check_attr(
                "migration/baseline.json",
                root=repository,
            )
            self.assertGitAttribute(
                overridden,
                "migration/baseline.json",
                "crlf",
            )
            assert_migration_attribute_contract(self, repository)

    def test_git_check_attr_ignores_ambient_repository_redirection(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            decoy = Path(temporary_directory).resolve()
            init = run_sanitized_git(decoy, "init", "-q")
            self.assertEqual(init.returncode, 0, init.stderr)
            (decoy / ".gitattributes").write_text(
                "migration/*.json text eol=crlf\n",
                encoding="utf-8",
                newline="\n",
            )
            pollution = {
                "GIT_DIR": str(decoy / ".git"),
                "GIT_WORK_TREE": str(decoy),
            }
            with mock.patch.dict(os.environ, pollution, clear=False):
                result = run_git_check_attr("migration/baseline.json")

        self.assertGitAttribute(result, "migration/baseline.json", "lf")

    def test_git_check_attr_handles_dubious_ownership_locally(self):
        with mock.patch.dict(
            os.environ,
            {"GIT_TEST_ASSUME_DIFFERENT_OWNER": "1"},
            clear=False,
        ):
            result = run_git_check_attr("migration/baseline.json")

        self.assertGitAttribute(result, "migration/baseline.json", "lf")

    def test_git_check_attr_ignores_hostile_home_attributes_config(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            hostile_home = Path(temporary_directory).resolve()
            attributes_file = hostile_home / "hostile-attributes"
            attributes_file.write_text(
                "README.md eol=crlf\n",
                encoding="utf-8",
                newline="\n",
            )
            (hostile_home / ".gitconfig").write_text(
                "[core]\n"
                f"    attributesFile = {attributes_file.as_posix()}\n",
                encoding="utf-8",
                newline="\n",
            )
            with mock.patch.dict(
                os.environ,
                {
                    "HOME": str(hostile_home),
                    "USERPROFILE": str(hostile_home),
                },
                clear=False,
            ):
                result = run_git_check_attr("README.md")

        self.assertGitAttribute(result, "README.md", "unspecified")

    def test_git_check_attr_disables_global_and_system_config(self):
        completed = SimpleNamespace(returncode=0, stdout="", stderr="")
        with mock.patch.object(
            subprocess,
            "run",
            return_value=completed,
        ) as run:
            run_git_check_attr("migration/baseline.json")

        environment = run.call_args.kwargs["env"]
        self.assertEqual(environment.get("GIT_CONFIG_GLOBAL"), os.devnull)
        self.assertEqual(environment.get("GIT_CONFIG_NOSYSTEM"), "1")

    def test_git_check_attr_uses_exact_sanitized_process_contract(self):
        pollution = {
            key: f"redirected-{key.lower()}"
            for key in GIT_CHECK_ATTR_BLOCKED_VARIABLES
        }
        pollution.update(
            {
                "PATH": os.environ.get("PATH", os.defpath),
                "HOME": "preserved-home",
                "GIT_CONFIG_COUNT": "2",
                "GIT_CONFIG_KEY_0": "core.attributesFile",
                "GIT_CONFIG_VALUE_0": "redirected-attributes",
                "GIT_CONFIG_KEY_1": "safe.directory",
                "GIT_CONFIG_VALUE_1": "*",
            }
        )
        completed = SimpleNamespace(returncode=0, stdout="", stderr="")
        with mock.patch.dict(os.environ, pollution, clear=True):
            with mock.patch.object(
                subprocess,
                "run",
                return_value=completed,
            ) as run:
                self.assertIs(
                    run_git_check_attr("migration/baseline.json"),
                    completed,
                )

        run.assert_called_once()
        command = run.call_args.args[0]
        options = run.call_args.kwargs
        self.assertEqual(
            command,
            [
                "git",
                "-c",
                f"safe.directory={ROOT}",
                "check-attr",
                "eol",
                "--",
                "migration/baseline.json",
            ],
        )
        self.assertEqual(options["cwd"], ROOT)
        self.assertFalse(options["shell"])
        environment = options["env"]
        self.assertEqual(environment["PATH"], pollution["PATH"])
        self.assertEqual(environment["HOME"], pollution["HOME"])
        preserved_or_forced = {
            "PATH",
            "HOME",
            "GIT_CONFIG_GLOBAL",
            "GIT_CONFIG_NOSYSTEM",
        }
        for key in pollution:
            if key not in preserved_or_forced:
                self.assertNotIn(key, environment)
        self.assertEqual(environment["GIT_CONFIG_GLOBAL"], os.devnull)
        self.assertEqual(environment["GIT_CONFIG_NOSYSTEM"], "1")
        self.assertEqual(environment["GIT_NO_LAZY_FETCH"], "1")
        self.assertEqual(environment["GIT_NO_REPLACE_OBJECTS"], "1")
        self.assertEqual(environment["GIT_TERMINAL_PROMPT"], "0")

    def test_rejects_non_object_top_level_value(self):
        self.assertInvalid([], "manifest must be a JSON object")

    def test_rejects_unknown_top_level_field(self):
        mutated = copy.deepcopy(CANONICAL)
        mutated["unexpected"] = True
        self.assertInvalid(mutated, "manifest has unknown field")

    def test_rejects_each_missing_top_level_field(self):
        for field in CANONICAL:
            with self.subTest(field=field):
                mutated = copy.deepcopy(CANONICAL)
                del mutated[field]
                self.assertInvalid(mutated, f"manifest is missing field: {field}")

    def test_rejects_bool_float_and_string_schema_versions(self):
        for value in (True, 1.0, "1"):
            with self.subTest(value=value):
                mutated = copy.deepcopy(CANONICAL)
                mutated["schemaVersion"] = value
                self.assertInvalid(mutated, "schemaVersion must be integer 1")

    def test_rejects_wrong_repository(self):
        mutated = copy.deepcopy(CANONICAL)
        mutated["repository"] = "a1112/Other"
        self.assertInvalid(mutated, "repository must equal a1112/Mac-Win")

    def test_rejects_malformed_source_commits(self):
        malformed = {
            "short": "db12d5e",
            "uppercase": "4E421FBEA6F59E73E4F813C1F0A14E8DB9E36DE7",
            "nonhex": "ge421fbea6f59e73e4f813c1f0a14e8db9e36de7",
        }
        for name, value in malformed.items():
            with self.subTest(name=name):
                mutated = copy.deepcopy(CANONICAL)
                mutated["sourceCommit"] = value
                self.assertInvalid(
                    mutated,
                    "sourceCommit must be a 40-character lowercase hexadecimal commit",
                )

    def test_rejects_well_formed_but_wrong_source_commit(self):
        mutated = copy.deepcopy(CANONICAL)
        mutated["sourceCommit"] = "0" * 40
        self.assertInvalid(
            mutated,
            "sourceCommit must equal db12d5ebc5ba0d5a29c9464d07c1a86ffbc47527",
        )

    def test_rejects_wrong_tag(self):
        mutated = copy.deepcopy(CANONICAL)
        mutated["tag"] = "mw-migration-baseline-other"
        self.assertInvalid(
            mutated, "tag must equal mw-migration-baseline-db12d5e"
        )

    def test_rejects_unsafe_and_wrong_package_paths(self):
        paths = (
            "OtherPackage",
            "../MacWinManager",
            "/MacWinManager",
            "MacWinManager/../Other",
            r"MacWinManager\Other",
        )
        for path in paths:
            with self.subTest(path=path):
                mutated = copy.deepcopy(CANONICAL)
                mutated["swiftPackagePath"] = path
                self.assertInvalid(
                    mutated, "swiftPackagePath must equal MacWinManager"
                )

    def test_rejects_missing_evidence_target(self):
        mutated = copy.deepcopy(CANONICAL)
        mutated["evidenceTargets"] = mutated["evidenceTargets"][:1]
        self.assertInvalid(
            mutated,
            "evidenceTargets must exactly equal the reviewed runner sequence",
        )

    def test_rejects_duplicate_evidence_target(self):
        mutated = copy.deepcopy(CANONICAL)
        mutated["evidenceTargets"] = [
            copy.deepcopy(mutated["evidenceTargets"][0]),
            copy.deepcopy(mutated["evidenceTargets"][0]),
        ]
        self.assertInvalid(
            mutated,
            "evidenceTargets must exactly equal the reviewed runner sequence",
        )

    def test_rejects_reordered_evidence_targets(self):
        mutated = copy.deepcopy(CANONICAL)
        mutated["evidenceTargets"].reverse()
        self.assertInvalid(
            mutated,
            "evidenceTargets must exactly equal the reviewed runner sequence",
        )

    def test_rejects_unexpected_evidence_target(self):
        mutated = copy.deepcopy(CANONICAL)
        mutated["evidenceTargets"][1] = {
            "runner": "macos-14",
            "architecture": "x86_64",
        }
        self.assertInvalid(
            mutated,
            "evidenceTargets must exactly equal the reviewed runner sequence",
        )

    def test_rejects_missing_frozen_feature_area(self):
        mutated = copy.deepcopy(CANONICAL)
        mutated["frozenFeatureAreas"] = mutated["frozenFeatureAreas"][:2]
        self.assertInvalid(
            mutated,
            "frozenFeatureAreas must exactly equal the reviewed freeze sequence",
        )

    def test_rejects_duplicate_frozen_feature_area(self):
        mutated = copy.deepcopy(CANONICAL)
        mutated["frozenFeatureAreas"] = ["SwiftUI", "Bridge", "Bridge"]
        self.assertInvalid(
            mutated,
            "frozenFeatureAreas must exactly equal the reviewed freeze sequence",
        )

    def test_rejects_reordered_frozen_feature_areas(self):
        mutated = copy.deepcopy(CANONICAL)
        mutated["frozenFeatureAreas"] = [
            "Bridge",
            "SwiftUI",
            "legacy-launcher",
        ]
        self.assertInvalid(
            mutated,
            "frozenFeatureAreas must exactly equal the reviewed freeze sequence",
        )

    def test_rejects_unexpected_frozen_feature_area(self):
        mutated = copy.deepcopy(CANONICAL)
        mutated["frozenFeatureAreas"][2] = "launcher"
        self.assertInvalid(
            mutated,
            "frozenFeatureAreas must exactly equal the reviewed freeze sequence",
        )

    def test_rejects_duplicate_raw_json_keys(self):
        self.assertRawInvalid(
            b'{"schemaVersion":1,"schemaVersion":1}',
            "manifest has duplicate JSON key",
        )

    def test_rejects_unicode_escaped_duplicate_json_keys(self):
        self.assertRawInvalid(
            b'{"repository":"a1112/Mac-Win","repos\\u0069tory":"other"}',
            "manifest has duplicate JSON key",
        )

    def test_rejects_duplicate_nested_json_keys(self):
        self.assertRawInvalid(
            b'{"evidenceTargets":[{"runner":"macos-15","runn\\u0065r":"other"}]}',
            "manifest has duplicate JSON key",
        )

    def test_rejects_json_nesting_above_128_before_decoder_recursion(self):
        validator = load_validator()
        nested_inputs = (
            b"[" * 129 + b"0" + b"]" * 129,
            b'{"value":' * 129 + b"0" + b"}" * 129,
        )
        original_recursion_limit = sys.getrecursionlimit()
        try:
            sys.setrecursionlimit(max(original_recursion_limit, 10_000))
            for raw in nested_inputs:
                with self.subTest(opening=raw[:1]):
                    with mock.patch.object(
                        validator.json,
                        "loads",
                        wraps=validator.json.loads,
                    ) as decoder:
                        with self.assertRaises(
                            validator.BaselineValidationError
                        ) as caught:
                            validator.parse_manifest_bytes(raw)
                    self.assertEqual(
                        str(caught.exception),
                        "manifest is not valid JSON",
                    )
                    decoder.assert_not_called()
        finally:
            sys.setrecursionlimit(original_recursion_limit)

    def test_accepts_exact_json_nesting_limit_and_ignores_string_delimiters(self):
        validator = load_validator()
        self.assertEqual(validator.MAX_JSON_NESTING_DEPTH, 128)
        exact_inputs = (
            b"[" * 128 + b"0" + b"]" * 128,
            b'{"value":' * 128 + b"0" + b"}" * 128,
        )
        for raw in exact_inputs:
            with self.subTest(opening=raw[:1]):
                validator.parse_manifest_bytes(raw)

        string_value = ('[{]} escaped quote: " and slash: \\' * 256)
        raw = json.dumps({"value": string_value}).encode("utf-8")
        self.assertGreater(raw.count(b"{"), 128)
        self.assertIn(b'\\"', raw)
        self.assertEqual(
            validator.parse_manifest_bytes(raw),
            {"value": string_value},
        )

    def test_direct_hostile_json_failures_have_one_stable_error(self):
        validator = load_validator()
        for name, raw in HOSTILE_JSON_INPUTS:
            with self.subTest(name=name):
                self.assertLessEqual(len(raw), validator.MAX_MANIFEST_BYTES)
                self.assertRawInvalid(raw, "manifest is not valid JSON")

    def test_entrypoint_hostile_json_failures_have_one_stable_error(self):
        validator = load_validator()
        for name, raw in HOSTILE_JSON_INPUTS:
            with self.subTest(name=name):
                self.assertLessEqual(len(raw), validator.MAX_MANIFEST_BYTES)
                self.assertEntrypointInvalid(
                    raw,
                    "reviewed working-tree content does not match approved content",
                )

    def test_direct_duplicate_key_diagnostics_never_echo_hostile_keys(self):
        validator = load_validator()
        for key in HOSTILE_KEYS:
            with self.subTest(key=repr(key[:40])):
                encoded_key = json.dumps(key, ensure_ascii=True)
                raw = f"{{{encoded_key}:1,{encoded_key}:2}}".encode("ascii")
                self.assertLessEqual(len(raw), validator.MAX_MANIFEST_BYTES)
                self.assertRawInvalid(raw, "manifest has duplicate JSON key")

    def test_entrypoint_duplicate_key_diagnostics_never_echo_hostile_keys(self):
        validator = load_validator()
        for key in HOSTILE_KEYS:
            with self.subTest(key=repr(key[:40])):
                encoded_key = json.dumps(key, ensure_ascii=True)
                raw = f"{{{encoded_key}:1,{encoded_key}:2}}".encode("ascii")
                self.assertLessEqual(len(raw), validator.MAX_MANIFEST_BYTES)
                self.assertEntrypointInvalid(
                    raw,
                    "reviewed working-tree content does not match approved content",
                )

    def test_direct_unknown_key_diagnostics_never_echo_hostile_keys(self):
        validator = load_validator()
        for key in HOSTILE_KEYS:
            with self.subTest(key=repr(key[:40])):
                mutated = copy.deepcopy(CANONICAL)
                mutated[key] = True
                raw = json.dumps(
                    mutated, ensure_ascii=True, separators=(",", ":")
                ).encode("ascii")
                self.assertLessEqual(len(raw), validator.MAX_MANIFEST_BYTES)
                self.assertInvalid(mutated, "manifest has unknown field")

    def test_entrypoint_unknown_key_diagnostics_never_echo_hostile_keys(self):
        validator = load_validator()
        for key in HOSTILE_KEYS:
            with self.subTest(key=repr(key[:40])):
                mutated = copy.deepcopy(CANONICAL)
                mutated[key] = True
                raw = json.dumps(
                    mutated, ensure_ascii=True, separators=(",", ":")
                ).encode("ascii")
                self.assertLessEqual(len(raw), validator.MAX_MANIFEST_BYTES)
                self.assertEntrypointInvalid(
                    raw,
                    "reviewed working-tree content does not match approved content",
                )

    def test_accepts_exactly_65536_bytes(self):
        validator = load_validator()
        raw = json.dumps(CANONICAL, separators=(",", ":")).encode("utf-8")
        raw += b" " * (validator.MAX_MANIFEST_BYTES - len(raw))
        self.assertEqual(len(raw), 65_536)

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "baseline.json"
            path.write_bytes(raw)
            self.assertEqual(validator.load_manifest(path), CANONICAL)

    def test_rejects_65537_bytes_before_json_allocation(self):
        validator = load_validator()
        raw = json.dumps(CANONICAL, separators=(",", ":")).encode("utf-8")
        raw += b" " * (validator.MAX_MANIFEST_BYTES + 1 - len(raw))
        self.assertEqual(len(raw), 65_537)

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "baseline.json"
            path.write_bytes(raw)
            with self.assertRaisesRegex(
                validator.BaselineValidationError,
                "^manifest exceeds 65536-byte limit$",
            ):
                validator.load_manifest(path)

    def test_rejects_invalid_utf8(self):
        self.assertRawInvalid(b"{\"schemaVersion\":\xff}", "manifest is not valid UTF-8")

    def test_rejects_invalid_json(self):
        self.assertRawInvalid(b"{", "manifest is not valid JSON")


class MigrationBaselineDocumentTests(unittest.TestCase):
    def assertReadmeInvalid(self, text, diagnostic):
        validator = load_validator()
        with self.assertRaises(validator.BaselineValidationError) as caught:
            validator.validate_readme_document(text)
        self.assertEqual(str(caught.exception), diagnostic)

    def assertMigrationDocumentInvalid(self, text, diagnostic):
        validator = load_validator()
        with self.assertRaises(validator.BaselineValidationError) as caught:
            validator.validate_migration_document(text)
        self.assertEqual(str(caught.exception), diagnostic)

    def test_reviewed_documents_are_exact_and_semantically_valid(self):
        self.assertTrue(README_PATH.is_file(), "README is missing")
        self.assertTrue(
            MIGRATION_DOCUMENT_PATH.is_file(), "migration document is missing"
        )
        self.assertEqual(README_PATH.read_text(encoding="utf-8"), README_CANONICAL)
        self.assertEqual(
            MIGRATION_DOCUMENT_PATH.read_text(encoding="utf-8"),
            MIGRATION_DOCUMENT_CANONICAL,
        )

        validator = load_validator()
        self.assertEqual(
            validator.MIGRATION_DOCUMENT_REQUIRED_STATEMENTS,
            MIGRATION_DOCUMENT_REQUIRED_STATEMENTS,
        )
        validator.validate_readme_document(README_CANONICAL)
        validator.validate_migration_document(MIGRATION_DOCUMENT_CANONICAL)

    def test_readme_requires_full_sha_and_unweakened_freeze_statement(self):
        diagnostic = "README is missing the standalone migration freeze statement"
        mutations = (
            README_CANONICAL.replace(SOURCE_COMMIT, SOURCE_COMMIT[:7]),
            README_CANONICAL.replace("is frozen", "is planned to be frozen"),
            README_CANONICAL.replace("are not accepted", "may be accepted"),
        )
        for text in mutations:
            with self.subTest(text=text):
                self.assertReadmeInvalid(text, diagnostic)

    def test_readme_rejects_comment_and_negation_wrappers(self):
        diagnostic = "README is missing the standalone migration freeze statement"
        commented = README_CANONICAL.replace(
            README_FREEZE_STATEMENT,
            f"<!-- {README_FREEZE_STATEMENT} -->",
        )
        negated = README_CANONICAL.replace(
            README_FREEZE_STATEMENT,
            f"It is not true that {README_FREEZE_STATEMENT}",
        )
        fenced = README_CANONICAL.replace(
            README_FREEZE_STATEMENT,
            f"```text\n\n{README_FREEZE_STATEMENT}\n\n```",
        )
        for text in (commented, negated, fenced):
            with self.subTest(text=text):
                self.assertReadmeInvalid(text, diagnostic)

    def test_readme_requires_visible_migration_document_link(self):
        diagnostic = "README is missing the standalone migration document link"
        missing = README_CANONICAL.replace(
            "See [Migration baseline and evidence boundary](docs/migration-baseline.md).",
            "See the migration baseline documentation.",
        )
        commented = README_CANONICAL.replace(
            "See [Migration baseline and evidence boundary](docs/migration-baseline.md).",
            "<!-- See [Migration baseline and evidence boundary](docs/migration-baseline.md). -->",
        )
        for text in (missing, commented):
            with self.subTest(text=text):
                self.assertReadmeInvalid(text, diagnostic)

    def test_readme_requires_visible_asset_inventory_document_link(self):
        diagnostic = "README is missing the standalone asset inventory document link"
        missing = README_CANONICAL.replace(
            README_ASSET_INVENTORY_LINK_STATEMENT,
            "See the migration asset inventory documentation.",
        )
        commented = README_CANONICAL.replace(
            README_ASSET_INVENTORY_LINK_STATEMENT,
            f"<!-- {README_ASSET_INVENTORY_LINK_STATEMENT} -->",
        )
        for text in (missing, commented):
            with self.subTest(text=text):
                self.assertReadmeInvalid(text, diagnostic)

    def test_document_requires_full_sha_both_architectures_and_known_failures(self):
        diagnostic = (
            "migration document is missing a required standalone evidence statement"
        )
        mutations = (
            MIGRATION_DOCUMENT_CANONICAL.replace(SOURCE_COMMIT, SOURCE_COMMIT[:7]),
            MIGRATION_DOCUMENT_CANONICAL.replace(
                "Required runner and architecture: `macos-15-intel` / `x86_64`.\n\n",
                "",
            ),
            MIGRATION_DOCUMENT_CANONICAL.replace("`arm64`", "`aarch64`"),
            MIGRATION_DOCUMENT_CANONICAL.replace(
                "Known failures must be recorded in MW-MIG-001 with the affected runner, observed architecture, command, exit status, and CI run URL; they must not be converted into passing expectations.\n\n",
                "",
            ),
        )
        for text in mutations:
            with self.subTest(text=text):
                self.assertMigrationDocumentInvalid(text, diagnostic)

    def test_document_rejects_comment_and_negation_wrappers(self):
        diagnostic = (
            "migration document is missing a required standalone evidence statement"
        )
        for statement in MIGRATION_DOCUMENT_REQUIRED_STATEMENTS:
            with self.subTest(statement=statement):
                commented = MIGRATION_DOCUMENT_CANONICAL.replace(
                    statement, f"<!-- {statement} -->"
                )
                negated = MIGRATION_DOCUMENT_CANONICAL.replace(
                    statement, f"It is not true that {statement}"
                )
                fenced = MIGRATION_DOCUMENT_CANONICAL.replace(
                    statement, f"```text\n\n{statement}\n\n```"
                )
                self.assertMigrationDocumentInvalid(commented, diagnostic)
                self.assertMigrationDocumentInvalid(negated, diagnostic)
                self.assertMigrationDocumentInvalid(fenced, diagnostic)

    def test_document_requires_all_five_commands_and_evidence_boundaries(self):
        diagnostic = (
            "migration document is missing a required standalone evidence statement"
        )
        for statement in MIGRATION_DOCUMENT_REQUIRED_STATEMENTS:
            with self.subTest(statement=statement):
                mutated = MIGRATION_DOCUMENT_CANONICAL.replace(
                    f"{statement}\n\n", ""
                )
                if mutated == MIGRATION_DOCUMENT_CANONICAL:
                    mutated = MIGRATION_DOCUMENT_CANONICAL.replace(
                        f"{statement}\n", ""
                    )
                self.assertMigrationDocumentInvalid(mutated, diagnostic)

    def test_document_requires_all_three_jobs_and_canonical_tag_message(self):
        diagnostic = (
            "migration document is missing a required standalone evidence statement"
        )
        old_two_job_gate = (
            "After the merge commit passes both macOS evidence jobs, create the "
            "annotated tag directly at the frozen source with `git tag --no-sign "
            f"-a {BASELINE_TAG} {SOURCE_COMMIT} -m \"Mac-Win migration baseline "
            "db12d5e\"`."
        )
        mutations = (
            MIGRATION_DOCUMENT_CANONICAL.replace(
                TAG_CREATION_GATE_STATEMENT, old_two_job_gate
            ),
            MIGRATION_DOCUMENT_CANONICAL.replace(
                "all three required jobs", "both macOS evidence jobs"
            ),
            MIGRATION_DOCUMENT_CANONICAL.replace(
                "Mac-Win migration source baseline db12d5e",
                "Mac-Win migration baseline db12d5e",
            ),
            MIGRATION_DOCUMENT_CANONICAL.replace(
                TAG_FAILURE_GATE_STATEMENT,
                "A failed required job may still permit tag publication.",
            ),
        )
        for text in mutations:
            with self.subTest(text=text):
                self.assertMigrationDocumentInvalid(text, diagnostic)

    def test_document_statement_matching_normalizes_only_ascii_whitespace(self):
        validator = load_validator()
        wrapped = MIGRATION_DOCUMENT_CANONICAL.replace(
            "The authoritative macOS evidence is the GitHub Actions run URL plus the logs and job summary for both required runner and architecture jobs.",
            "The authoritative macOS evidence is the GitHub Actions run URL plus\n"
            "the logs and job summary for both required runner and architecture jobs.",
        )
        validator.validate_migration_document(wrapped)

        non_ascii_space = MIGRATION_DOCUMENT_CANONICAL.replace(
            "Windows output is not macOS evidence.",
            "Windows\u00a0output is not macOS evidence.",
        )
        self.assertMigrationDocumentInvalid(
            non_ascii_space,
            "migration document is missing a required standalone evidence statement",
        )


class MigrationBaselineWorkflowTests(unittest.TestCase):
    DIGEST_DIAGNOSTIC = "migration workflow does not match the approved SHA-256 seal"
    SEMANTIC_DIAGNOSTIC = "migration workflow structure is not approved"

    def assertWorkflowInvalid(self, text, diagnostic=None):
        validator = load_validator()
        with self.assertRaises(validator.BaselineValidationError) as caught:
            validator.validate_workflow_document(text)
        self.assertEqual(
            str(caught.exception),
            diagnostic or self.DIGEST_DIAGNOSTIC,
        )

    def bashExecutable(self):
        if os.name == "nt":
            program_files = Path(
                os.environ.get("ProgramFiles", r"C:\Program Files")
            )
            for candidate in (
                program_files / "Git" / "bin" / "bash.exe",
                program_files / "Git" / "usr" / "bin" / "bash.exe",
            ):
                if candidate.is_file():
                    return str(candidate)
        executable = shutil.which("bash")
        if executable is None:
            self.skipTest("Bash is required to execute the sealed workflow step")
        return executable

    def swiftTestNames(self):
        names = []
        pattern = re.compile(r'@Test(?:\("((?:[^"\\]|\\.)*)"\))?')
        for path in sorted((ROOT / "MacWinManager" / "Tests").rglob("*.swift")):
            text = path.read_text(encoding="utf-8")
            for match in pattern.finditer(text):
                line_number = text.count("\n", 0, match.start()) + 1
                names.append(match.group(1) or f"{path.name}:{line_number}")
        self.assertEqual(
            len(names),
            500,  # 492 existing tests + 8 window-control permission regressions.
            "the migration baseline test-name fixture must cover every current @Test",
        )
        return names

    def swiftSixPassingOutput(self):
        return "".join(
            f'◇ Test "{name}" started.\n'
            f'✔ Test "{name}" passed after 0.001 seconds.\n'
            for name in self.swiftTestNames()
        ).encode("utf-8")

    def swiftEvidenceScript(self):
        return textwrap.dedent(WORKFLOW_CANONICAL.rsplit("        run: |\n", 1)[1])

    def runSwiftEvidence(self, raw_output, swift_status=0, script=None):
        if script is None:
            script = self.swiftEvidenceScript()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "fixture.log").write_bytes(raw_output)
            fake_swift = root / "swift"
            fake_swift.write_text(
                "#!/usr/bin/env bash\n"
                "if [[ -n \"${GITHUB_STEP_SUMMARY+x}\" || "
                "-n \"${summary_path+x}\" ]]; then\n"
                "  echo inherited-summary-path > env-leak\n"
                "fi\n"
                "cat fixture.log\n"
                "exit \"${SWIFT_FAKE_STATUS}\"\n",
                encoding="utf-8",
                newline="\n",
            )
            fake_swift.chmod(0o755)
            environment = os.environ.copy()
            environment.update(
                {
                    "PATH": ".:/usr/bin:/bin",
                    "RUNNER_TEMP": ".",
                    "GITHUB_STEP_SUMMARY": "summary.md",
                    "SWIFT_FAKE_STATUS": str(swift_status),
                }
            )
            result = subprocess.run(
                [self.bashExecutable(), "-c", script],
                cwd=root,
                env=environment,
                capture_output=True,
                text=False,
                shell=False,
                check=False,
            )
            summary_path = root / "summary.md"
            self.assertTrue(summary_path.is_file(), result.stderr.decode(errors="replace"))
            summary = summary_path.read_text(encoding="utf-8")
            leaked_summary_path = (root / "env-leak").exists()
            temporary_evidence = sorted(
                path.name for path in root.glob("mac-win-swift-*")
            )
            return result, summary, leaked_summary_path, temporary_evidence

    def test_reviewed_workflow_is_exact_sealed_and_semantically_valid(self):
        self.assertTrue(WORKFLOW_PATH.is_file(), "migration workflow is missing")
        self.assertEqual(WORKFLOW_PATH.read_text(encoding="utf-8"), WORKFLOW_CANONICAL)

        validator = load_validator()
        self.assertEqual(validator.APPROVED_WORKFLOW_TEXT, WORKFLOW_CANONICAL)
        self.assertEqual(validator.WORKFLOW_SHA256, WORKFLOW_SHA256)
        self.assertEqual(
            hashlib.sha256(
                WORKFLOW_PATH.read_text(encoding="utf-8").encode("utf-8")
            ).hexdigest(),
            WORKFLOW_SHA256,
        )
        validator.validate_workflow_document(WORKFLOW_CANONICAL)

    def test_xcode_16_2_pin_is_job_wide_and_exact(self):
        pin = "      DEVELOPER_DIR: /Applications/Xcode_16.2.app/Contents/Developer"
        job_env = f"    env:\n{pin}\n"
        self.assertEqual(WORKFLOW_CANONICAL.count(pin), 1)
        self.assertIn(
            "    timeout-minutes: 30\n" + job_env + "    steps:\n",
            WORKFLOW_CANONICAL,
        )
        pin_index = WORKFLOW_CANONICAL.index(pin)
        self.assertLess(
            pin_index,
            WORKFLOW_CANONICAL.index("      - name: Record and verify host facts"),
        )
        self.assertLess(
            pin_index,
            WORKFLOW_CANONICAL.index("      - name: Test Swift package"),
        )

        without_pin = WORKFLOW_CANONICAL.replace(job_env, "", 1)
        step_only = without_pin.replace(
            "      - name: Test Swift package\n        shell: bash\n",
            "      - name: Test Swift package\n"
            "        shell: bash\n"
            "        env:\n"
            "          DEVELOPER_DIR: /Applications/Xcode_16.2.app/Contents/Developer\n",
            1,
        )
        mutations = {
            "pin deleted": without_pin,
            "wrong Xcode version": WORKFLOW_CANONICAL.replace(
                "/Applications/Xcode_16.2.app/Contents/Developer",
                "/Applications/Xcode_16.4.app/Contents/Developer",
                1,
            ),
            "pin moved to one step": step_only,
        }
        validator = load_validator()
        for name, text in mutations.items():
            with self.subTest(name=name):
                self.assertNotEqual(text, WORKFLOW_CANONICAL)
                self.assertWorkflowInvalid(text)
                with self.assertRaises(
                    validator.BaselineValidationError
                ) as caught:
                    validator._validate_workflow_semantics(text)
                self.assertEqual(str(caught.exception), self.SEMANTIC_DIAGNOSTIC)

    def test_accepts_crlf_equivalent_workflow(self):
        validator = load_validator()
        validator.validate_workflow_document(
            WORKFLOW_CANONICAL.replace("\n", "\r\n")
        )

    def test_digest_is_checked_before_semantic_validation(self):
        validator = load_validator()
        drifted = WORKFLOW_CANONICAL.replace("ubuntu-24.04", "ubuntu-latest", 1)
        with mock.patch.object(
            validator,
            "_validate_workflow_semantics",
            side_effect=AssertionError("semantic helper must not inspect unsealed text"),
        ) as semantic:
            with self.assertRaises(validator.BaselineValidationError) as caught:
                validator.validate_workflow_document(drifted)
        self.assertEqual(str(caught.exception), self.DIGEST_DIAGNOSTIC)
        semantic.assert_not_called()

    def test_sealed_workflow_reaches_semantic_validation_once(self):
        validator = load_validator()
        with mock.patch.object(
            validator, "_validate_workflow_semantics"
        ) as semantic:
            validator.validate_workflow_document(WORKFLOW_CANONICAL)
        semantic.assert_called_once_with(WORKFLOW_CANONICAL)

    def test_rejects_required_structure_mutations_and_comment_decoys(self):
        pinned = CHECKOUT_ACTION
        mutations = {
            "pull requests not limited to main": WORKFLOW_CANONICAL.replace(
                "  pull_request:\n    branches:\n      - main\n",
                "  pull_request:\n",
            ),
            "missing Intel row": WORKFLOW_CANONICAL.replace(
                "          - runner: macos-15-intel\n"
                "            architecture: x86_64\n",
                "",
            ),
            "swapped Intel architecture": WORKFLOW_CANONICAL.replace(
                "          - runner: macos-15-intel\n"
                "            architecture: x86_64\n",
                "          - runner: macos-15-intel\n"
                "            architecture: arm64\n",
            ),
            "mutable checkout": WORKFLOW_CANONICAL.replace(pinned, "actions/checkout@v4"),
            "write permission": WORKFLOW_CANONICAL.replace(
                "  contents: read\n", "  contents: write\n"
            ),
            "changed Swift command": WORKFLOW_CANONICAL.replace(
                "swift test --package-path MacWinManager 2>&1",
                "swift test --package-path Other 2>&1",
            ),
            "hidden test fallback": WORKFLOW_CANONICAL.replace(
                "swift test --package-path MacWinManager 2>&1 | tee",
                "swift test --package-path MacWinManager 2>&1 || true | tee",
            ),
            "missing fetch depth": WORKFLOW_CANONICAL.replace(
                "          fetch-depth: 0\n", "", 1
            ),
            "shallow checkout": WORKFLOW_CANONICAL.replace(
                "          fetch-depth: 0\n", "          fetch-depth: 1\n", 1
            ),
            "comment-only Intel decoy": WORKFLOW_CANONICAL.replace(
                "          - runner: macos-15-intel\n"
                "            architecture: x86_64\n",
                "          # - runner: macos-15-intel\n"
                "          #   architecture: x86_64\n",
            ),
            "comment-only fetch-depth decoy": WORKFLOW_CANONICAL.replace(
                "          fetch-depth: 0\n",
                "          # fetch-depth: 0\n",
                1,
            ),
        }
        for name, text in mutations.items():
            with self.subTest(name=name):
                self.assertNotEqual(text, WORKFLOW_CANONICAL)
                self.assertWorkflowInvalid(text)

    def test_repository_contract_runs_the_complete_inventory_gate_in_order(self):
        validator = load_validator()
        repository_job = WORKFLOW_CANONICAL.split(
            "  repository-contract:\n", 1
        )[1].split("\n  swift-evidence:\n", 1)[0]
        required_lines = (
            "          fetch-depth: 0",
            '          python -B -m unittest discover -s tests -p "test_*.py" -v',
            "          python -B tools/validate_migration_baseline.py --require-tag",
            "          python -B tools/generate_migration_asset_inventory.py --check",
            "          python -B tools/validate_migration_asset_inventory.py",
        )
        positions = []
        for line in required_lines:
            self.assertEqual(repository_job.count(line), 1)
            positions.append(repository_job.index(line))
        self.assertEqual(positions, sorted(positions))
        self.assertIn("    runs-on: ubuntu-24.04\n", repository_job)

        mutations = {
            "baseline tag requirement deleted": WORKFLOW_CANONICAL.replace(
                " --require-tag\n", "\n", 1
            ),
            "inventory check changed to write": WORKFLOW_CANONICAL.replace(
                "generate_migration_asset_inventory.py --check",
                "generate_migration_asset_inventory.py --write",
                1,
            ),
            "inventory validator deleted": WORKFLOW_CANONICAL.replace(
                "          python -B tools/validate_migration_asset_inventory.py\n",
                "",
                1,
            ),
            "inventory validator is only a comment": WORKFLOW_CANONICAL.replace(
                "          python -B tools/validate_migration_asset_inventory.py\n",
                "          # python -B tools/validate_migration_asset_inventory.py\n",
                1,
            ),
            "generator and validator reordered": WORKFLOW_CANONICAL.replace(
                "          python -B tools/generate_migration_asset_inventory.py --check\n"
                "          python -B tools/validate_migration_asset_inventory.py\n",
                "          python -B tools/validate_migration_asset_inventory.py\n"
                "          python -B tools/generate_migration_asset_inventory.py --check\n",
                1,
            ),
            "full tests moved after validation": WORKFLOW_CANONICAL.replace(
                '          python -B -m unittest discover -s tests -p "test_*.py" -v\n'
                "          python -B tools/validate_migration_baseline.py --require-tag\n",
                "          python -B tools/validate_migration_baseline.py --require-tag\n"
                '          python -B -m unittest discover -s tests -p "test_*.py" -v\n',
                1,
            ),
        }
        for name, text in mutations.items():
            with self.subTest(name=name):
                self.assertNotEqual(text, WORKFLOW_CANONICAL)
                self.assertWorkflowInvalid(text)
                with self.assertRaises(
                    validator.BaselineValidationError
                ) as caught:
                    validator._validate_workflow_semantics(text)
                self.assertEqual(str(caught.exception), self.SEMANTIC_DIAGNOSTIC)

    def test_rejects_forbidden_capability_and_failure_masking_mutations(self):
        insert_at_job = "  repository-contract:\n"
        mutations = {
            "continue on error": WORKFLOW_CANONICAL.replace(
                "      - name: Test Swift package\n",
                "      - name: Test Swift package\n        continue-on-error: true\n",
            ),
            "artifact upload": WORKFLOW_CANONICAL.replace(
                insert_at_job,
                "  publish-artifact:\n"
                "    runs-on: ubuntu-24.04\n"
                "    steps:\n"
                "      - uses: actions/upload-artifact@v4\n\n"
                + insert_at_job,
            ),
            "release write": WORKFLOW_CANONICAL.replace(
                "  contents: read\n", "  contents: write\n  packages: write\n"
            ),
            "download": WORKFLOW_CANONICAL.replace(
                "          set -euo pipefail\n",
                "          set -euo pipefail\n          curl https://example.invalid/tool\n",
                1,
            ),
            "Bottle mutation": WORKFLOW_CANONICAL.replace(
                "          set -euo pipefail\n",
                "          set -euo pipefail\n          rm -rf Bottle\n",
                1,
            ),
            "product launch": WORKFLOW_CANONICAL.replace(
                "          set -euo pipefail\n",
                "          set -euo pipefail\n          open MacWinManager.app\n",
                1,
            ),
        }
        for name, text in mutations.items():
            with self.subTest(name=name):
                self.assertWorkflowInvalid(text)

    def test_swift_summary_isolated_bounded_safe_and_status_preserving(self):
        test_step = WORKFLOW_CANONICAL.split(
            "      - name: Test Swift package\n", 1
        )[1]
        summary_capture = 'summary_path="$GITHUB_STEP_SUMMARY"'
        summary_unexport = "export -n summary_path"
        summary_unset = "unset GITHUB_STEP_SUMMARY"
        swift_command = (
            "swift test --package-path MacWinManager 2>&1 | "
            'tee "$swift_output_file"'
        )
        self.assertLess(
            test_step.index(summary_capture), test_step.index(summary_unexport)
        )
        self.assertLess(test_step.index(summary_unexport), test_step.index(summary_unset))
        self.assertLess(test_step.index(summary_unset), test_step.index(swift_command))
        self.assertIn('swift_pipeline_status=("${PIPESTATUS[@]}")', test_step)
        self.assertIn("swift_status=${swift_pipeline_status[0]}", test_step)
        self.assertIn("swift_tee_status=${swift_pipeline_status[1]}", test_step)
        self.assertIn("swift_summary_raw_limit_bytes=262144", test_step)
        self.assertIn("swift_summary_copy_limit_bytes=524288", test_step)
        self.assertIn(
            "base64 < \"$swift_output_file\" | sed 's/^/    /'",
            test_step,
        )
        self.assertIn("if (( swift_summary_limit_exceeded != 0 )); then", test_step)
        self.assertIn('exit "$swift_status"', test_step)
        self.assertNotIn('tee -a "$GITHUB_STEP_SUMMARY"', test_step)
        self.assertNotIn("```", test_step)

    def test_swift_failure_status_is_preserved_in_summary_and_process(self):
        raw_output = b"intentional Swift failure\n"
        result, summary, leaked, temporary_evidence = self.runSwiftEvidence(
            raw_output,
            swift_status=7,
        )

        self.assertEqual(result.returncode, 7)
        self.assertEqual(result.stdout, raw_output)
        self.assertIn("Swift test exit status: 7", summary)
        self.assertFalse(leaked, "the Swift child inherited a summary path")
        self.assertEqual(temporary_evidence, [])

    def test_current_swift_six_output_passes_new_limit_and_old_limit_regresses(self):
        raw_output = b"```html\n<script>unsafe()</script>\n```\n" + self.swiftSixPassingOutput()
        self.assertGreater(len(raw_output), 65_536)
        self.assertLessEqual(len(raw_output), 262_144)

        current_script = self.swiftEvidenceScript()
        old_script = current_script.replace(
            "swift_summary_raw_limit_bytes=262144",
            "swift_summary_raw_limit_bytes=65536",
        )
        self.assertNotEqual(old_script, current_script)
        old_result, old_summary, _, _ = self.runSwiftEvidence(
            raw_output, script=old_script
        )
        self.assertEqual(old_result.returncode, 1)
        self.assertIn(
            "Swift test summary copy status: omitted; raw output limit exceeded; not truncated",
            old_summary,
        )

        result, summary, leaked, temporary_evidence = self.runSwiftEvidence(raw_output)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        self.assertEqual(result.stdout, raw_output)
        self.assertFalse(leaked, "the Swift child inherited a summary path")
        self.assertEqual(temporary_evidence, [])
        self.assertLess(len(summary.encode("utf-8")), 1_048_576)
        self.assertIn("Swift test exit status: 0", summary)
        self.assertIn("Swift test log capture exit status: 0", summary)
        self.assertIn(f"Swift test raw output bytes: {len(raw_output)}", summary)
        self.assertIn("Swift test raw output limit bytes: 262144", summary)
        self.assertIn(
            "Swift test summary copy status: complete; Markdown-safe base64 indented code; not truncated",
            summary,
        )
        self.assertTrue(
            all(not line.startswith("```") for line in summary.splitlines()),
            "fence-like Swift output must remain Markdown code, never active GFM",
        )

    def test_raw_output_one_byte_over_limit_fails_closed_with_bounded_summary(self):
        raw_output = b"x" * 262_145
        result, summary, leaked, temporary_evidence = self.runSwiftEvidence(raw_output)

        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, raw_output)
        self.assertFalse(leaked)
        self.assertEqual(temporary_evidence, [])
        self.assertLess(len(summary.encode("utf-8")), 1_048_576)
        self.assertIn("Swift test exit status: 0", summary)
        self.assertIn("Swift test raw output bytes: 262145", summary)
        self.assertIn(
            "Swift test summary copy status: omitted; raw output limit exceeded; not truncated",
            summary,
        )

    def test_markdown_safe_copy_over_limit_fails_closed_without_summary_overflow(self):
        raw_output = b"\n" * 100_000
        self.assertLessEqual(len(raw_output), 262_144)
        script = self.swiftEvidenceScript().replace(
            "swift_summary_copy_limit_bytes=524288",
            "swift_summary_copy_limit_bytes=131072",
        )
        result, summary, leaked, temporary_evidence = self.runSwiftEvidence(
            raw_output, script=script
        )

        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, raw_output)
        self.assertFalse(leaked)
        self.assertEqual(temporary_evidence, [])
        self.assertLess(len(summary.encode("utf-8")), 1_048_576)
        self.assertIn("Swift test exit status: 0", summary)
        match = re.search(r"Swift test Markdown-safe copy bytes: ([0-9]+)", summary)
        self.assertIsNotNone(match)
        self.assertGreater(int(match.group(1)), 131_072)
        self.assertIn(
            "Swift test summary copy status: omitted; Markdown-safe copy limit exceeded; not truncated",
            summary,
        )

    def test_rejects_summary_injection_isolation_limit_and_status_mutations(self):
        mutations = {
            "summary environment inherited": WORKFLOW_CANONICAL.replace(
                "          unset GITHUB_STEP_SUMMARY\n", ""
            ),
            "summary path exported": WORKFLOW_CANONICAL.replace(
                "          export -n summary_path\n", ""
            ),
            "raw output written into fenced summary": WORKFLOW_CANONICAL.replace(
                "          cat \"$swift_summary_copy_file\" >> \"$summary_path\"\n",
                "          echo '```text' >> \"$summary_path\"\n"
                "          cat \"$swift_output_file\" >> \"$summary_path\"\n"
                "          echo '```' >> \"$summary_path\"\n",
            ),
            "Markdown formatter removed": WORKFLOW_CANONICAL.replace(
                "            base64 < \"$swift_output_file\" | sed 's/^/    /' > \"$swift_summary_copy_file\"\n",
                "            cat \"$swift_output_file\" > \"$swift_summary_copy_file\"\n",
            ),
            "raw limit disabled": WORKFLOW_CANONICAL.replace(
                "          swift_summary_raw_limit_bytes=262144\n",
                "          swift_summary_raw_limit_bytes=999999999\n",
            ),
            "formatted limit disabled": WORKFLOW_CANONICAL.replace(
                "          swift_summary_copy_limit_bytes=524288\n",
                "          swift_summary_copy_limit_bytes=999999999\n",
            ),
            "overlimit gate removed": WORKFLOW_CANONICAL.replace(
                "          if (( swift_summary_limit_exceeded != 0 )); then\n"
                "            exit 1\n"
                "          fi\n",
                "",
            ),
            "wrong pipeline status": WORKFLOW_CANONICAL.replace(
                "swift_status=${swift_pipeline_status[0]}",
                "swift_status=${swift_pipeline_status[1]}",
            ),
            "tee failure gate removed": WORKFLOW_CANONICAL.replace(
                "          if (( swift_capture_failed != 0 )); then\n"
                "            exit 1\n"
                "          fi\n",
                "",
            ),
            "formatter failure gate removed": WORKFLOW_CANONICAL.replace(
                "          if (( swift_format_failed != 0 )); then\n"
                "            exit 1\n"
                "          fi\n",
                "",
            ),
            "Swift status masked": WORKFLOW_CANONICAL.replace(
                '          exit "$swift_status"\n',
                "          exit 0\n",
            ),
            "summary status omitted": WORKFLOW_CANONICAL.replace(
                "            echo \"- Swift test exit status: ${swift_status}\"\n",
                "",
            ),
            "temporary cleanup removed": WORKFLOW_CANONICAL.replace(
                "          trap 'rm -f \"$swift_output_file\"; if [[ -n \"$swift_summary_copy_file\" ]]; then rm -f \"$swift_summary_copy_file\"; fi' EXIT\n",
                "",
            ),
        }
        for name, text in mutations.items():
            with self.subTest(name=name):
                self.assertNotEqual(text, WORKFLOW_CANONICAL)
                self.assertWorkflowInvalid(text)

    def test_semantic_structure_does_not_treat_yaml_comments_as_configuration(self):
        validator = load_validator()
        decoys = (
            WORKFLOW_CANONICAL.replace(
                "          - runner: macos-15-intel\n"
                "            architecture: x86_64\n",
                "          # - runner: macos-15-intel\n"
                "          #   architecture: x86_64\n",
            ),
            WORKFLOW_CANONICAL.replace(
                "  contents: read\n", "  # contents: read\n"
            ),
        )
        for text in decoys:
            with self.subTest(text=text):
                with self.assertRaises(validator.BaselineValidationError) as caught:
                    validator._validate_workflow_semantics(text)
                self.assertEqual(str(caught.exception), self.SEMANTIC_DIAGNOSTIC)

    def test_rejects_every_single_byte_drift_from_the_sealed_workflow(self):
        validator = load_validator()
        raw = WORKFLOW_CANONICAL.encode("utf-8")
        for index in range(len(raw)):
            mutated = bytearray(raw)
            mutated[index] ^= 1
            with self.subTest(index=index):
                with self.assertRaises(validator.BaselineValidationError) as caught:
                    validator.validate_workflow_document(
                        bytes(mutated).decode("utf-8", errors="strict")
                    )
                self.assertEqual(str(caught.exception), self.DIGEST_DIAGNOSTIC)


class MigrationBaselineGitSourceTests(unittest.TestCase):
    GIT_IDENTITY = (
        "-c",
        "user.name=Mac-Win Baseline Tests",
        "-c",
        "user.email=baseline-tests@example.invalid",
        "-c",
        "commit.gpgSign=false",
        "-c",
        "tag.gpgSign=false",
    )
    GIT_OVERRIDE_VARIABLES = (
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_COMMON_DIR",
        "GIT_INDEX_FILE",
        "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_NAMESPACE",
    )
    GIT_SAFETY_VARIABLES = {
        "GIT_CONFIG_GLOBAL": os.devnull,
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_NO_LAZY_FETCH": "1",
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_NO_REPLACE_OBJECTS": "1",
    }

    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.test_root = Path(self.temporary_directory.name)

    def runGit(self, repository, *arguments, environment=None, check=True):
        result = run_fixture_git(
            repository,
            *arguments,
            configuration=self.GIT_IDENTITY,
            environment=environment,
        )
        if check and result.returncode != 0:
            self.fail(
                f"Git fixture command failed ({result.returncode}): "
                f"{arguments!r}\nstdout: {result.stdout}\nstderr: {result.stderr}"
            )
        return result

    def createRepository(
        self,
        name,
        source_text="source\n",
        descendant_text="descendant\n",
    ):
        repository = self.test_root / name
        self.runGit(repository, "init", "-b", "main")

        tracked = repository / "tracked.txt"
        tracked.write_text(source_text, encoding="utf-8")
        self.runGit(repository, "add", "tracked.txt")
        self.runGit(repository, "commit", "-m", "source")
        source_commit = self.runGit(
            repository, "rev-parse", "HEAD"
        ).stdout.strip()

        tracked.write_text(descendant_text, encoding="utf-8")
        self.runGit(repository, "add", "tracked.txt")
        self.runGit(repository, "commit", "-m", "descendant")
        descendant_commit = self.runGit(
            repository, "rev-parse", "HEAD"
        ).stdout.strip()
        return repository, source_commit, descendant_commit

    def assertSourceInvalid(self, repository, source_commit, diagnostic):
        validator = load_validator()
        with self.assertRaises(validator.BaselineValidationError) as caught:
            validator.validate_source_commit(repository, source_commit)
        self.assertEqual(str(caught.exception), diagnostic)

    def test_accepts_local_commit_that_is_an_ancestor_of_head(self):
        repository, source_commit, _ = self.createRepository("target")
        validator = load_validator()

        validator.validate_source_commit(repository, source_commit)

    def test_git_fixture_ignores_ambient_commit_signing(self):
        pollution = {
            **GIT_SIGNING_POLLUTION,
            **GIT_HOSTILE_REPOSITORY_POLLUTION,
            "GIT_TEST_ASSUME_DIFFERENT_OWNER": "1",
        }
        with mock.patch.dict(os.environ, pollution, clear=False):
            repository, source_commit, _ = self.createRepository(
                "signing-pollution"
            )

        validator = load_validator()
        validator.validate_source_commit(repository, source_commit)

    def test_rejects_missing_source_object_with_stable_diagnostic(self):
        repository, _, _ = self.createRepository("target")

        self.assertSourceInvalid(
            repository,
            "0" * 40,
            "source commit is not a local commit object",
        )

    def test_rejects_blob_tree_and_tag_objects_as_source_commits(self):
        repository, source_commit, _ = self.createRepository("target")
        blob = self.runGit(
            repository, "rev-parse", f"{source_commit}:tracked.txt"
        ).stdout.strip()
        tree = self.runGit(
            repository, "rev-parse", f"{source_commit}^{{tree}}"
        ).stdout.strip()
        self.runGit(
            repository,
            "tag",
            "-a",
            "source-tag",
            source_commit,
            "-m",
            "tag",
        )
        tag = self.runGit(
            repository, "rev-parse", "refs/tags/source-tag"
        ).stdout.strip()

        objects = (("blob", blob), ("tree", tree), ("tag", tag))
        for object_name, object_id in objects:
            with self.subTest(object_type=object_name):
                self.assertSourceInvalid(
                    repository,
                    object_id,
                    "source commit is not a local commit object",
                )

    def test_rejects_local_commit_that_is_not_an_ancestor_of_head(self):
        repository, source_commit, _ = self.createRepository("target")
        tree = self.runGit(
            repository, "rev-parse", f"{source_commit}^{{tree}}"
        ).stdout.strip()
        unrelated_commit = self.runGit(
            repository, "commit-tree", tree, "-m", "unrelated root"
        ).stdout.strip()

        self.assertSourceInvalid(
            repository,
            unrelated_commit,
            "source commit is not an ancestor of HEAD",
        )

    def test_replace_ref_cannot_supply_a_missing_source_commit(self):
        repository, source_commit, _ = self.createRepository("target")
        replaced_object = "1" * 40
        self.runGit(
            repository,
            "update-ref",
            f"refs/replace/{replaced_object}",
            source_commit,
        )
        unprotected_environment = os.environ.copy()
        unprotected_environment.pop("GIT_NO_REPLACE_OBJECTS", None)
        self.assertEqual(
            self.runGit(
                repository,
                "cat-file",
                "-t",
                replaced_object,
                environment=unprotected_environment,
            ).stdout.strip(),
            "commit",
        )

        self.assertSourceInvalid(
            repository,
            replaced_object,
            "source commit is not a local commit object",
        )

    def test_git_subprocesses_use_target_and_sanitized_environment(self):
        repository, source_commit, _ = self.createRepository("target")
        alternate, _, _ = self.createRepository(
            "alternate",
            source_text="alternate source\n",
            descendant_text="alternate descendant\n",
        )
        alternate_git = alternate / ".git"
        self.assertNotEqual(
            self.runGit(
                alternate,
                "cat-file",
                "-t",
                source_commit,
                check=False,
            ).returncode,
            0,
            "fixture must prove the target source object is absent from the alternate",
        )
        pollution = {
            "GIT_DIR": str(alternate_git),
            "GIT_WORK_TREE": str(alternate),
            "GIT_COMMON_DIR": str(alternate_git),
            "GIT_INDEX_FILE": str(alternate_git / "index"),
            "GIT_OBJECT_DIRECTORY": str(alternate_git / "objects"),
            "GIT_ALTERNATE_OBJECT_DIRECTORIES": str(alternate_git / "objects"),
            "GIT_NAMESPACE": "redirected",
            "GIT_CONFIG_COUNT": "2",
            "GIT_CONFIG_KEY_0": "core.hooksPath",
            "GIT_CONFIG_VALUE_0": str(alternate / "hooks"),
            "GIT_CONFIG_KEY_1": "core.attributesFile",
            "GIT_CONFIG_VALUE_1": str(alternate / "attributes"),
            "GIT_CONFIG_GLOBAL": str(alternate / "global-config"),
            "GIT_CONFIG_SYSTEM": str(alternate / "system-config"),
        }
        validator = load_validator()
        real_run = subprocess.run
        recorded_calls = []

        def recording_run(*args, **kwargs):
            recorded_calls.append((args, kwargs))
            return real_run(*args, **kwargs)

        with mock.patch.dict(os.environ, pollution, clear=False):
            with mock.patch.object(
                validator.subprocess, "run", side_effect=recording_run
            ):
                validator.validate_source_commit(repository, source_commit)

        self.assertEqual(len(recorded_calls), 2)
        self.assertEqual(
            [call[0][0] for call in recorded_calls],
            [
                [
                    "git",
                    "-c",
                    f"safe.directory={repository.resolve()}",
                    "cat-file",
                    "-t",
                    source_commit,
                ],
                [
                    "git",
                    "-c",
                    f"safe.directory={repository.resolve()}",
                    "merge-base",
                    "--is-ancestor",
                    source_commit,
                    "HEAD",
                ],
            ],
        )
        for positional, keywords in recorded_calls:
            with self.subTest(argv=positional[0]):
                self.assertIsInstance(positional[0], list)
                self.assertEqual(keywords["cwd"], repository.resolve())
                self.assertIs(keywords["shell"], False)
                self.assertIs(keywords["capture_output"], True)
                self.assertIs(keywords["text"], False)
                self.assertIs(keywords["check"], False)
                self.assertIs(keywords["stdin"], subprocess.DEVNULL)
                child_environment = keywords["env"]
                self.assertFalse(
                    any(
                        key.upper() in self.GIT_OVERRIDE_VARIABLES
                        for key in child_environment
                    )
                )
                self.assertFalse(
                    any(
                        key.upper().startswith("GIT_CONFIG")
                        and key.upper() not in self.GIT_SAFETY_VARIABLES
                        for key in child_environment
                    )
                )
                for variable, value in self.GIT_SAFETY_VARIABLES.items():
                    self.assertEqual(child_environment.get(variable), value)

    def test_git_environment_scrubs_casefolded_repository_and_config_injection(self):
        hostile = {
            "PATH": os.environ.get("PATH", ""),
            "KEEP_ME": "yes",
            "git_dir": "decoy",
            "Git_Work_Tree": "decoy",
            "gIt_CoMmOn_DiR": "decoy",
            "git_index_file": "decoy",
            "Git_Object_Directory": "decoy",
            "git_alternate_object_directories": "decoy",
            "Git_Namespace": "decoy",
            "git_shallow_file": "decoy",
            "Git_Config_Count": "1",
            "git_config_key_0": "core.bare",
            "GIT_CONFIG_VALUE_0": "true",
            "Git_Config_Global": "decoy",
            "git_config_system": "decoy",
            "GIT_CONFIG_PARAMETERS": "'core.worktree'='decoy'",
            "GIT_TEST_ASSUME_DIFFERENT_OWNER": "1",
        }
        validator = load_validator()

        cleaned = validator._git_environment(hostile)

        self.assertEqual(cleaned["PATH"], hostile["PATH"])
        self.assertEqual(cleaned["KEEP_ME"], "yes")
        self.assertEqual(cleaned["GIT_TEST_ASSUME_DIFFERENT_OWNER"], "1")
        self.assertFalse(
            any(
                key.upper() in {*self.GIT_OVERRIDE_VARIABLES, "GIT_SHALLOW_FILE"}
                or (
                    key.upper().startswith("GIT_CONFIG")
                    and key.upper() not in self.GIT_SAFETY_VARIABLES
                )
                for key in cleaned
            )
        )
        for variable, value in self.GIT_SAFETY_VARIABLES.items():
            self.assertEqual(cleaned.get(variable), value)
        self.assertEqual(hostile["git_dir"], "decoy")

    def test_fixture_git_environment_scrubs_all_ambient_git_state(self):
        hostile = {
            "PATH": os.environ.get("PATH", ""),
            "KEEP_ME": "yes",
            "git_dir": "decoy",
            "Git_Config_Count": "1",
            "git_config_key_0": "core.hooksPath",
            "GIT_CONFIG_VALUE_0": "decoy-hooks",
            "GIT_TEST_ASSUME_DIFFERENT_OWNER": "1",
        }

        cleaned = fixture_git_environment(hostile)

        self.assertEqual(cleaned["PATH"], hostile["PATH"])
        self.assertEqual(cleaned["KEEP_ME"], "yes")
        self.assertEqual(
            {key for key in cleaned if key.upper().startswith("GIT_")},
            {"GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM", "GIT_TERMINAL_PROMPT"},
        )
        self.assertEqual(cleaned["GIT_CONFIG_GLOBAL"], os.devnull)
        self.assertEqual(cleaned["GIT_CONFIG_NOSYSTEM"], "1")
        self.assertEqual(cleaned["GIT_TERMINAL_PROMPT"], "0")
        self.assertEqual(hostile["git_dir"], "decoy")

    def test_git_runner_handles_forced_dubious_ownership_with_exact_safe_root(self):
        repository, source_commit, _ = self.createRepository("forced-owner")
        validator = load_validator()

        with mock.patch.dict(
            os.environ,
            {"GIT_TEST_ASSUME_DIFFERENT_OWNER": "1"},
            clear=False,
        ):
            validator.validate_source_commit(repository, source_commit)

    def test_default_and_require_tag_cli_handle_forced_dubious_ownership(self):
        environment = os.environ.copy()
        environment["GIT_TEST_ASSUME_DIFFERENT_OWNER"] = "1"

        for arguments in ((), ("--require-tag",)):
            with self.subTest(arguments=arguments):
                result = subprocess.run(
                    [sys.executable, "-B", str(VALIDATOR_PATH), *arguments],
                    cwd=ROOT,
                    env=environment,
                    capture_output=True,
                    text=True,
                    shell=False,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    result.stdout,
                    "Mac-Win migration baseline is valid.\n",
                )
                self.assertEqual(result.stderr, "")

    def test_main_binds_reviewed_bytes_before_semantic_validation(self):
        validator = load_validator()
        events = []
        parsed_manifest = object()

        def parse_manifest_bytes(raw):
            events.append(("parse", raw))
            return parsed_manifest

        def validate_manifest(manifest):
            events.append(("validate", manifest))

        def validate_source_commit(repository, source_commit):
            events.append(("source", repository, source_commit))

        def validate_readme_document(text):
            events.append(("readme-semantic", text))

        def validate_migration_document(text):
            events.append(("migration-semantic", text))

        def read_reviewed_text(
            repository, relative_path, expected_text, maximum_bytes
        ):
            events.append(
                (
                    "reviewed",
                    repository,
                    relative_path,
                    expected_text,
                    maximum_bytes,
                )
            )
            return expected_text

        with mock.patch.object(
            validator,
            "load_manifest",
            side_effect=AssertionError("main must not read the manifest twice"),
        ):
            with mock.patch.object(
                validator,
                "read_reviewed_text",
                side_effect=read_reviewed_text,
            ):
                with mock.patch.object(
                    validator,
                    "parse_manifest_bytes",
                    side_effect=parse_manifest_bytes,
                ):
                    with mock.patch.object(
                        validator,
                        "validate_manifest",
                        side_effect=validate_manifest,
                    ):
                        with mock.patch.object(
                            validator,
                            "validate_source_commit",
                            side_effect=validate_source_commit,
                        ):
                            with mock.patch.object(
                                validator,
                                "validate_readme_document",
                                side_effect=validate_readme_document,
                            ):
                                with mock.patch.object(
                                    validator,
                                    "validate_migration_document",
                                    side_effect=validate_migration_document,
                                ):
                                    with mock.patch("builtins.print"):
                                        self.assertEqual(validator.main(), 0)

        self.assertEqual(
            events,
            [
                (
                    "reviewed",
                    validator.ROOT,
                    validator.MANIFEST_RELATIVE_PATH,
                    validator.APPROVED_MANIFEST_TEXT,
                    validator.MAX_MANIFEST_BYTES,
                ),
                ("parse", validator.APPROVED_MANIFEST_TEXT.encode("utf-8")),
                ("validate", parsed_manifest),
                ("source", validator.ROOT, validator.SOURCE_COMMIT),
                (
                    "reviewed",
                    validator.ROOT,
                    validator.README_RELATIVE_PATH,
                    validator.APPROVED_README_TEXT,
                    validator.MAX_README_BYTES,
                ),
                ("readme-semantic", validator.APPROVED_README_TEXT),
                (
                    "reviewed",
                    validator.ROOT,
                    validator.MIGRATION_DOCUMENT_RELATIVE_PATH,
                    validator.APPROVED_MIGRATION_DOCUMENT_TEXT,
                    validator.MAX_MIGRATION_DOCUMENT_BYTES,
                ),
                (
                    "migration-semantic",
                    validator.APPROVED_MIGRATION_DOCUMENT_TEXT,
                ),
                (
                    "reviewed",
                    validator.ROOT,
                    validator.WORKFLOW_RELATIVE_PATH,
                    validator.APPROVED_WORKFLOW_TEXT,
                    validator.MAX_WORKFLOW_BYTES,
                ),
            ],
        )


class MigrationBaselineTagTests(unittest.TestCase):
    GIT_IDENTITY = (
        "-c",
        "user.name=Mac-Win Baseline Tests",
        "-c",
        "user.email=baseline-tests@example.invalid",
        "-c",
        "commit.gpgSign=false",
        "-c",
        "tag.gpgSign=false",
    )

    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.test_root = Path(self.temporary_directory.name)

    def runGit(
        self,
        repository,
        *arguments,
        environment=None,
        input_bytes=None,
        check=True,
    ):
        result = run_fixture_git(
            repository,
            *arguments,
            configuration=self.GIT_IDENTITY,
            environment=environment,
            input_bytes=input_bytes,
        )
        if check and result.returncode != 0:
            self.fail(
                f"Git fixture command failed ({result.returncode}): "
                f"{arguments!r}\nstdout: {result.stdout}\nstderr: {result.stderr}"
            )
        return result

    def createRepository(self, name):
        repository = self.test_root / name
        self.runGit(repository, "init", "-b", "main")
        tracked = repository / "tracked.txt"
        tracked.write_text("source\n", encoding="utf-8")
        self.runGit(repository, "add", "tracked.txt")
        self.runGit(repository, "commit", "-m", "source")
        source_commit = self.runGit(repository, "rev-parse", "HEAD").stdout.strip()
        tracked.write_text("descendant\n", encoding="utf-8")
        self.runGit(repository, "add", "tracked.txt")
        self.runGit(repository, "commit", "-m", "descendant")
        descendant_commit = self.runGit(
            repository, "rev-parse", "HEAD"
        ).stdout.strip()
        return repository, source_commit, descendant_commit

    def createHostileCloneTemplate(self, name):
        template = self.test_root / name
        hooks = template / "hooks"
        hooks.mkdir(parents=True)
        post_checkout = hooks / "post-checkout"
        post_checkout.write_text(
            "#!/bin/sh\nexit 93\n",
            encoding="utf-8",
            newline="\n",
        )
        post_checkout.chmod(0o755)
        return template

    def cloneCurrentRepository(self, name):
        repository = self.test_root / name
        safe_root = f"safe.directory={ROOT}"
        clone_environment = clone_git_test_environment(
            assume_different_owner=(
                os.environ.get("GIT_TEST_ASSUME_DIFFERENT_OWNER") == "1"
            )
        )
        git_directory_result = subprocess.run(
            ["git", "-c", safe_root, "rev-parse", "--absolute-git-dir"],
            cwd=ROOT,
            env=clone_environment,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            shell=False,
            check=False,
        )
        if git_directory_result.returncode != 0:
            self.fail("Git CLI fixture could not resolve the worktree admin directory")
        git_directory = git_directory_result.stdout.strip()
        if not git_directory:
            self.fail("Git CLI fixture returned an empty worktree admin directory")
        safe_git_directory = f"safe.directory={git_directory}"
        current_head_result = subprocess.run(
            [
                "git",
                "-c",
                safe_root,
                "-c",
                safe_git_directory,
                "rev-parse",
                "HEAD",
            ],
            cwd=ROOT,
            env=clone_environment,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            shell=False,
            check=False,
        )
        if current_head_result.returncode != 0:
            self.fail("Git CLI fixture could not resolve the current commit")
        current_head = current_head_result.stdout.strip()
        result = subprocess.run(
            [
                "git",
                "-c",
                safe_root,
                "-c",
                safe_git_directory,
                "-c",
                f"core.hooksPath={os.devnull}",
                "-c",
                "commit.gpgSign=false",
                "-c",
                "tag.gpgSign=false",
                "clone",
                "--no-hardlinks",
                str(ROOT),
                str(repository),
            ],
            cwd=self.test_root,
            env=clone_environment,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            shell=False,
            check=False,
        )
        if result.returncode != 0:
            self.fail(
                f"Git CLI fixture clone failed ({result.returncode})\n"
                f"stdout: {result.stdout}\nstderr: {result.stderr}"
            )
        self.runGit(repository, "checkout", "--detach", current_head)
        shutil.copyfile(
            VALIDATOR_PATH,
            repository / "tools" / "validate_migration_baseline.py",
        )
        shutil.copyfile(
            GIT_METADATA_PATH,
            repository / "tools" / "migration_git_metadata.py",
        )
        shutil.copyfile(
            README_PATH,
            repository / README_PATH.relative_to(ROOT),
        )
        shutil.copyfile(
            WORKFLOW_PATH,
            repository / WORKFLOW_PATH.relative_to(ROOT),
        )
        self.runGit(
            repository,
            "add",
            README_PATH.relative_to(ROOT).as_posix(),
            WORKFLOW_RELATIVE_PATH,
        )
        return repository

    def createRawTagObject(
        self,
        repository,
        source_commit,
        *,
        internal_name=BASELINE_TAG,
        message=TAG_MESSAGE,
        timestamp=0,
    ):
        raw = (
            f"object {source_commit}\n"
            "type commit\n"
            f"tag {internal_name}\n"
            "tagger Baseline Tests <baseline-tests@example.invalid> "
            f"{timestamp} +0000\n"
            "\n"
            f"{message}\n"
        ).encode("utf-8")
        result = self.runGit(repository, "mktag", input_bytes=raw)
        return result.stdout.decode("ascii").strip()

    def createUncheckedTagObject(self, repository, source_commit, tagger_line):
        raw = (
            f"object {source_commit}\n"
            "type commit\n"
            f"tag {BASELINE_TAG}\n"
            f"{tagger_line}\n"
            "\n"
            f"{TAG_MESSAGE}\n"
        ).encode("utf-8")
        strict_result = self.runGit(
            repository,
            "mktag",
            input_bytes=raw,
            check=False,
        )
        self.assertNotEqual(
            strict_result.returncode,
            0,
            "fixture must be rejected by Git's native tag validation",
        )
        result = self.runGit(
            repository,
            "hash-object",
            "--literally",
            "-t",
            "tag",
            "-w",
            "--stdin",
            input_bytes=raw,
        )
        return result.stdout.decode("ascii").strip()

    def validateTag(self, repository, source_commit):
        validator = load_validator()
        validator.validate_baseline_tag(repository, BASELINE_TAG, source_commit)

    def assertTagInvalid(self, repository, source_commit, diagnostic):
        validator = load_validator()
        with self.assertRaises(validator.BaselineValidationError) as caught:
            validator.validate_baseline_tag(repository, BASELINE_TAG, source_commit)
        self.assertEqual(str(caught.exception), diagnostic)

    def test_default_main_does_not_require_a_preexisting_tag(self):
        validator = load_validator()
        with mock.patch.object(validator, "read_reviewed_text") as reviewed:
            reviewed.side_effect = lambda _root, _path, approved, _limit: approved
            with mock.patch.object(validator, "validate_source_commit"):
                with mock.patch.object(
                    validator,
                    "validate_baseline_tag",
                    side_effect=AssertionError("default validation must not inspect the tag"),
                ) as tag_validation:
                    with mock.patch("builtins.print") as printed:
                        self.assertEqual(validator.main([]), 0)

        tag_validation.assert_not_called()
        printed.assert_called_once_with("Mac-Win migration baseline is valid.")

    def test_cli_fixture_clone_handles_dubious_worktree_ownership_locally(self):
        admin_result = run_sanitized_git(
            ROOT,
            "rev-parse",
            "--absolute-git-dir",
        )
        self.assertEqual(admin_result.returncode, 0, admin_result.stderr)
        expected_admin = admin_result.stdout.strip()
        template = self.createHostileCloneTemplate("dubious-owner-template")
        real_run = subprocess.run
        recorded_calls = []

        def recording_run(*args, **kwargs):
            recorded_calls.append((args, kwargs))
            return real_run(*args, **kwargs)

        with mock.patch.object(self, "runGit") as git_commands:
            with mock.patch.object(subprocess, "run", side_effect=recording_run):
                with mock.patch.dict(
                    os.environ,
                    {
                        "GIT_TEMPLATE_DIR": str(template),
                        "GIT_TEST_ASSUME_DIFFERENT_OWNER": "1",
                    },
                ):
                    repository = self.cloneCurrentRepository("dubious-owner")

        self.assertTrue(
            (repository / "tools" / "validate_migration_baseline.py").is_file()
        )
        self.assertEqual(
            (repository / README_PATH.relative_to(ROOT)).read_bytes(),
            README_PATH.read_bytes(),
        )
        self.assertTrue((repository / WORKFLOW_PATH.relative_to(ROOT)).is_file())
        self.assertEqual(git_commands.call_count, 2)
        checkout_repository, command, mode, current_head = (
            git_commands.call_args_list[0].args
        )
        self.assertEqual(checkout_repository, repository)
        self.assertEqual((command, mode), ("checkout", "--detach"))
        self.assertRegex(current_head, r"\A[0-9a-f]{40}(?:[0-9a-f]{24})?\Z")
        self.assertEqual(
            git_commands.call_args_list[1].args,
            (
                repository,
                "add",
                README_PATH.relative_to(ROOT).as_posix(),
                WORKFLOW_RELATIVE_PATH,
            ),
        )
        clone_calls = [
            call for call in recorded_calls if "clone" in call[0][0]
        ]
        self.assertEqual(len(clone_calls), 1)
        clone_argv = clone_calls[0][0][0]
        self.assertEqual(
            clone_argv[:11],
            [
                "git",
                "-c",
                f"safe.directory={ROOT}",
                "-c",
                f"safe.directory={expected_admin}",
                "-c",
                f"core.hooksPath={os.devnull}",
                "-c",
                "commit.gpgSign=false",
                "-c",
                "tag.gpgSign=false",
            ],
        )
        clone_environment = clone_calls[0][1]["env"]
        self.assertEqual(clone_environment["GIT_TEST_ASSUME_DIFFERENT_OWNER"], "1")
        self.assertNotIn("GIT_TEMPLATE_DIR", clone_environment)

    def test_clone_environment_scrubs_every_ambient_git_clone_override(self):
        hostile = {
            "PATH": os.environ.get("PATH", ""),
            "KEEP_ME": "yes",
            "GIT_TEMPLATE_DIR": "decoy-template",
            "GIT_CLONE_PROTECTION_ACTIVE": "false",
            "GIT_PROTOCOL_FROM_USER": "1",
            "git_dir": "decoy-dir",
            "Git_Config_Count": "1",
            "git_config_key_0": "core.hooksPath",
            "GIT_CONFIG_VALUE_0": "decoy-hooks",
            "GIT_TEST_ASSUME_DIFFERENT_OWNER": "1",
        }

        cleaned = clone_git_test_environment(
            hostile,
            assume_different_owner=True,
        )

        self.assertEqual(cleaned["PATH"], hostile["PATH"])
        self.assertEqual(cleaned["KEEP_ME"], "yes")
        self.assertEqual(cleaned["GIT_TEST_ASSUME_DIFFERENT_OWNER"], "1")
        self.assertEqual(
            {key for key in cleaned if key.upper().startswith("GIT_")},
            {
                "GIT_CONFIG_GLOBAL",
                "GIT_CONFIG_NOSYSTEM",
                "GIT_NO_LAZY_FETCH",
                "GIT_NO_REPLACE_OBJECTS",
                "GIT_TERMINAL_PROMPT",
                "GIT_TEST_ASSUME_DIFFERENT_OWNER",
            },
        )
        self.assertEqual(hostile["GIT_TEMPLATE_DIR"], "decoy-template")

    def test_require_tag_main_adds_tag_verification_after_repository_contract(self):
        validator = load_validator()
        events = []

        def reviewed(_root, path, approved, _limit):
            events.append(("reviewed", path))
            return approved

        with mock.patch.object(
            validator, "read_reviewed_text", side_effect=reviewed
        ):
            with mock.patch.object(validator, "validate_source_commit"):
                with mock.patch.object(
                    validator,
                    "validate_baseline_tag",
                    side_effect=lambda root, tag, source: events.append(
                        ("tag", root, tag, source)
                    ),
                ):
                    with mock.patch("builtins.print"):
                        self.assertEqual(validator.main(["--require-tag"]), 0)

        self.assertEqual(
            events[-1],
            ("tag", validator.ROOT, validator.TAG, validator.SOURCE_COMMIT),
        )
        self.assertEqual(
            [event[1] for event in events[:-1]],
            [
                validator.MANIFEST_RELATIVE_PATH,
                validator.README_RELATIVE_PATH,
                validator.MIGRATION_DOCUMENT_RELATIVE_PATH,
                validator.WORKFLOW_RELATIVE_PATH,
            ],
        )

    def test_require_tag_rejects_missing_and_lightweight_tags(self):
        for kind in ("missing", "lightweight"):
            with self.subTest(kind=kind):
                repository, source_commit, _ = self.createRepository(kind)
                if kind == "lightweight":
                    self.runGit(repository, "tag", BASELINE_TAG, source_commit)
                self.assertTagInvalid(
                    repository,
                    source_commit,
                    "baseline tag is not a local annotated tag object",
                )

    def test_require_tag_rejects_annotated_tag_at_wrong_commit(self):
        repository, source_commit, descendant_commit = self.createRepository("wrong")
        self.runGit(
            repository,
            "tag",
            "-a",
            BASELINE_TAG,
            descendant_commit,
            "-m",
            "wrong baseline",
        )
        self.assertTagInvalid(
            repository,
            source_commit,
            "baseline tag does not peel to the source commit",
        )

    def test_require_tag_accepts_annotated_tag_directly_at_source(self):
        repository, source_commit, _ = self.createRepository("exact")
        self.runGit(
            repository,
            "tag",
            "-a",
            BASELINE_TAG,
            source_commit,
            "-m",
            TAG_MESSAGE,
        )
        self.validateTag(repository, source_commit)

    def test_rejects_linked_and_nonregular_tag_ref_metadata(self):
        repository, source_commit, _ = self.createRepository("linked-tag-ref")
        self.runGit(
            repository,
            "tag",
            "-a",
            BASELINE_TAG,
            source_commit,
            "-m",
            TAG_MESSAGE,
        )
        loose_ref = repository / ".git" / "refs" / "tags" / BASELINE_TAG
        external = self.test_root / "external-tag-ref"
        loose_ref.rename(external)
        try:
            try:
                loose_ref.symlink_to(external)
            except OSError as error:
                external.rename(loose_ref)
                self.skipTest(f"file symlink creation is unavailable: {error}")
            self.assertTagInvalid(
                repository,
                source_commit,
                "baseline tag ref metadata is unsafe",
            )
        finally:
            if loose_ref.is_symlink():
                loose_ref.unlink()
            if external.exists():
                external.rename(loose_ref)

        loose_ref.rename(external)
        loose_ref.mkdir()
        try:
            self.assertTagInvalid(
                repository,
                source_commit,
                "baseline tag ref metadata is unsafe",
            )
        finally:
            loose_ref.rmdir()
            external.rename(loose_ref)

    def test_rejects_linked_packed_refs_metadata(self):
        repository, source_commit, _ = self.createRepository("linked-packed-refs")
        self.runGit(
            repository,
            "tag",
            "-a",
            BASELINE_TAG,
            source_commit,
            "-m",
            TAG_MESSAGE,
        )
        self.runGit(repository, "pack-refs", "--all")
        packed_refs = repository / ".git" / "packed-refs"
        external = self.test_root / "external-packed-refs"
        packed_refs.rename(external)
        try:
            try:
                packed_refs.symlink_to(external)
            except OSError as error:
                external.rename(packed_refs)
                self.skipTest(f"file symlink creation is unavailable: {error}")
            self.assertTagInvalid(
                repository,
                source_commit,
                "baseline tag ref metadata is unsafe",
            )
        finally:
            if packed_refs.is_symlink():
                packed_refs.unlink()
            if external.exists():
                external.rename(packed_refs)

        packed_refs.rename(external)
        packed_refs.mkdir()
        try:
            self.assertTagInvalid(
                repository,
                source_commit,
                "baseline tag ref metadata is unsafe",
            )
        finally:
            packed_refs.rmdir()
            external.rename(packed_refs)

    def test_accepts_hardlinked_loose_and_packed_tag_metadata(self):
        repository, source_commit, _ = self.createRepository("hardlinked-tag-ref")
        self.runGit(
            repository,
            "tag",
            "-a",
            BASELINE_TAG,
            source_commit,
            "-m",
            TAG_MESSAGE,
        )
        loose_ref = repository / ".git" / "refs" / "tags" / BASELINE_TAG
        external_loose = self.test_root / "hardlinked-tag-source"
        loose_ref.rename(external_loose)
        os.link(external_loose, loose_ref)
        try:
            self.validateTag(repository, source_commit)
        finally:
            loose_ref.chmod(0o600)
            loose_ref.unlink()
            external_loose.rename(loose_ref)

        self.runGit(repository, "pack-refs", "--all")
        packed_refs = repository / ".git" / "packed-refs"
        external_packed = self.test_root / "hardlinked-packed-refs-source"
        packed_refs.rename(external_packed)
        os.link(external_packed, packed_refs)
        try:
            self.validateTag(repository, source_commit)
        finally:
            packed_refs.chmod(0o600)
            packed_refs.unlink()
            external_packed.rename(packed_refs)

    def test_rejects_same_identity_loose_tag_content_replaced_during_read(self):
        repository, source_commit, _ = self.createRepository(
            "same-identity-loose-tag"
        )
        self.runGit(
            repository,
            "tag",
            "-a",
            BASELINE_TAG,
            source_commit,
            "-m",
            TAG_MESSAGE,
        )
        replacement_oid = self.createRawTagObject(
            repository,
            source_commit,
            timestamp=1,
        )
        loose_ref = repository / ".git" / "refs" / "tags" / BASELINE_TAG
        sibling = self.test_root / "same-identity-loose-tag-sibling"
        os.link(loose_ref, sibling)
        validator = load_validator()
        real_run_git = validator._run_git
        mutated = False

        def mutate_then_read(root, arguments, check=False):
            nonlocal mutated
            if not mutated:
                overwrite_hardlink_preserving_bound_identity(
                    self,
                    loose_ref,
                    sibling,
                    replacement_oid.encode("ascii") + b"\n",
                )
                mutated = True
            return real_run_git(root, arguments, check=check)

        try:
            with mock.patch.object(
                validator, "_run_git", side_effect=mutate_then_read
            ), self.assertRaises(validator.BaselineValidationError) as caught:
                validator.validate_baseline_tag(
                    repository,
                    BASELINE_TAG,
                    source_commit,
                )
        finally:
            sibling.unlink()
        self.assertTrue(mutated)
        self.assertEqual(
            str(caught.exception),
            "baseline tag ref metadata is unsafe",
        )

    def test_rejects_same_identity_packed_refs_content_replaced_during_read(self):
        repository, source_commit, _ = self.createRepository(
            "same-identity-packed-refs"
        )
        self.runGit(
            repository,
            "tag",
            "-a",
            BASELINE_TAG,
            source_commit,
            "-m",
            TAG_MESSAGE,
        )
        original_oid = self.runGit(
            repository,
            "rev-parse",
            f"refs/tags/{BASELINE_TAG}",
        ).stdout.strip()
        replacement_oid = self.createRawTagObject(
            repository,
            source_commit,
            timestamp=1,
        ).encode("ascii")
        self.runGit(repository, "pack-refs", "--all")
        packed_refs = repository / ".git" / "packed-refs"
        original_raw = packed_refs.read_bytes()
        replacement_raw = original_raw.replace(
            original_oid.encode("ascii"),
            replacement_oid,
            1,
        )
        self.assertNotEqual(replacement_raw, original_raw)
        sibling = self.test_root / "same-identity-packed-refs-sibling"
        os.link(packed_refs, sibling)
        validator = load_validator()
        real_run_git = validator._run_git
        mutated = False

        def mutate_then_read(root, arguments, check=False):
            nonlocal mutated
            if not mutated:
                overwrite_hardlink_preserving_bound_identity(
                    self,
                    packed_refs,
                    sibling,
                    replacement_raw,
                )
                mutated = True
            return real_run_git(root, arguments, check=check)

        try:
            with mock.patch.object(
                validator, "_run_git", side_effect=mutate_then_read
            ), self.assertRaises(validator.BaselineValidationError) as caught:
                validator.validate_baseline_tag(
                    repository,
                    BASELINE_TAG,
                    source_commit,
                )
        finally:
            sibling.unlink()
        self.assertTrue(mutated)
        self.assertEqual(
            str(caught.exception),
            "baseline tag ref metadata is unsafe",
        )

    def test_accepts_tag_metadata_from_linked_worktree_common_directory(self):
        repository, source_commit, _ = self.createRepository("linked-tag-common")
        self.runGit(
            repository,
            "tag",
            "-a",
            BASELINE_TAG,
            source_commit,
            "-m",
            TAG_MESSAGE,
        )
        linked = self.test_root / "linked-tag-worktree"
        self.runGit(
            repository,
            "worktree",
            "add",
            "-b",
            "linked-tag-worktree",
            str(linked),
            source_commit,
        )
        try:
            self.validateTag(linked, source_commit)
        finally:
            self.runGit(
                repository,
                "worktree",
                "remove",
                "--force",
                str(linked),
                check=False,
            )

    def test_rejects_reparse_tag_ref_metadata_before_git_reads(self):
        repository, source_commit, _ = self.createRepository("reparse-tag-ref")
        self.runGit(
            repository,
            "tag",
            "-a",
            BASELINE_TAG,
            source_commit,
            "-m",
            TAG_MESSAGE,
        )
        loose_ref = repository / ".git" / "refs" / "tags" / BASELINE_TAG
        real_status = loose_ref.lstat()
        reparse_status = SimpleNamespace(
            st_mode=real_status.st_mode,
            st_file_attributes=getattr(
                stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400
            ),
        )
        real_lstat = Path.lstat

        def reparse_lstat(path):
            if path == loose_ref:
                return reparse_status
            return real_lstat(path)

        validator = load_validator()
        with mock.patch.object(
            Path, "lstat", autospec=True, side_effect=reparse_lstat
        ), mock.patch.object(validator, "_run_git") as run_git:
            with self.assertRaises(validator.BaselineValidationError) as caught:
                validator.validate_baseline_tag(
                    repository, BASELINE_TAG, source_commit
                )
        self.assertEqual(
            str(caught.exception), "baseline tag ref metadata is unsafe"
        )
        run_git.assert_not_called()

    def test_rejects_invalid_tag_metadata_path_without_reflection(self):
        validator = load_validator()
        for tag_name in ("../escape", "bad\\path", "lone-\ud800"):
            with self.subTest(tag_name=repr(tag_name)):
                with self.assertRaises(
                    validator.BaselineValidationError
                ) as caught:
                    validator.validate_baseline_tag(
                        Path("repository"), tag_name, SOURCE_COMMIT
                    )
                self.assertEqual(
                    str(caught.exception), "baseline tag ref metadata is unsafe"
                )
                self.assertNotIn("escape", str(caught.exception))
                self.assertNotIn("surrogate", str(caught.exception))

    def test_tag_lookup_is_scoped_to_the_exact_casefold_identity(self):
        repository, source_commit, _ = self.createRepository("scoped-tag-lookup")
        self.runGit(
            repository,
            "tag",
            "-a",
            BASELINE_TAG,
            source_commit,
            "-m",
            TAG_MESSAGE,
        )
        validator = load_validator()
        real_run_git = validator._run_git
        calls = []

        def recording_run_git(repository_root, arguments, check=False):
            calls.append(tuple(arguments))
            return real_run_git(repository_root, arguments, check=check)

        with mock.patch.object(
            validator, "_run_git", side_effect=recording_run_git
        ):
            validator.validate_baseline_tag(
                repository, BASELINE_TAG, source_commit
            )

        for arguments in calls:
            if arguments and arguments[0] == "for-each-ref":
                self.assertNotEqual(arguments[-1], "refs/tags")
                self.assertEqual(arguments[-1], f"refs/tags/{BASELINE_TAG}")

    def test_git_fixture_ignores_ambient_commit_and_tag_signing(self):
        with mock.patch.dict(os.environ, GIT_SIGNING_POLLUTION, clear=False):
            repository, source_commit, _ = self.createRepository(
                "signing-pollution"
            )
            self.runGit(
                repository,
                "tag",
                "-a",
                BASELINE_TAG,
                source_commit,
                "-m",
                TAG_MESSAGE,
            )

        self.validateTag(repository, source_commit)

    def test_rejects_case_variant_ref_when_exact_spelling_is_absent(self):
        repository, source_commit, _ = self.createRepository("case-variant")
        tag_object = self.createRawTagObject(repository, source_commit)
        self.runGit(
            repository,
            "update-ref",
            f"refs/tags/{BASELINE_TAG.upper()}",
            tag_object,
        )

        self.assertTagInvalid(
            repository,
            source_commit,
            "baseline tag ref is not stored with exact canonical spelling",
        )

    def test_rejects_casefold_collision_even_when_exact_ref_is_enumerated(self):
        validator = load_validator()
        expected_ref = f"refs/tags/{BASELINE_TAG}"
        enumerated = SimpleNamespace(
            returncode=0,
            stdout=f"{expected_ref}\n{expected_ref.upper()}\n".encode("ascii"),
            stderr=b"",
        )
        with mock.patch.object(
            validator, "bind_tag_refs", return_value=object()
        ), mock.patch.object(
            validator, "verify_binding"
        ), mock.patch.object(
            validator, "_run_git", return_value=enumerated
        ):
            with self.assertRaises(validator.BaselineValidationError) as caught:
                validator.validate_baseline_tag(
                    Path("repository"), BASELINE_TAG, SOURCE_COMMIT
                )
        self.assertEqual(
            str(caught.exception),
            "baseline tag ref is not stored with exact canonical spelling",
        )

    def test_rejects_symbolic_expected_tag_ref(self):
        repository, source_commit, _ = self.createRepository("symbolic")
        tag_object = self.createRawTagObject(repository, source_commit)
        target_ref = "refs/tags/symbolic-target"
        self.runGit(repository, "update-ref", target_ref, tag_object)
        self.runGit(
            repository,
            "symbolic-ref",
            f"refs/tags/{BASELINE_TAG}",
            target_ref,
        )

        self.assertTagInvalid(
            repository,
            source_commit,
            "baseline tag ref must not be symbolic",
        )

    def test_rejects_tag_object_with_different_internal_tag_name(self):
        repository, source_commit, _ = self.createRepository("internal-name")
        tag_object = self.createRawTagObject(
            repository,
            source_commit,
            internal_name="different-name",
        )
        self.runGit(
            repository,
            "update-ref",
            f"refs/tags/{BASELINE_TAG}",
            tag_object,
        )

        self.assertTagInvalid(
            repository,
            source_commit,
            "baseline tag object content does not match the approved source baseline",
        )

    def test_rejects_wrong_extra_and_signed_tag_messages(self):
        messages = (
            "wrong message",
            f"{TAG_MESSAGE}\nextra body",
            f"{TAG_MESSAGE}\n-----BEGIN PGP SIGNATURE-----\nhostile",
        )
        for index, message in enumerate(messages):
            with self.subTest(message=message):
                repository, source_commit, _ = self.createRepository(
                    f"message-{index}"
                )
                tag_object = self.createRawTagObject(
                    repository,
                    source_commit,
                    message=message,
                )
                self.runGit(
                    repository,
                    "update-ref",
                    f"refs/tags/{BASELINE_TAG}",
                    tag_object,
                )
                self.assertTagInvalid(
                    repository,
                    source_commit,
                    "baseline tag object content does not match the approved source baseline",
                )

    def test_rejects_taggers_that_fail_git_strict_validation(self):
        invalid_taggers = (
            "tagger x",
            "tagger Baseline Tests 0 +0000",
            "tagger Baseline Tests <baseline-tests@example.invalid> bad +0000",
            "tagger Baseline Tests <baseline-tests@example.invalid> 0 +0x00",
            "tagger Baseline Tests <baseline-tests@example.invalid> 00 +0000",
            "tagger Baseline Tests <baseline-tests@example.invalid> 0001 +0000",
        )
        for index, tagger_line in enumerate(invalid_taggers):
            with self.subTest(tagger_line=tagger_line):
                repository, source_commit, _ = self.createRepository(
                    f"strict-tagger-{index}"
                )
                tag_object = self.createUncheckedTagObject(
                    repository, source_commit, tagger_line
                )
                self.runGit(
                    repository,
                    "update-ref",
                    f"refs/tags/{BASELINE_TAG}",
                    tag_object,
                )
                self.assertTagInvalid(
                    repository,
                    source_commit,
                    "baseline tag object has an invalid tagger identity",
                )

    def test_accepts_ordinary_unsigned_tag_with_unicode_name(self):
        repository, source_commit, _ = self.createRepository("unicode-tagger")
        self.runGit(
            repository,
            "-c",
            "user.name=迁移 基线",
            "-c",
            "user.email=unicode@example.invalid",
            "tag",
            "--no-sign",
            "-a",
            BASELINE_TAG,
            source_commit,
            "-m",
            TAG_MESSAGE,
        )

        self.validateTag(repository, source_commit)

    def test_closed_tagger_parser_rejects_non_utf8_controls_and_bad_fields(self):
        validator = load_validator()
        invalid_lines = (
            b"tagger Name <mail@example.invalid> 0 +0000\xff",
            b"tagger Na\x00me <mail@example.invalid> 0 +0000",
            b"tagger Name\tTab <mail@example.invalid> 0 +0000",
            "tagger Name\u0085Control <mail@example.invalid> 0 +0000".encode(
                "utf-8"
            ),
            b"tagger Name <mail address@example.invalid> 0 +0000",
            b"tagger Name <mail@example.invalid> 00 +0000",
            b"tagger Name <mail@example.invalid> 0001 +0000",
            b"tagger Name <mail@example.invalid> 12345678901234567890 +0000",
            b"tagger Name <mail@example.invalid> 0 +1460",
            b"tagger Name <mail@example.invalid> 0 +1500",
        )
        for line in invalid_lines:
            with self.subTest(line=line):
                with self.assertRaises(
                    validator.BaselineValidationError
                ) as caught:
                    validator._validate_tag_tagger_line(line)
                self.assertEqual(
                    str(caught.exception),
                    "baseline tag object has an invalid tagger identity",
                )

    def test_closed_tagger_parser_accepts_unicode_name_and_timezone_bounds(self):
        validator = load_validator()
        valid_lines = (
            "tagger 迁移 基线 <unicode@example.invalid> 0 +0000",
            "tagger Example Name <name@example.invalid> 1 -1200",
            "tagger Example Name <name@example.invalid> 9223372036854775807 +1400",
        )
        for line in valid_lines:
            with self.subTest(line=line):
                validator._validate_tag_tagger_line(line.encode("utf-8"))

    def test_require_tag_cli_rejects_zero_padded_timestamps(self):
        template = self.createHostileCloneTemplate("zero-padded-template")
        with mock.patch.dict(
            os.environ,
            {"GIT_TEMPLATE_DIR": str(template)},
            clear=False,
        ):
            repository = self.cloneCurrentRepository("zero-padded-cli")
        for timestamp in ("00", "0001"):
            with self.subTest(timestamp=timestamp):
                tag_object = self.createUncheckedTagObject(
                    repository,
                    SOURCE_COMMIT,
                    "tagger Baseline Tests <baseline-tests@example.invalid> "
                    f"{timestamp} +0000",
                )
                self.runGit(
                    repository,
                    "update-ref",
                    f"refs/tags/{BASELINE_TAG}",
                    tag_object,
                )
                result = subprocess.run(
                    [
                        sys.executable,
                        str(repository / "tools" / "validate_migration_baseline.py"),
                        "--require-tag",
                    ],
                    cwd=repository,
                    capture_output=True,
                    text=True,
                    shell=False,
                    check=False,
                )
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
                self.assertEqual(
                    result.stderr,
                    "migration baseline validation failed: baseline tag object "
                    "has an invalid tagger identity\n",
                )
                self.assertNotIn("Traceback", result.stderr)

    def test_strict_validation_is_scoped_and_does_not_write_repository_state(self):
        repository, source_commit, _ = self.createRepository("strict-read-only")
        self.createUncheckedTagObject(repository, source_commit, "tagger x")
        approved_tag_object = self.createRawTagObject(repository, source_commit)
        self.runGit(
            repository,
            "update-ref",
            f"refs/tags/{BASELINE_TAG}",
            approved_tag_object,
        )

        git_directory = repository / ".git"

        def repository_snapshot():
            snapshot = {}
            for path in git_directory.rglob("*"):
                if path.is_file():
                    status = path.stat()
                    snapshot[path.relative_to(git_directory).as_posix()] = (
                        status.st_size,
                        status.st_mtime_ns,
                        path.read_bytes(),
                    )
            return snapshot

        before = repository_snapshot()
        self.validateTag(repository, source_commit)
        after = repository_snapshot()

        changed_paths = {
            path: (
                before.get(path, (None, None, b""))[:2],
                after.get(path, (None, None, b""))[:2],
            )
            for path in set(before) | set(after)
            if before.get(path) != after.get(path)
        }
        self.assertEqual(changed_paths, {})

    def test_rejects_oversized_tag_before_reading_the_object(self):
        repository, source_commit, _ = self.createRepository("oversized")
        tag_object = self.createRawTagObject(
            repository,
            source_commit,
            message="x" * (5 * 1024 * 1024),
        )
        self.runGit(
            repository,
            "update-ref",
            f"refs/tags/{BASELINE_TAG}",
            tag_object,
        )
        validator = load_validator()
        real_run_git = validator._run_git
        calls = []

        def recording_run_git(repository_root, arguments, check=False):
            calls.append(list(arguments))
            return real_run_git(repository_root, arguments, check=check)

        with mock.patch.object(
            validator, "_run_git", side_effect=recording_run_git
        ):
            with self.assertRaises(validator.BaselineValidationError) as caught:
                validator.validate_baseline_tag(
                    repository, BASELINE_TAG, source_commit
                )
        self.assertEqual(
            str(caught.exception),
            f"baseline tag object exceeds {MAX_TAG_OBJECT_BYTES}-byte limit",
        )
        self.assertIn(
            ["cat-file", "-s", tag_object], calls
        )
        self.assertNotIn(
            ["cat-file", "tag", tag_object], calls
        )

    def test_replace_ref_cannot_change_the_tag_object_or_peeled_commit(self):
        repository, source_commit, descendant_commit = self.createRepository("replace")
        self.runGit(
            repository,
            "tag",
            "-a",
            BASELINE_TAG,
            source_commit,
            "-m",
            TAG_MESSAGE,
        )
        self.runGit(
            repository,
            "tag",
            "-a",
            "replacement-tag",
            descendant_commit,
            "-m",
            "hostile replacement",
        )
        baseline_tag_object = self.runGit(
            repository, "rev-parse", f"refs/tags/{BASELINE_TAG}"
        ).stdout.strip()
        replacement_tag_object = self.runGit(
            repository, "rev-parse", "refs/tags/replacement-tag"
        ).stdout.strip()
        self.runGit(
            repository,
            "update-ref",
            f"refs/replace/{baseline_tag_object}",
            replacement_tag_object,
        )
        unprotected_environment = os.environ.copy()
        unprotected_environment.pop("GIT_NO_REPLACE_OBJECTS", None)
        self.assertEqual(
            self.runGit(
                repository,
                "rev-parse",
                f"refs/tags/{BASELINE_TAG}^{{}}",
                environment=unprotected_environment,
            ).stdout.strip(),
            descendant_commit,
        )

        self.validateTag(repository, source_commit)

    def test_tag_validation_checks_size_before_bounded_content_read(self):
        repository, source_commit, _ = self.createRepository("command-order")
        tag_object = self.createRawTagObject(repository, source_commit)
        self.runGit(
            repository,
            "update-ref",
            f"refs/tags/{BASELINE_TAG}",
            tag_object,
        )
        validator = load_validator()
        real_run_git = validator._run_git
        calls = []

        def recording_run_git(repository_root, arguments, check=False):
            calls.append(list(arguments))
            return real_run_git(repository_root, arguments, check=check)

        with mock.patch.object(
            validator, "_run_git", side_effect=recording_run_git
        ):
            validator.validate_baseline_tag(
                repository, BASELINE_TAG, source_commit
            )

        tag_ref = f"refs/tags/{BASELINE_TAG}"
        self.assertEqual(
            calls,
            [
                [
                    "for-each-ref",
                    "--count=3",
                    "--ignore-case",
                    "--format=%(refname)",
                    tag_ref,
                ],
                ["symbolic-ref", "-q", tag_ref],
                ["cat-file", "-t", tag_ref],
                ["rev-parse", f"{tag_ref}^{{}}"],
                ["rev-parse", "--verify", tag_ref],
                ["cat-file", "-s", tag_object],
                ["cat-file", "tag", tag_object],
            ],
        )

    def test_rejects_invalid_size_and_content_length_with_stable_diagnostics(self):
        repository, source_commit, _ = self.createRepository("corrupt-read")
        tag_object = self.createRawTagObject(repository, source_commit)
        self.runGit(
            repository,
            "update-ref",
            f"refs/tags/{BASELINE_TAG}",
            tag_object,
        )
        validator = load_validator()
        real_run_git = validator._run_git
        hostile = b"invalid-size\n\x1b[31m"

        def invalid_size(repository_root, arguments, check=False):
            if arguments == ["cat-file", "-s", tag_object]:
                return SimpleNamespace(returncode=0, stdout=hostile, stderr=hostile)
            return real_run_git(repository_root, arguments, check=check)

        with mock.patch.object(validator, "_run_git", side_effect=invalid_size):
            with self.assertRaises(validator.BaselineValidationError) as caught:
                validator.validate_baseline_tag(
                    repository, BASELINE_TAG, source_commit
                )
        self.assertEqual(
            str(caught.exception), "baseline tag object size is invalid"
        )
        self.assertNotIn("invalid-size", str(caught.exception))

        def truncated_content(repository_root, arguments, check=False):
            result = real_run_git(repository_root, arguments, check=check)
            if arguments == ["cat-file", "tag", tag_object]:
                return SimpleNamespace(
                    returncode=0,
                    stdout=result.stdout[:-1],
                    stderr=b"",
                )
            return result

        with mock.patch.object(
            validator, "_run_git", side_effect=truncated_content
        ):
            with self.assertRaises(validator.BaselineValidationError) as caught:
                validator.validate_baseline_tag(
                    repository, BASELINE_TAG, source_commit
                )
        self.assertEqual(
            str(caught.exception),
            "baseline tag object length does not match Git metadata",
        )

    def test_rejects_annotated_tag_that_points_to_another_tag_object(self):
        repository, source_commit, _ = self.createRepository("nested")
        self.runGit(
            repository,
            "tag",
            "-a",
            "inner-baseline",
            source_commit,
            "-m",
            "inner",
        )
        inner_object = self.runGit(
            repository, "rev-parse", "refs/tags/inner-baseline"
        ).stdout.strip()
        outer_input = (
            f"object {inner_object}\n"
            "type tag\n"
            f"tag {BASELINE_TAG}\n"
            "tagger Baseline Tests <baseline-tests@example.invalid> 0 +0000\n"
            "\nouter\n"
        ).encode("utf-8")
        outer_object = self.runGit(
            repository, "mktag", input_bytes=outer_input
        ).stdout.strip()
        self.runGit(
            repository,
            "update-ref",
            f"refs/tags/{BASELINE_TAG}",
            outer_object,
        )

        self.assertTagInvalid(
            repository,
            source_commit,
            "baseline tag does not directly reference the source commit",
        )

    def test_tag_diagnostics_do_not_echo_untrusted_git_output(self):
        validator = load_validator()
        hostile = b"hostile\n\x1b[31mspoof"
        failed = SimpleNamespace(returncode=17, stdout=hostile, stderr=hostile)
        with mock.patch.object(
            validator, "bind_tag_refs", return_value=object()
        ), mock.patch.object(
            validator, "verify_binding"
        ), mock.patch.object(
            validator, "_run_git", return_value=failed
        ):
            with self.assertRaises(validator.BaselineValidationError) as caught:
                validator.validate_baseline_tag(Path("repository"), BASELINE_TAG, SOURCE_COMMIT)
        self.assertEqual(
            str(caught.exception),
            "baseline tag refs could not be enumerated",
        )
        self.assertNotIn("hostile", str(caught.exception))

    def test_tag_validation_uses_an_injected_runner_exclusively(self):
        validator = load_validator()
        repository, source_commit, _ = self.createRepository("injected-runner")
        self.runGit(
            repository,
            "tag",
            "-a",
            BASELINE_TAG,
            source_commit,
            "-m",
            TAG_MESSAGE,
        )
        original_runner = validator._run_git
        calls = []

        def injected(root, arguments):
            calls.append((Path(root).resolve(), tuple(arguments)))
            return original_runner(root, arguments)

        with mock.patch.object(
            validator,
            "_run_git",
            side_effect=AssertionError("injected validation must not use module runner"),
        ):
            validator.validate_baseline_tag(
                repository,
                BASELINE_TAG,
                source_commit,
                run_git=injected,
            )

        self.assertGreaterEqual(len(calls), 7)
        self.assertTrue(all(root == repository.resolve() for root, _args in calls))

    def test_cli_rejects_extra_arguments_with_argparse_usage_status(self):
        result = subprocess.run(
            [sys.executable, str(VALIDATOR_PATH), "unexpected"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            shell=False,
            check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertIn("usage:", result.stderr)
        self.assertIn("error: invalid command-line arguments", result.stderr)
        self.assertNotIn("unexpected", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_cli_does_not_echo_control_characters_from_unknown_arguments(self):
        hostile_argument = "hostile\n\x1b[31mspoofed"
        result = subprocess.run(
            [sys.executable, str(VALIDATOR_PATH), hostile_argument],
            cwd=ROOT,
            capture_output=True,
            text=True,
            shell=False,
            check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertIn("usage:", result.stderr)
        self.assertIn("error: invalid command-line arguments", result.stderr)
        self.assertNotIn("hostile", result.stderr)
        self.assertNotIn("spoofed", result.stderr)
        self.assertNotIn("\x1b", result.stderr)

    def test_cli_does_not_accept_abbreviated_require_tag_option(self):
        result = subprocess.run(
            [sys.executable, str(VALIDATOR_PATH), "--require-t"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            shell=False,
            check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertIn("usage:", result.stderr)
        self.assertIn("error: invalid command-line arguments", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_import_does_not_change_global_bytecode_policy(self):
        original = sys.dont_write_bytecode
        try:
            sys.dont_write_bytecode = False
            namespace = {
                "__file__": str(VALIDATOR_PATH),
                "__name__": "validate_migration_baseline_import_probe",
            }
            source = VALIDATOR_PATH.read_text(encoding="utf-8")
            exec(compile(source, str(VALIDATOR_PATH), "exec"), namespace)
            self.assertIs(sys.dont_write_bytecode, False)
        finally:
            sys.dont_write_bytecode = original


class MigrationBaselineReviewedFileTests(unittest.TestCase):
    GIT_IDENTITY = (
        "-c",
        "user.name=Mac-Win Baseline Tests",
        "-c",
        "user.email=baseline-tests@example.invalid",
        "-c",
        "commit.gpgSign=false",
        "-c",
        "tag.gpgSign=false",
        "-c",
        "core.autocrlf=false",
    )
    RELATIVE_PATH = "reviewed.txt"
    APPROVED_TEXT = "approved baseline\n"
    MAXIMUM_BYTES = 64

    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.test_root = Path(self.temporary_directory.name)

    def runGit(
        self,
        repository,
        *arguments,
        input_bytes=None,
        check=True,
    ):
        result = run_fixture_git(
            repository,
            *arguments,
            configuration=self.GIT_IDENTITY,
            input_bytes=input_bytes,
        )
        if check and result.returncode != 0:
            stdout = result.stdout
            stderr = result.stderr
            self.fail(
                f"Git fixture command failed ({result.returncode}): "
                f"{arguments!r}\nstdout: {stdout!r}\nstderr: {stderr!r}"
            )
        return result

    def createRepository(self, name="target", relative_path=None):
        if relative_path is None:
            relative_path = self.RELATIVE_PATH
        repository = self.test_root / name
        self.runGit(repository, "init", "-b", "main")
        reviewed = repository / Path(relative_path)
        reviewed.parent.mkdir(parents=True, exist_ok=True)
        reviewed.write_text(self.APPROVED_TEXT, encoding="utf-8", newline="")
        self.runGit(repository, "add", relative_path)
        self.runGit(repository, "commit", "-m", "reviewed baseline")
        oid = self.runGit(
            repository, "rev-parse", f"HEAD:{relative_path}"
        ).stdout.strip()
        return repository, reviewed, oid

    def writeBlob(self, repository, raw):
        result = self.runGit(
            repository,
            "hash-object",
            "-w",
            "--stdin",
            input_bytes=raw,
        )
        return result.stdout.decode("ascii").strip()

    def setIndexEntry(self, repository, mode, oid, *, info_only=False):
        arguments = ["update-index"]
        if info_only:
            arguments.append("--info-only")
        arguments.extend(
            ["--add", "--cacheinfo", mode, oid, self.RELATIVE_PATH]
        )
        self.runGit(repository, *arguments)

    def readReviewed(self, repository, validator=None, **overrides):
        if validator is None:
            validator = load_validator()
        arguments = {
            "repository_root": repository,
            "relative_path": self.RELATIVE_PATH,
            "expected_text": self.APPROVED_TEXT,
            "maximum_bytes": self.MAXIMUM_BYTES,
        }
        arguments.update(overrides)
        return validator.read_reviewed_text(**arguments)

    def assertReviewedInvalid(self, repository, diagnostic, **overrides):
        validator = load_validator()
        with self.assertRaises(validator.BaselineValidationError) as caught:
            self.readReviewed(repository, validator=validator, **overrides)
        self.assertEqual(str(caught.exception), diagnostic)

    def test_accepts_regular_stage_zero_file_and_reads_blob_type_size_first(self):
        repository, _, oid = self.createRepository()
        validator = load_validator()
        real_run_git = validator._run_git
        calls = []

        def recording_run_git(repository_root, arguments, check=False):
            calls.append(list(arguments))
            return real_run_git(repository_root, arguments, check=check)

        with mock.patch.object(
            validator, "_run_git", side_effect=recording_run_git
        ):
            text = validator.read_reviewed_text(
                repository,
                self.RELATIVE_PATH,
                self.APPROVED_TEXT,
                self.MAXIMUM_BYTES,
            )

        self.assertEqual(text, self.APPROVED_TEXT)
        self.assertEqual(
            calls,
            [
                ["ls-files", "--stage", "-z", "--", self.RELATIVE_PATH],
                ["ls-files", "--debug", "-z", "--", self.RELATIVE_PATH],
                ["cat-file", "-t", oid],
                ["cat-file", "-s", oid],
                ["cat-file", "blob", oid],
            ],
        )

    def test_git_fixture_ignores_ambient_commit_signing(self):
        with mock.patch.dict(os.environ, GIT_SIGNING_POLLUTION, clear=False):
            repository, _, oid = self.createRepository("signing-pollution")

        self.assertEqual(
            self.runGit(
                repository,
                "rev-parse",
                f"HEAD:{self.RELATIVE_PATH}",
            ).stdout.strip(),
            oid,
        )

    def test_accepts_crlf_worktree_equivalent(self):
        repository, reviewed, _ = self.createRepository()
        reviewed.write_bytes(self.APPROVED_TEXT.replace("\n", "\r\n").encode())

        self.assertEqual(self.readReviewed(repository), self.APPROVED_TEXT)

    def test_accepts_regular_hardlink(self):
        repository, reviewed, _ = self.createRepository()
        hardlink_source = repository / "hardlink-source.txt"
        hardlink_source.write_text(self.APPROVED_TEXT, encoding="utf-8", newline="")
        reviewed.unlink()
        os.link(hardlink_source, reviewed)

        self.assertEqual(self.readReviewed(repository), self.APPROVED_TEXT)

    def test_rejects_linked_and_nonregular_index_metadata(self):
        repository, _, _ = self.createRepository("linked-index")
        index = repository / ".git" / "index"
        external = self.test_root / "external-index"
        index.rename(external)
        try:
            try:
                index.symlink_to(external)
            except OSError as error:
                external.rename(index)
                self.skipTest(f"file symlink creation is unavailable: {error}")
            self.assertReviewedInvalid(
                repository,
                "reviewed file index metadata is unsafe",
            )
        finally:
            if index.is_symlink():
                index.unlink()
            if external.exists():
                external.rename(index)

        index.rename(external)
        index.mkdir()
        try:
            self.assertReviewedInvalid(
                repository,
                "reviewed file index metadata is unsafe",
            )
        finally:
            index.rmdir()
            external.rename(index)

    def test_accepts_hardlinked_index_metadata(self):
        repository, _, _ = self.createRepository("hardlinked-index")
        index = repository / ".git" / "index"
        external = self.test_root / "hardlinked-index-source"
        index.rename(external)
        os.link(external, index)
        try:
            self.assertEqual(self.readReviewed(repository), self.APPROVED_TEXT)
        finally:
            index.chmod(0o600)
            index.unlink()
            external.rename(index)

    def test_rejects_same_identity_index_content_replaced_during_read(self):
        repository, _, _ = self.createRepository("same-identity-index")
        index = repository / ".git" / "index"
        original = index.read_bytes()
        self.assertGreater(len(original), 32)
        replacement = bytearray(original)
        replacement[12:16] = (
            (int.from_bytes(replacement[12:16], "big") + 1) % (2**32)
        ).to_bytes(4, "big")
        replacement[-20:] = hashlib.sha1(replacement[:-20]).digest()
        self.assertNotEqual(bytes(replacement), original)
        sibling = self.test_root / "same-identity-index-sibling"
        os.link(index, sibling)
        validator = load_validator()
        real_run_git = validator._run_git
        mutated = False

        def mutate_then_read(root, arguments, check=False):
            nonlocal mutated
            if not mutated:
                overwrite_hardlink_preserving_bound_identity(
                    self,
                    index,
                    sibling,
                    bytes(replacement),
                )
                mutated = True
            return real_run_git(root, arguments, check=check)

        try:
            with mock.patch.object(
                validator, "_run_git", side_effect=mutate_then_read
            ), self.assertRaises(validator.BaselineValidationError) as caught:
                self.readReviewed(repository, validator=validator)
        finally:
            sibling.unlink()
        self.assertTrue(mutated)
        self.assertEqual(
            str(caught.exception),
            "reviewed file index metadata is unsafe",
        )

    def test_rejects_reparse_index_metadata_before_git_reads(self):
        repository, _, _ = self.createRepository("reparse-index")
        index = repository / ".git" / "index"
        real_status = index.lstat()
        reparse_status = SimpleNamespace(
            st_mode=real_status.st_mode,
            st_file_attributes=getattr(
                stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400
            ),
        )
        real_lstat = Path.lstat

        def reparse_lstat(path):
            if path == index:
                return reparse_status
            return real_lstat(path)

        validator = load_validator()
        with mock.patch.object(
            Path, "lstat", autospec=True, side_effect=reparse_lstat
        ), mock.patch.object(validator, "_run_git") as run_git:
            with self.assertRaises(validator.BaselineValidationError) as caught:
                self.readReviewed(repository, validator=validator)
        self.assertEqual(
            str(caught.exception), "reviewed file index metadata is unsafe"
        )
        run_git.assert_not_called()

    def test_rejects_symlink_and_non_regular_worktree_inputs(self):
        repository, reviewed, _ = self.createRepository("symlink")
        target = repository / "symlink-target.txt"
        target.write_text(self.APPROVED_TEXT, encoding="utf-8", newline="")
        reviewed.unlink()
        try:
            reviewed.symlink_to(target.name)
        except OSError as error:
            self.skipTest(f"symlink creation is unavailable: {error}")
        self.assertReviewedInvalid(
            repository,
            "reviewed working-tree input must be a regular non-reparse file",
        )

        repository, reviewed, _ = self.createRepository("directory")
        reviewed.unlink()
        reviewed.mkdir()
        self.assertReviewedInvalid(
            repository,
            "reviewed working-tree input must be a regular non-reparse file",
        )

    def test_rejects_windows_reparse_attribute_before_reading(self):
        repository, reviewed, _ = self.createRepository()
        real_status = reviewed.lstat()
        reparse_status = SimpleNamespace(
            st_mode=real_status.st_mode,
            st_file_attributes=getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400),
        )
        validator = load_validator()
        real_lstat = Path.lstat

        def leaf_reparse_lstat(path):
            if path == reviewed:
                return reparse_status
            return real_lstat(path)

        with mock.patch.object(
            Path, "lstat", autospec=True, side_effect=leaf_reparse_lstat
        ):
            with self.assertRaises(validator.BaselineValidationError) as caught:
                validator.read_reviewed_text(
                    repository,
                    self.RELATIVE_PATH,
                    self.APPROVED_TEXT,
                    self.MAXIMUM_BYTES,
                )
        self.assertEqual(
            str(caught.exception),
            "reviewed working-tree input must be a regular non-reparse file",
        )

    def test_rejects_parent_directory_symlink_to_outside_repository(self):
        relative_path = "reviewed-parent/reviewed.txt"
        repository, reviewed, _ = self.createRepository(
            "parent-symlink", relative_path=relative_path
        )
        external_parent = self.test_root / "external-reviewed-parent"
        external_parent.mkdir()
        (external_parent / reviewed.name).write_text(
            self.APPROVED_TEXT, encoding="utf-8", newline=""
        )
        shutil.rmtree(reviewed.parent)
        reviewed.parent.symlink_to(external_parent, target_is_directory=True)

        self.assertReviewedInvalid(
            repository,
            "reviewed path components must not be symlinks or reparse points",
            relative_path=relative_path,
        )

    def test_rejects_absolute_parent_and_dotdot_reviewed_paths(self):
        repository, _, _ = self.createRepository()
        for relative_path in (
            str((repository / self.RELATIVE_PATH).resolve()),
            "../reviewed.txt",
            "reviewed-parent/../reviewed.txt",
        ):
            with self.subTest(relative_path=relative_path):
                self.assertReviewedInvalid(
                    repository,
                    "reviewed file path is not repository-relative",
                    relative_path=relative_path,
                )

    def test_rejects_windows_qualified_rooted_unc_and_colon_paths_directly(self):
        validator = load_validator()
        unsafe_paths = (
            "C:escape.txt",
            "C:/escape.txt",
            "nested/C:escape.txt",
            "nested/file:stream",
            "C:",
            r"C:\escape.txt",
            r"\rooted\escape.txt",
            r"\\server\share\escape.txt",
            "//server/share/escape.txt",
        )

        for relative_path in unsafe_paths:
            with self.subTest(relative_path=relative_path):
                with self.assertRaises(
                    validator.BaselineValidationError
                ) as caught:
                    validator._reviewed_relative_path(relative_path)
                self.assertEqual(
                    str(caught.exception),
                    "reviewed file path is not repository-relative",
                )

    @unittest.skipUnless(os.name == "nt", "Windows path semantics only")
    def test_windows_join_semantics_explain_drive_and_stream_escape_risk(self):
        repository, _, _ = self.createRepository()
        drive_absolute = repository / "C:/escape.txt"
        drive_relative = Path("C:escape.txt")
        colon_component = repository / "nested" / "C:escape.txt"

        self.assertEqual(drive_absolute.drive.upper(), "C:")
        self.assertEqual(drive_absolute.root, "\\")
        self.assertFalse(drive_absolute.is_relative_to(repository))
        self.assertEqual(drive_relative.drive.upper(), "C:")
        self.assertEqual(drive_relative.root, "")
        self.assertEqual(colon_component.drive.upper(), "C:")
        self.assertNotIn(":", colon_component.name)

        validator = load_validator()
        for relative_path in (
            "C:/escape.txt",
            "C:escape.txt",
            "nested/C:escape.txt",
        ):
            with self.subTest(relative_path=relative_path):
                with self.assertRaises(validator.BaselineValidationError):
                    validator._reviewed_relative_path(relative_path)

    def test_rejects_non_directory_parent_component(self):
        relative_path = "reviewed-parent/reviewed.txt"
        repository, reviewed, _ = self.createRepository(
            "non-directory-parent", relative_path=relative_path
        )
        shutil.rmtree(reviewed.parent)
        reviewed.parent.write_text("not a directory\n", encoding="utf-8")

        self.assertReviewedInvalid(
            repository,
            "reviewed parent path components must be directories",
            relative_path=relative_path,
        )

    def test_rejects_missing_oversized_and_invalid_utf8_worktree_inputs(self):
        cases = (
            ("missing", None, "reviewed working-tree input is missing"),
            (
                "oversized",
                b"x" * (self.MAXIMUM_BYTES + 1),
                "reviewed working-tree input exceeds 64-byte limit",
            ),
            (
                "invalid-utf8",
                b"approved \xff baseline\n",
                "reviewed working-tree input is not valid UTF-8",
            ),
        )
        for name, raw, diagnostic in cases:
            with self.subTest(name=name):
                repository, reviewed, _ = self.createRepository(name)
                if raw is None:
                    reviewed.unlink()
                else:
                    reviewed.write_bytes(raw)
                self.assertReviewedInvalid(repository, diagnostic)

    def test_wraps_worktree_read_os_errors_with_stable_diagnostic(self):
        repository, _, _ = self.createRepository()
        validator = load_validator()
        hostile_error = OSError("hostile path\n\x1b[31m")

        with mock.patch.object(validator.os, "fdopen", side_effect=hostile_error):
            with self.assertRaises(validator.BaselineValidationError) as caught:
                validator.read_reviewed_text(
                    repository,
                    self.RELATIVE_PATH,
                    self.APPROVED_TEXT,
                    self.MAXIMUM_BYTES,
                )

        self.assertEqual(
            str(caught.exception),
            "reviewed working-tree input could not be read",
        )
        self.assertNotIn("hostile", str(caught.exception))

    def test_rejects_missing_conflicted_and_unexpected_index_entries(self):
        repository, _, oid = self.createRepository("missing-index")
        self.runGit(repository, "rm", "--cached", self.RELATIVE_PATH)
        self.assertReviewedInvalid(
            repository,
            "reviewed file must have one stage-0 index entry",
        )

        repository, _, oid = self.createRepository("conflict")
        index_info = (
            f"100644 {oid} 1\t{self.RELATIVE_PATH}\n"
            f"100644 {oid} 2\t{self.RELATIVE_PATH}\n"
            f"100644 {oid} 3\t{self.RELATIVE_PATH}\n"
        ).encode("ascii")
        self.runGit(repository, "read-tree", "--empty")
        self.runGit(repository, "update-index", "--index-info", input_bytes=index_info)
        self.assertReviewedInvalid(
            repository,
            "reviewed file must have one stage-0 index entry",
        )

    def test_rejects_executable_symlink_and_submodule_index_modes(self):
        repository, _, oid = self.createRepository()
        source_commit = self.runGit(repository, "rev-parse", "HEAD").stdout.strip()
        for mode, object_id in (
            ("100755", oid),
            ("120000", oid),
            ("160000", source_commit),
        ):
            with self.subTest(mode=mode):
                self.setIndexEntry(repository, mode, object_id)
                self.assertReviewedInvalid(
                    repository,
                    "reviewed file index mode must be 100644",
                )

    def test_rejects_intent_to_add_entry(self):
        repository, _, _ = self.createRepository()
        self.runGit(repository, "rm", "--cached", self.RELATIVE_PATH)
        self.runGit(repository, "add", "--intent-to-add", self.RELATIVE_PATH)

        self.assertReviewedInvalid(
            repository,
            "reviewed file index entry must not be intent-to-add",
        )

    def test_rejects_intent_to_add_even_when_empty_blob_content_is_approved(self):
        repository, reviewed, _ = self.createRepository()
        reviewed.write_bytes(b"")
        self.runGit(repository, "rm", "--cached", self.RELATIVE_PATH)
        self.runGit(repository, "add", "--intent-to-add", self.RELATIVE_PATH)

        self.assertReviewedInvalid(
            repository,
            "reviewed file index entry must not be intent-to-add",
            expected_text="",
        )

    def test_rejects_zero_or_malformed_index_object_ids(self):
        repository, _, _ = self.createRepository()
        validator = load_validator()
        outputs = (
            b"100644 " + b"0" * 40 + b" 0\treviewed.txt\0",
            b"100644 not-an-object 0\treviewed.txt\0",
        )
        for output in outputs:
            with self.subTest(output=output):
                result = SimpleNamespace(returncode=0, stdout=output)
                with mock.patch.object(validator, "_run_git", return_value=result):
                    with self.assertRaises(
                        validator.BaselineValidationError
                    ) as caught:
                        validator.read_reviewed_text(
                            repository,
                            self.RELATIVE_PATH,
                            self.APPROVED_TEXT,
                            self.MAXIMUM_BYTES,
                        )
                self.assertEqual(
                    str(caught.exception),
                    "reviewed file index object id is invalid",
                )

    def test_rejects_missing_and_non_blob_index_objects(self):
        repository, _, _ = self.createRepository("missing-object")
        self.setIndexEntry(repository, "100644", "1" * 40, info_only=True)
        self.assertReviewedInvalid(
            repository,
            "reviewed file index object is not a local blob",
        )

        repository, _, _ = self.createRepository("tree-object")
        tree_oid = self.runGit(repository, "rev-parse", "HEAD^{tree}").stdout.strip()
        self.setIndexEntry(repository, "100644", tree_oid)
        self.assertReviewedInvalid(
            repository,
            "reviewed file index object is not a local blob",
        )

    def test_rejects_oversized_and_invalid_utf8_index_blobs(self):
        repository, _, _ = self.createRepository("oversized-blob")
        oversized_oid = self.writeBlob(
            repository, b"x" * (self.MAXIMUM_BYTES + 1)
        )
        self.setIndexEntry(repository, "100644", oversized_oid)
        self.assertReviewedInvalid(
            repository,
            "reviewed file index blob exceeds 64-byte limit",
        )

        repository, _, _ = self.createRepository("invalid-blob")
        invalid_oid = self.writeBlob(repository, b"approved \xff baseline\n")
        self.setIndexEntry(repository, "100644", invalid_oid)
        self.assertReviewedInvalid(
            repository,
            "reviewed file index blob is not valid UTF-8",
        )

    def test_rejects_index_and_worktree_drift_from_approved_content(self):
        repository, reviewed, _ = self.createRepository("worktree-drift")
        reviewed.write_text("changed\n", encoding="utf-8", newline="")
        self.assertReviewedInvalid(
            repository,
            "reviewed working-tree content does not match approved content",
        )

        repository, _, _ = self.createRepository("index-drift")
        changed_oid = self.writeBlob(repository, b"changed\n")
        self.setIndexEntry(repository, "100644", changed_oid)
        self.assertReviewedInvalid(
            repository,
            "reviewed index content does not match approved content",
        )

    def test_rejects_index_blob_length_mismatch_with_stable_diagnostic(self):
        repository, _, oid = self.createRepository()
        validator = load_validator()
        real_run_git = validator._run_git

        def corrupt_blob(repository_root, arguments, check=False):
            result = real_run_git(repository_root, arguments, check=check)
            if arguments == ["cat-file", "blob", oid]:
                return SimpleNamespace(returncode=0, stdout=result.stdout[:-1])
            return result

        with mock.patch.object(validator, "_run_git", side_effect=corrupt_blob):
            with self.assertRaises(validator.BaselineValidationError) as caught:
                validator.read_reviewed_text(
                    repository,
                    self.RELATIVE_PATH,
                    self.APPROVED_TEXT,
                    self.MAXIMUM_BYTES,
                )
        self.assertEqual(
            str(caught.exception),
            "reviewed file index blob length does not match Git metadata",
        )

    def test_git_failure_diagnostic_does_not_echo_untrusted_output(self):
        repository, _, _ = self.createRepository()
        validator = load_validator()
        hostile = b"git-output\n\x1b[31mspoofed diagnostic\x00"
        failed = SimpleNamespace(returncode=17, stdout=hostile, stderr=hostile)

        with mock.patch.object(validator, "_run_git", return_value=failed):
            with self.assertRaises(validator.BaselineValidationError) as caught:
                validator.read_reviewed_text(
                    repository,
                    self.RELATIVE_PATH,
                    self.APPROVED_TEXT,
                    self.MAXIMUM_BYTES,
                )

        self.assertEqual(
            str(caught.exception), "reviewed file index could not be read"
        )
        self.assertNotIn("git-output", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
