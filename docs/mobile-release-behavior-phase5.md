# Mobile Release Behavior Phase 5

Phase 5 keeps mobile productization scoped to the `MobileControl` profile.
Mobile shells are remote-control clients and evidence viewers. They do not run
local native plugins, local Java probes, browser automation, subprocess workers,
or local service IPC.

## Network Permission

Mobile clients require outbound network access to a configured Genesis node URL.
The first release profile must treat that URL as explicit user or deployment
configuration. Local loopback-only desktop assumptions are not valid on iOS or
Android.

## Background Behavior

Mobile clients are not release-gated as always-on background agents. When the
operating system suspends the app, in-flight remote requests may be cancelled or
retried by the foreground session. Long-running Genesis work remains on the
remote node and must be observed through SDK status and evidence APIs after the
client resumes.

## Release Evidence

The release packaging manifest links the mobile behavior contract to the SDK
version, validation profile, platform smoke manifest, and build artifact hashes.
Store or development signing evidence remains platform-specific and must be
provided by the iOS and Android release jobs before the full Phase 5 packaging
claim can become `passed`.
