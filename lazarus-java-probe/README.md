# Lazarus Java Probe

Low-intrusion Old-Java probe SDK for Project Lazarus Breakwater.

Build:

```sh
mvn -f lazarus-java-probe/pom.xml package
```

Use `target/lazarus-java-probe-0.1.0-all.jar` in the legacy app. The shaded JAR relocates Jackson to `com.genesis.lazarus.shadow.jackson`.

MVP integration:

1. Register `com.genesis.lazarus.probe.servlet.LazarusFilter` first in `web.xml`.
2. Wrap the existing `DataSource` with `com.genesis.lazarus.probe.jdbc.LazarusDataSource`.
3. Configure output directory and limits with system properties:

```text
-Dlazarus.probe.enabled=true
-Dlazarus.probe.output.dir=/tmp/lazarus_breakwater_snapshots
-Dlazarus.probe.queue.capacity=1024
-Dlazarus.probe.max.rows=500
-Dlazarus.probe.max.field.bytes=1048576
-Dlazarus.probe.max.snapshot.bytes=1048576
-Dlazarus.probe.max.dir.bytes=2147483648
```

Fail-safe behavior:

- Queue full: drop snapshot.
- Oversized ResultSet or payload: mark `truncated_invalid`; Rust ingestion rejects it.
- Writer failure: disable probe in-memory and let the host continue.
- Sensitive keys containing `password`, `token`, `card`, `secret`, `ssn`, or `pin` are masked.

Deployment approval packet:

- `docs/lazarus-pilot-deployment-and-masking-audit.md`
