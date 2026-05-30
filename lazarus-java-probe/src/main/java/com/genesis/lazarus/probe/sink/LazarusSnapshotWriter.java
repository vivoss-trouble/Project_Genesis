package com.genesis.lazarus.probe.sink;

import com.fasterxml.jackson.databind.MapperFeature;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.SerializationFeature;
import com.fasterxml.jackson.annotation.JsonPropertyOrder;
import com.genesis.lazarus.probe.Hashing;
import com.genesis.lazarus.probe.LazarusConfig;
import com.genesis.lazarus.probe.LazarusContext;
import com.genesis.lazarus.probe.LazarusProbe;
import com.genesis.lazarus.probe.model.StateSnapshot;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.text.SimpleDateFormat;
import java.util.Arrays;
import java.util.Comparator;
import java.util.Date;
import java.util.concurrent.ArrayBlockingQueue;

public final class LazarusSnapshotWriter extends Thread {
    private final ArrayBlockingQueue<LazarusContext.Capture> queue;
    private final LazarusConfig config;
    private final ObjectMapper mapper;
    private volatile boolean running = true;
    private int written;

    public LazarusSnapshotWriter(ArrayBlockingQueue<LazarusContext.Capture> queue, LazarusConfig config) {
        super("lazarus-snapshot-writer");
        setDaemon(true);
        this.queue = queue;
        this.config = config;
        this.mapper = new ObjectMapper();
        this.mapper.configure(SerializationFeature.ORDER_MAP_ENTRIES_BY_KEYS, true);
        this.mapper.configure(MapperFeature.SORT_PROPERTIES_ALPHABETICALLY, false);
        this.mapper.setSerializationInclusion(com.fasterxml.jackson.annotation.JsonInclude.Include.ALWAYS);
    }

    public void shutdown() {
        running = false;
        interrupt();
    }

    @Override
    public void run() {
        while (running) {
            try {
                LazarusContext.Capture capture = queue.take();
                writeCapture(capture);
            } catch (InterruptedException ignored) {
                // shutdown path
            } catch (Throwable fatal) {
                LazarusProbe.disable();
                return;
            }
        }
    }

    private void writeCapture(LazarusContext.Capture capture) throws IOException {
        StateSnapshot snapshot = capture.snapshot();
        snapshot.snapshot_hash = computeSnapshotHash(snapshot);
        byte[] line = mapper.writeValueAsBytes(snapshot);
        if (line.length > config.maxSnapshotBytes) {
            snapshot.status = "truncated_invalid";
            snapshot.snapshot_hash = computeSnapshotHash(snapshot);
            line = mapper.writeValueAsBytes(snapshot);
        }
        ensureOutputDir();
        if (written % config.flushEvery == 0) {
            enforceDirBudget();
        }
        File file = new File(config.outputDir, fileName());
        FileOutputStream out = new FileOutputStream(file, true);
        try {
            out.write(line);
            out.write('\n');
        } finally {
            out.close();
        }
        written++;
    }

    private String computeSnapshotHash(StateSnapshot snapshot) throws IOException {
        StateSnapshotHashMaterial material = new StateSnapshotHashMaterial(snapshot);
        return Hashing.sha256Hex(mapper.writeValueAsBytes(material));
    }

    @JsonPropertyOrder({
            "contract_version",
            "snapshot_id",
            "trace_id",
            "operation",
            "status",
            "context",
            "trace_tags",
            "upstream",
            "downstream_dependencies",
            "mutation_intents",
            "limits"
    })
    private static final class StateSnapshotHashMaterial {
        public final int contract_version;
        public final String snapshot_id;
        public final String trace_id;
        public final String operation;
        public final String status;
        public final StateSnapshot.SnapshotContext context;
        public final java.util.Map<String, String> trace_tags;
        public final StateSnapshot.UpstreamRequest upstream;
        public final java.util.List<StateSnapshot.DownstreamDependency> downstream_dependencies;
        public final java.util.List<StateSnapshot.MutationIntent> mutation_intents;
        public final StateSnapshot.SnapshotLimits limits;

        StateSnapshotHashMaterial(StateSnapshot snapshot) {
            this.contract_version = snapshot.contract_version;
            this.snapshot_id = snapshot.snapshot_id;
            this.trace_id = snapshot.trace_id;
            this.operation = snapshot.operation;
            this.status = snapshot.status;
            this.context = snapshot.context;
            this.trace_tags = snapshot.trace_tags;
            this.upstream = snapshot.upstream;
            this.downstream_dependencies = snapshot.downstream_dependencies;
            this.mutation_intents = snapshot.mutation_intents;
            this.limits = snapshot.limits;
        }
    }

    private void ensureOutputDir() throws IOException {
        if (!config.outputDir.isDirectory() && !config.outputDir.mkdirs()) {
            throw new IOException("failed to create " + config.outputDir);
        }
    }

    private String fileName() {
        String day = new SimpleDateFormat("yyyyMMdd").format(new Date());
        return "lazarus_breakwater_" + day + ".jsonl";
    }

    private void enforceDirBudget() {
        File[] files = config.outputDir.listFiles();
        if (files == null) {
            return;
        }
        long total = 0L;
        for (File file : files) {
            if (file.isFile()) {
                total += file.length();
            }
        }
        if (total <= config.maxDirBytes) {
            return;
        }
        Arrays.sort(files, Comparator.comparingLong(File::lastModified));
        for (File file : files) {
            if (total <= config.maxDirBytes) {
                return;
            }
            if (file.isFile()) {
                long size = file.length();
                if (file.delete()) {
                    total -= size;
                }
            }
        }
    }
}
