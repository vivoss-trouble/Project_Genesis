# Lazarus Pilot Deployment and Masking Audit

## Purpose

This document is the approval packet for deploying `lazarus-java-probe` into a legacy Java service for a read-only pilot harvest. The goal is to collect `StateSnapshot` JSONL files for Lazarus Breakwater without changing business behavior, blocking request threads, or exporting unmasked sensitive fields.

## Deployment Scope

Approved target class of systems:

- Java 8 compatible servlet applications.
- Services where `LazarusFilter` can be registered before business filters.
- Services where the production `DataSource` can be wrapped by `LazarusDataSource`.
- First pilot methods should be read-heavy or compute-heavy and should avoid write-after-read control flow.

Not approved for first deployment:

- Core transfer or settlement cutover paths.
- Methods whose correctness depends on DB locks, triggers, sequences, cursors, or thread scheduling.
- Methods that stream very large result sets as normal behavior.
- Services where local snapshot storage cannot be capacity-limited.

## Artifact

Build artifact:

```text
lazarus-java-probe/target/lazarus-java-probe-0.1.0-all.jar
```

The shaded JAR relocates Jackson under:

```text
com.genesis.lazarus.shadow.jackson
```

This reduces host application classpath collision risk.

## Runtime Configuration

Recommended first-pilot JVM properties:

```text
-Dlazarus.probe.enabled=true
-Dlazarus.probe.output.dir=/var/log/lazarus_breakwater_snapshots
-Dlazarus.probe.queue.capacity=1024
-Dlazarus.probe.max.rows=500
-Dlazarus.probe.max.field.bytes=1048576
-Dlazarus.probe.max.snapshot.bytes=1048576
-Dlazarus.probe.max.dir.bytes=2147483648
-Dlazarus.probe.flush.every=1000
```

Emergency disable:

```text
-Dlazarus.probe.enabled=false
```

## Data Captured

The probe writes JSONL `StateSnapshot` records containing:

- Request metadata: method, URI, headers, body hash/body when available.
- Context: capture time, locale, thread name, principal when available.
- Trace tags: `business_class`, `business_method`, source file, line.
- JDBC read dependencies: SQL text, deterministic flat rows, row count.
- JDBC mutation intents: SQL statement and parameters as intent only.
- Capture limits and status.
- SHA-256 snapshot hash for tamper detection.

The probe does not execute business logic outside the host request path. It records observations and writes snapshots asynchronously.

## Masking Rules

Sensitive keys are masked before serialization when the key contains any of:

```text
password
passwd
token
secret
card
ssn
pin
```

Masked value:

```text
***
```

Large byte arrays are not emitted raw. They are represented as:

```text
bytes:<captured_len>:sha256:<digest>
```

Large strings are truncated according to `lazarus.probe.max.field.bytes`.

Rust-side ingestion performs a second validation pass and rejects unmasked sensitive fields.

## Resource Controls

Threading:

- Request thread performs only bounded capture and `ArrayBlockingQueue.offer`.
- Snapshot JSON serialization and file writes run on a daemon writer thread.
- Queue full behavior is drop, not block.

Memory:

- JDBC rows are capped by `lazarus.probe.max.rows`.
- Field size is capped by `lazarus.probe.max.field.bytes`.
- Snapshot size is capped by `lazarus.probe.max.snapshot.bytes`.

Disk:

- Snapshot directory total size is capped by `lazarus.probe.max.dir.bytes`.
- Writer performs aging deletion of oldest snapshot files when above budget.

Failure behavior:

- Queue full: snapshot is dropped.
- Oversized result set or payload: snapshot is marked `truncated_invalid`.
- Writer fatal error: probe disables itself in memory; host service continues.

## Operational Runbook

Pre-deployment:

1. Build and verify probe:

```sh
bash scripts/validate_lazarus_java_probe.sh
```

2. Confirm target service can register `LazarusFilter` first.
3. Confirm target service can wrap its `DataSource` with `LazarusDataSource`.
4. Confirm snapshot directory has isolated quota and is not on the root filesystem.
5. Confirm operations has rollback access to remove the filter/DataSource wrapper or set `lazarus.probe.enabled=false`.

Deployment:

1. Deploy shaded JAR to the target service classpath.
2. Register `com.genesis.lazarus.probe.servlet.LazarusFilter`.
3. Wrap the target `DataSource` with `com.genesis.lazarus.probe.jdbc.LazarusDataSource`.
4. Set JVM properties from the runtime configuration section.
5. Restart during an approved low-risk window.

Harvest:

1. Run silently for 24-48 hours.
2. Copy JSONL files from `lazarus.probe.output.dir` to the Lazarus workstation.
3. Run:

```sh
target/debug/genesis-cli corpus-ingest <snapshot-dir> <ingest-out-dir>
target/debug/genesis-cli corpus-report <snapshot-dir> <report.json>
```

Go/No-Go:

- `missing_trace_tag_count == 0`
- `invalid_count == 0`
- `truncated_invalid_count / total_snapshots <= 0.01`
- Top candidate has `valid_ingestable_count >= 100`
- First pilot candidate has `mutation_intent_count == 0`
- First pilot candidate has `unique_dependency_query_count <= 5`

Rollback:

1. Set `-Dlazarus.probe.enabled=false` and restart, or remove filter/DataSource wrapper.
2. Remove snapshot directory after collection and approval.
3. Keep copied corpus under the project evidence retention policy.

## Security Review Checklist

- Shaded JAR verified to relocate Jackson.
- No raw passwords, tokens, card values, SSNs, PINs, or secrets in sample JSONL.
- Snapshot directory has explicit quota.
- Probe failure does not block host request path.
- Rust `corpus-ingest` accepts valid snapshots and rejects invalid/unmasked snapshots.
- `corpus-report` produces method-level candidate scoring before any synthesis attempt.

## Validation Evidence

Current local validation command:

```sh
bash scripts/validate_lazarus_engine.sh
```

This covers:

- Java Probe build and integration test.
- Shaded dependency relocation check.
- Snapshot ingest.
- Snapshot report and trace-tag assertion.
- Rust Lazarus package tests.
- Wasm smoke path to `CutoverReady`.
- Engine selftests.
