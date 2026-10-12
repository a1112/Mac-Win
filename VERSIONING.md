# Mac-Win version management

## Current authority

The existing source/package values below are preserved. They are not a claim that a product is stable or that these source commits were released. Independent applications, libraries, build tools and protocol/schema numbers are not reset to one repository-wide version.

- `product`: `0.1.0` from `MacWinManager/Tools/package-app.sh` (CFBundleShortVersionString); explicit local bump supported. Independent native marketing field.
- `build`: `14` from `MacWinManager/Tools/package-app.sh` (CFBundleVersion); explicit local bump supported. Independent native build field.

The machine-readable inventory is `versioning.json`. Cargo workspace inheritance and local lock entries are bound explicitly. Node lock root fields are distinct from registry dependency versions. Tauri versions are bound to their own package; different frontend numbers remain independent.

## Check and change

Python 3.11 or newer; standard library only. Run from the repository root.

```sh
python3 scripts/native_version_manager.py show
python3 scripts/native_version_manager.py check
python3 scripts/test_versioning.py -v
```

Choose a single unit. Preview is non-mutating; apply is explicit and should always include the observed current value:

```sh
python3 scripts/native_version_manager.py bump patch --unit product
python3 scripts/native_version_manager.py bump patch --unit product --expect 0.1.0 --apply
python3 scripts/native_version_manager.py check
```

Marketing versions are three numeric components; build numbers are separate positive integers. For Apple builds, use `bump build --unit build --expect CURRENT --apply` separately. Neither changes Swift tools, deployment target or SDK versions.

Native field bindings use a SHA-256 fingerprint of the entire source with every configured version span masked together. A packaging/manifest template edit fails closed, including nested PowerShell keys or later Python overrides. Review effective authority and refresh the masked fingerprint in `versioning.json` after a deliberate template edit; never bypass the check.

## Release history and channels

- No release entry was returned in the repository release inventory reviewed on 2026-10-12. Absence here does not prove the project was never distributed.
- Existing tags are retained: `mw-migration-baseline-db12d5e`.
- `migration/baseline.json`, `sourceCommit=db12d5ebc5ba0d5a29c9464d07c1a86ffbc47527` and `mw-migration-baseline-db12d5e` remain immutable historical references. They are not the current application marketing version/build number.

This change creates no tag, release, publication, deployment or release date. Record future changes under Unreleased first; use the existing release process and tag namespace only after platform validation and explicit release approval.

## Scope and validation

The added CI checks metadata consistency and dependency-free version-manager safety only, with `contents: read`. Apply/idempotency/stale-source/mismatch checks use temporary fixtures. They do not establish that a native app builds, signs, installs or works on macOS/Windows/Linux. No native packaging or device acceptance was run for this adoption.

Generated Apple projects, vendored/upstream material, historical evidence, protocol/schema/database numbers and dependency versions remain outside product bumps. Existing runtime version mechanisms are retained; there is no UI redesign.

## Adoption base

Source snapshot: [fix/macos-permission-recovery-2026-10-12 @ 6d2ab2849995](https://github.com/a1112/Mac-Win/commit/6d2ab2849995f80696ea8e7dd2ef22857b5f1488). Default branch `main` and all existing repair/tag refs are retained.

