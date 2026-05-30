package com.genesis.lazarus.probe;

import com.genesis.lazarus.probe.sink.LazarusSnapshotWriter;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.atomic.AtomicBoolean;

public final class LazarusProbe {
    private static final Object LOCK = new Object();
    private static volatile LazarusConfig config;
    private static volatile ArrayBlockingQueue<LazarusContext.Capture> queue;
    private static volatile LazarusSnapshotWriter writer;
    private static final AtomicBoolean enabled = new AtomicBoolean(false);

    private LazarusProbe() {}

    public static void start() {
        start(LazarusConfig.fromSystemProperties());
    }

    public static void start(LazarusConfig newConfig) {
        synchronized (LOCK) {
            if (enabled.get()) {
                return;
            }
            config = newConfig;
            enabled.set(newConfig.enabled);
            if (!newConfig.enabled) {
                return;
            }
            queue = new ArrayBlockingQueue<LazarusContext.Capture>(newConfig.queueCapacity);
            writer = new LazarusSnapshotWriter(queue, newConfig);
            writer.start();
        }
    }

    public static void disable() {
        synchronized (LOCK) {
            enabled.set(false);
            if (writer != null) {
                writer.shutdown();
            }
            queue = null;
            writer = null;
        }
    }

    public static boolean isEnabled() {
        return enabled.get();
    }

    public static LazarusConfig config() {
        LazarusConfig current = config;
        if (current == null) {
            current = LazarusConfig.fromSystemProperties();
            config = current;
        }
        return current;
    }

    public static boolean offer(LazarusContext.Capture capture) {
        if (!enabled.get() || capture == null || queue == null) {
            return false;
        }
        return queue.offer(capture);
    }
}
