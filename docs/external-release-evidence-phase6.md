# External Release Evidence Phase 6

Phase 6 makes the remaining five-platform work importable by CI workers and
device runners without weakening the release claim.

## Platform Smoke Import

External macOS, Linux, Windows, iOS, and Android runners must produce platform
smoke manifests for the same git commit. Import them with:

```bash
GENESIS_PLATFORM_SMOKE_MANIFEST=/path/to/linux.json \
GENESIS_PLATFORM_SMOKE_DIR=.genesis-state/autonomous-blueprint/platform-smoke \
  bash scripts/import_platform_smoke_manifest.sh
```

Desktop manifests must use `smoke_kind=desktop_shell_health`. Mobile manifests
must use `smoke_kind=mobile_control_device`. The import script rejects missing
files, wrong platforms, dirty commit mismatches, failed status, and non-real
smoke claims.

## Signing Evidence

Signing and installer jobs must record evidence through:

```bash
GENESIS_RELEASE_SIGNING_KIND=desktop_signing \
GENESIS_RELEASE_SIGNING_ARTIFACT=/path/to/signed-artifact \
GENESIS_RELEASE_SIGNING_VERIFY_CMD='test -s "$GENESIS_RELEASE_SIGNING_ARTIFACT"' \
GENESIS_RELEASE_SIGNING_DIR=.genesis-state/autonomous-blueprint/release-signing \
  bash scripts/record_release_signing_evidence.sh
```

Valid signing kinds:

- `desktop_installer`
- `desktop_signing`
- `desktop_notarization`
- `ios_development_signing`
- `android_development_signing`

The verification command must be the platform-specific proof command, such as
`codesign --verify`, `spctl`, `signtool verify`, `codesign -dv` for an iOS
artifact, or `apksigner verify` for Android. The manifest stores artifact hashes
and the verification command hash, not command output.

## Full Gate

Default autonomous runs may remain `partial` while external evidence is absent.
Set both strict flags in the final release CI job:

```bash
GENESIS_REQUIRE_REAL_PLATFORM_MATRIX=1 \
GENESIS_REQUIRE_RELEASE_PACKAGING=1 \
GENESIS_AUTONOMOUS_MODE=release \
  bash scripts/run_autonomous_blueprint.sh
```

That job passes only after all real platform smoke manifests and all signing
evidence manifests are present for the same git commit.
