package com.genesis.lazarus.probe.model;

import com.fasterxml.jackson.annotation.JsonInclude;
import com.fasterxml.jackson.annotation.JsonPropertyOrder;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

@JsonInclude(JsonInclude.Include.ALWAYS)
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
        "limits",
        "snapshot_hash"
})
public final class StateSnapshot {
    public int contract_version = 1;
    public String snapshot_id;
    public String trace_id;
    public String operation;
    public String status = "complete";
    public SnapshotContext context = new SnapshotContext();
    public Map<String, String> trace_tags = new LinkedHashMap<String, String>();
    public UpstreamRequest upstream = new UpstreamRequest();
    public List<DownstreamDependency> downstream_dependencies = new ArrayList<DownstreamDependency>();
    public List<MutationIntent> mutation_intents = new ArrayList<MutationIntent>();
    public SnapshotLimits limits = new SnapshotLimits();
    public String snapshot_hash = "";

    @JsonInclude(JsonInclude.Include.ALWAYS)
    @JsonPropertyOrder({
            "captured_at_unix_ms",
            "epoch_unix_ms",
            "locale",
            "principal",
            "thread_name",
            "env"
    })
    public static final class SnapshotContext {
        public long captured_at_unix_ms;
        public long epoch_unix_ms;
        public String locale;
        public String principal;
        public String thread_name;
        public Map<String, Object> env = new LinkedHashMap<String, Object>();
    }

    @JsonInclude(JsonInclude.Include.ALWAYS)
    @JsonPropertyOrder({"method", "uri", "headers", "body", "raw_body_sha256"})
    public static final class UpstreamRequest {
        public String method;
        public String uri;
        public Map<String, String> headers = new LinkedHashMap<String, String>();
        public Object body;
        public String raw_body_sha256;
    }

    @JsonInclude(JsonInclude.Include.ALWAYS)
    @JsonPropertyOrder({
            "dependency_id",
            "kind",
            "target",
            "query_or_request",
            "rows",
            "response",
            "deterministic"
    })
    public static final class DownstreamDependency {
        public String dependency_id;
        public String kind;
        public String target;
        public String query_or_request;
        public List<Map<String, Object>> rows = new ArrayList<Map<String, Object>>();
        public Object response;
        public boolean deterministic = true;
    }

    @JsonInclude(JsonInclude.Include.ALWAYS)
    @JsonPropertyOrder({"intent_id", "kind", "target", "statement_or_request", "params"})
    public static final class MutationIntent {
        public String intent_id;
        public String kind;
        public String target;
        public String statement_or_request;
        public Object params;
    }

    @JsonInclude(JsonInclude.Include.ALWAYS)
    @JsonPropertyOrder({"max_dependency_rows", "max_snapshot_bytes"})
    public static final class SnapshotLimits {
        public int max_dependency_rows = 500;
        public int max_snapshot_bytes = 1024 * 1024;
    }
}
