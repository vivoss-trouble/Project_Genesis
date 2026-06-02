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

Desktop runners can generate their own manifest with:

```bash
GENESIS_PLATFORM_ID=linux \
GENESIS_PLATFORM_SMOKE_DIR=.genesis-state/platform-smoke \
  bash scripts/record_platform_smoke.sh
```

iOS and Android device runners can generate mobile manifests with:

```bash
GENESIS_MOBILE_PLATFORM_ID=ios \
GENESIS_MOBILE_DEVICE_ID="$DEVICE_UDID" \
GENESIS_MOBILE_OS_VERSION="$DEVICE_OS_VERSION" \
GENESIS_MOBILE_DEVICE_PROOF=/path/to/device-proof.txt \
GENESIS_MOBILE_DEVICE_VERIFY_CMD='test -s "$GENESIS_MOBILE_DEVICE_PROOF"' \
GENESIS_PLATFORM_SMOKE_DIR=.genesis-state/platform-smoke \
  bash scripts/record_mobile_control_smoke.sh
```

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

Imported signing manifests are validated with:

```bash
GENESIS_RELEASE_SIGNING_MANIFEST=/path/to/desktop_signing.json \
GENESIS_RELEASE_SIGNING_DIR=.genesis-state/autonomous-blueprint/release-signing \
  bash scripts/import_release_signing_manifest.sh
```

## Evidence Bundle

The final release job can import an evidence bundle with this layout:

```text
bundle/
  platform-smoke/
    linux.json
    windows.json
    ios.json
    android.json
  release-signing/
    desktop_installer.json
    desktop_signing.json
    desktop_notarization.json
    ios_development_signing.json
    android_development_signing.json
```

Import and aggregate the bundle with:

```bash
GENESIS_EXTERNAL_EVIDENCE_BUNDLE=/path/to/bundle \
GENESIS_AUTONOMOUS_EVIDENCE_DIR=.genesis-state/autonomous-blueprint \
  bash scripts/collect_external_release_evidence.sh
```

## Full Gate

Default autonomous runs may remain `partial` while external evidence is absent.
Set both strict flags in the final release CI job:

```bash
GENESIS_REQUIRE_REAL_PLATFORM_MATRIX=1 \
GENESIS_REQUIRE_RELEASE_PACKAGING=1 \
GENESIS_RELEASE_SIGNING_DIR=.genesis-state/autonomous-blueprint/release-signing \
GENESIS_AUTONOMOUS_MODE=release \
  bash scripts/run_autonomous_blueprint.sh
```

That job passes only after all real platform smoke manifests and all signing
evidence manifests are present for the same git commit.

## GitHub Actions Bridge

`.github/workflows/external-release-evidence.yml` is the CI bridge for this
phase. It does not relax any gate and does not synthesize missing evidence.

Default manual dispatch:

```text
workflow: External Release Evidence
git_ref: genesis-rc-2
run_desktop_smoke: true
run_ios_smoke: false
run_android_smoke: false
run_signing_evidence: false
run_strict_gate: false
```

This records real desktop smoke manifests on GitHub-hosted macOS, Linux, and
Windows runners and uploads them as `external-release-evidence-*` artifacts.

Mobile jobs are disabled by default because they require real device runners:

- iOS runner labels: `self-hosted`, `macOS`, `ios-device`
- Android runner labels: `self-hosted`, `Linux`, `android-device`

Required mobile configuration:

- `GENESIS_IOS_DEVICE_ID` secret
- `GENESIS_IOS_OS_VERSION` variable
- optional `GENESIS_IOS_DEVICE_PROOF_CMD` variable
- optional `GENESIS_IOS_DEVICE_VERIFY_CMD` variable
- `GENESIS_ANDROID_DEVICE_ID` secret
- `GENESIS_ANDROID_OS_VERSION` variable
- optional `GENESIS_ANDROID_DEVICE_PROOF_CMD` variable
- optional `GENESIS_ANDROID_DEVICE_VERIFY_CMD` variable
- optional `GENESIS_MOBILE_REMOTE_BASE_URL` variable

Signing evidence is also disabled by default. Enable it only on a
`self-hosted`, `release-signing` runner that has access to the signed artifacts
and verification tooling. Required secrets are:

- `GENESIS_DESKTOP_INSTALLER_ARTIFACT`
- `GENESIS_DESKTOP_INSTALLER_VERIFY_CMD`
- `GENESIS_DESKTOP_SIGNING_ARTIFACT`
- `GENESIS_DESKTOP_SIGNING_VERIFY_CMD`
- `GENESIS_DESKTOP_NOTARIZATION_ARTIFACT`
- `GENESIS_DESKTOP_NOTARIZATION_VERIFY_CMD`
- `GENESIS_IOS_DEVELOPMENT_SIGNING_ARTIFACT`
- `GENESIS_IOS_DEVELOPMENT_SIGNING_VERIFY_CMD`
- `GENESIS_ANDROID_DEVELOPMENT_SIGNING_ARTIFACT`
- `GENESIS_ANDROID_DEVELOPMENT_SIGNING_VERIFY_CMD`

Set `run_strict_gate=true` only after all platform and signing jobs are enabled
for the same `git_ref`. The strict job downloads the evidence artifacts, builds
the expected bundle layout, imports it with
`scripts/collect_external_release_evidence.sh`, then runs
`scripts/run_autonomous_blueprint.sh` with both strict external gates enabled.
It fails if any real platform smoke or signing requirement is missing.

## Preflight Bridge

`.github/workflows/preflight-external-evidence.yml` is the zero-secret,
low-cost preflight bridge. It proves that hosted runners, simulators, emulators,
artifact upload/download, and self-signed verification are wired correctly. It
does not prove real device execution and does not prove production signing.

The workflow records:

- hosted Linux, Windows, and macOS desktop shell health checks
- hosted macOS iOS simulator availability plus `genesis-mobile-control` iOS
  target compilation
- hosted Linux Android emulator availability plus `genesis-mobile-control`
  host smoke
- a Linux desktop shell artifact with a self-signed digest verification proof

Every manifest is intentionally marked:

```json
{
  "preflight_evidence": true,
  "not_release_evidence": true,
  "real_host_smoke": false,
  "real_signing_evidence": false
}
```

Validate a preflight evidence directory with:

```bash
GENESIS_PREFLIGHT_OUT_DIR=/path/to/preflight-external-evidence \
GENESIS_REQUIRE_PREFLIGHT_EXTERNAL_EVIDENCE=1 \
  bash scripts/validate_preflight_external_evidence.sh
```

Preflight evidence must stay outside the strict release evidence bundle. The
strict gate accepts only real platform smoke manifests and real signing
manifests generated by the Phase 6 import scripts above.
