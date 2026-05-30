package com.genesis.lazarus.probe;

import com.genesis.lazarus.probe.model.StateSnapshot;
import java.util.UUID;

public final class LazarusContext {
    private static final ThreadLocal<Capture> CURRENT = new ThreadLocal<Capture>();

    private LazarusContext() {}

    public static Capture begin(String operation, LazarusConfig config) {
        Capture capture = new Capture(UUID.randomUUID().toString(), operation, config);
        CURRENT.set(capture);
        return capture;
    }

    public static Capture current() {
        return CURRENT.get();
    }

    public static void clear() {
        CURRENT.remove();
    }

    public static final class Capture {
        private final String traceId;
        private final String operation;
        private final LazarusConfig config;
        private final long startMs;
        private final StateSnapshot snapshot;
        private int dependencySeq;
        private int mutationSeq;

        Capture(String traceId, String operation, LazarusConfig config) {
            this.traceId = traceId;
            this.operation = operation;
            this.config = config;
            this.startMs = System.currentTimeMillis();
            this.snapshot = new StateSnapshot();
            this.snapshot.snapshot_id = traceId;
            this.snapshot.trace_id = traceId;
            this.snapshot.operation = operation;
            this.snapshot.context.captured_at_unix_ms = startMs;
            this.snapshot.context.epoch_unix_ms = startMs;
            this.snapshot.context.locale = java.util.Locale.getDefault().toString();
            this.snapshot.context.thread_name = Thread.currentThread().getName();
            tagBusinessFrame(this.snapshot);
            this.snapshot.limits.max_dependency_rows = config.maxRows;
            this.snapshot.limits.max_snapshot_bytes = config.maxSnapshotBytes;
        }

        public StateSnapshot snapshot() {
            return snapshot;
        }

        public LazarusConfig config() {
            return config;
        }

        public String nextDependencyId() {
            retagBusinessFrame();
            dependencySeq++;
            return "dep-" + dependencySeq;
        }

        public String nextMutationId() {
            retagBusinessFrame();
            mutationSeq++;
            return "mut-" + mutationSeq;
        }

        public void markTruncatedInvalid() {
            snapshot.status = "truncated_invalid";
        }

        private static void tagBusinessFrame(StateSnapshot snapshot) {
            StackTraceElement frame = findBusinessFrame(Thread.currentThread().getStackTrace());
            if (frame == null) {
                return;
            }
            String className = frame.getClassName();
            snapshot.trace_tags.put("business_class", className);
            snapshot.trace_tags.put("business_method", className + "." + frame.getMethodName());
            snapshot.trace_tags.put("business_file", String.valueOf(frame.getFileName()));
            snapshot.trace_tags.put("business_line", String.valueOf(frame.getLineNumber()));
        }

        private void retagBusinessFrame() {
            tagBusinessFrame(this.snapshot);
        }

        private static StackTraceElement findBusinessFrame(StackTraceElement[] frames) {
            for (int i = 0; i < frames.length; i++) {
                StackTraceElement frame = frames[i];
                String className = frame.getClassName();
                if (isProbeOrPlatformClass(className)) {
                    continue;
                }
                return frame;
            }
            return null;
        }

        private static boolean isProbeOrPlatformClass(String className) {
            return className.equals("com.genesis.lazarus.probe.LazarusContext")
                    || className.startsWith("com.genesis.lazarus.probe.LazarusContext$")
                    || className.startsWith("com.genesis.lazarus.probe.jdbc.")
                    || className.startsWith("com.genesis.lazarus.probe.servlet.")
                    || className.startsWith("com.genesis.lazarus.probe.sink.")
                    || className.startsWith("com.genesis.lazarus.probe.model.")
                    || className.equals("com.genesis.lazarus.probe.Hashing")
                    || className.equals("com.genesis.lazarus.probe.Masking")
                    || className.equals("com.genesis.lazarus.probe.LazarusProbe")
                    || className.startsWith("java.")
                    || className.startsWith("javax.")
                    || className.startsWith("sun.")
                    || className.startsWith("com.sun.")
                    || className.startsWith("org.eclipse.jetty.")
                    || className.startsWith("org.junit.")
                    || className.startsWith("jdk.");
        }
    }
}
