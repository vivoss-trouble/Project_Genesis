# Real Platform Matrix Phase 4

Phase 4 separates contract support from real platform verification.

`scripts/validate_platform_contracts.sh` proves that the shared Rust boundary
compiles and stays contained across macOS, Linux, Windows, iOS, Android, and
WASI targets. It does not prove that a real host or device ran Genesis.

## Evidence Rule

A platform can be marked `verified` only when a platform smoke manifest exists
for the same git commit and reports `status=passed`.

Required platform IDs:

- `macos`
- `linux`
- `windows`
- `ios`
- `android`

Missing manifests are recorded as `missing`, not inferred from cross-compilation.
The matrix `claim` remains `unverified` until all five required platforms are
verified.

## Scripts

- `scripts/record_platform_smoke.sh` records the current desktop host smoke by
  running `genesis-desktop-shell health` and writing
  `.genesis-state/platform-smoke/<platform>.json`.
- `scripts/validate_real_platform_matrix.sh` aggregates platform smoke
  manifests into `.genesis-state/real-platform-matrix.json`.
- `scripts/import_platform_smoke_manifest.sh` validates and imports a smoke
  manifest produced by another real host or device into the matrix smoke
  directory.
- `scripts/run_autonomous_blueprint.sh` runs both scripts and links the matrix
  manifest from `autonomous-summary.json`.

## Strict Mode

Set `GENESIS_REQUIRE_REAL_PLATFORM_MATRIX=1` to make the matrix gate fail unless
all five real platform manifests are present and passed.

Default autonomous runs keep release validation passing while honestly reporting
the matrix as `partial` when only the current host has been smoked.
