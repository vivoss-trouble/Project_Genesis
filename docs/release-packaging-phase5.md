# Release Packaging Phase 5

Phase 5 records release packaging evidence without claiming that unavailable
platform signing jobs have completed.

## Evidence Rule

The release packaging manifest must link:

- build artifact hashes;
- the `genesis-sdk` package version and shell ABI constants;
- the real platform matrix manifest for the same git commit;
- the validation manifest and profile for the same git commit.

The manifest may be `partial` while signing and installer evidence is missing.
It can become `passed` only when every release packaging requirement is present.

## Scripts

- `scripts/record_release_packaging_evidence.sh` builds the release desktop shell
  and SDK/mobile-control libraries, runs a desktop shell package smoke, hashes
  artifacts, and writes `.genesis-state/release-packaging.json`.
- `scripts/record_release_signing_evidence.sh` is the portable CI/runner entry
  for installer, signing, notarization, iOS signing, and Android signing
  evidence. It records only evidence backed by a real artifact and a successful
  verification command.
- `scripts/run_autonomous_blueprint.sh` runs the packaging evidence step after
  validation and validates the manifest from `autonomous-summary.json`.

## Strict Mode

Set `GENESIS_REQUIRE_RELEASE_PACKAGING=1` to fail unless desktop installer,
desktop signing/notarization, iOS development signing, and Android development
signing evidence are all present.

Default autonomous runs keep development velocity while honestly reporting
missing packaging evidence as `partial`.
