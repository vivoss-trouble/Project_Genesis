package com.genesis.lazarus.probe;

import java.io.File;

public final class LazarusConfig {
    public final boolean enabled;
    public final File outputDir;
    public final int queueCapacity;
    public final int maxRows;
    public final int maxFieldBytes;
    public final int maxSnapshotBytes;
    public final long maxDirBytes;
    public final int flushEvery;

    private LazarusConfig(
            boolean enabled,
            File outputDir,
            int queueCapacity,
            int maxRows,
            int maxFieldBytes,
            int maxSnapshotBytes,
            long maxDirBytes,
            int flushEvery) {
        this.enabled = enabled;
        this.outputDir = outputDir;
        this.queueCapacity = queueCapacity;
        this.maxRows = maxRows;
        this.maxFieldBytes = maxFieldBytes;
        this.maxSnapshotBytes = maxSnapshotBytes;
        this.maxDirBytes = maxDirBytes;
        this.flushEvery = flushEvery;
    }

    public static LazarusConfig fromSystemProperties() {
        return new LazarusConfig(
                boolProp("lazarus.probe.enabled", true),
                new File(strProp("lazarus.probe.output.dir", "/tmp/lazarus_breakwater_snapshots")),
                intProp("lazarus.probe.queue.capacity", 1024),
                intProp("lazarus.probe.max.rows", 500),
                intProp("lazarus.probe.max.field.bytes", 1024 * 1024),
                intProp("lazarus.probe.max.snapshot.bytes", 1024 * 1024),
                longProp("lazarus.probe.max.dir.bytes", 2L * 1024L * 1024L * 1024L),
                intProp("lazarus.probe.flush.every", 1000));
    }

    private static String strProp(String key, String fallback) {
        String value = System.getProperty(key);
        return value == null || value.trim().isEmpty() ? fallback : value;
    }

    private static boolean boolProp(String key, boolean fallback) {
        String value = System.getProperty(key);
        return value == null ? fallback : Boolean.parseBoolean(value);
    }

    private static int intProp(String key, int fallback) {
        String value = System.getProperty(key);
        if (value == null) {
            return fallback;
        }
        try {
            int parsed = Integer.parseInt(value);
            return parsed > 0 ? parsed : fallback;
        } catch (NumberFormatException ignored) {
            return fallback;
        }
    }

    private static long longProp(String key, long fallback) {
        String value = System.getProperty(key);
        if (value == null) {
            return fallback;
        }
        try {
            long parsed = Long.parseLong(value);
            return parsed > 0 ? parsed : fallback;
        } catch (NumberFormatException ignored) {
            return fallback;
        }
    }
}
