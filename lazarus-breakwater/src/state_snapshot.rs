use lazarus_contracts::LAZARUS_CONTRACT_VERSION;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

use crate::{
    ContextObservation, DEFAULT_MAX_DEPENDENCY_ROWS, DEFAULT_MAX_SNAPSHOT_BYTES, ObservationKind,
    TrafficSnapshot, require_non_empty, stable_hash,
};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StateSnapshotStatus {
    Complete,
    TruncatedInvalid,
    Dropped,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DependencyKind {
    JdbcRead,
    HttpResponse,
    CacheRead,
    FileRead,
    EnvRead,
    ClockRead,
    UnknownRead,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MutationKind {
    DbUpdate,
    DbInsert,
    DbDelete,
    HttpPost,
    HttpPut,
    CacheWrite,
    FileWrite,
    UnknownWrite,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SnapshotLimits {
    pub max_dependency_rows: usize,
    pub max_snapshot_bytes: usize,
}

impl Default for SnapshotLimits {
    fn default() -> Self {
        Self {
            max_dependency_rows: DEFAULT_MAX_DEPENDENCY_ROWS,
            max_snapshot_bytes: DEFAULT_MAX_SNAPSHOT_BYTES,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SnapshotContext {
    pub captured_at_unix_ms: u64,
    pub epoch_unix_ms: u64,
    pub locale: Option<String>,
    pub principal: Option<String>,
    pub thread_name: Option<String>,
    pub env: BTreeMap<String, Value>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct UpstreamRequest {
    pub method: String,
    pub uri: String,
    pub headers: BTreeMap<String, String>,
    pub body: Value,
    pub raw_body_sha256: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct DownstreamDependency {
    pub dependency_id: String,
    pub kind: DependencyKind,
    pub target: String,
    pub query_or_request: Option<String>,
    pub rows: Vec<BTreeMap<String, Value>>,
    pub response: Value,
    pub deterministic: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct MutationIntent {
    pub intent_id: String,
    pub kind: MutationKind,
    pub target: String,
    pub statement_or_request: Option<String>,
    pub params: Value,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct StateSnapshot {
    pub contract_version: u32,
    pub snapshot_id: String,
    pub trace_id: String,
    pub operation: String,
    pub status: StateSnapshotStatus,
    pub context: SnapshotContext,
    #[serde(default)]
    pub trace_tags: BTreeMap<String, String>,
    pub upstream: UpstreamRequest,
    pub downstream_dependencies: Vec<DownstreamDependency>,
    pub mutation_intents: Vec<MutationIntent>,
    pub limits: SnapshotLimits,
    pub snapshot_hash: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct StateSnapshotInput {
    pub snapshot_id: String,
    pub trace_id: String,
    pub operation: String,
    pub context: SnapshotContext,
    pub upstream: UpstreamRequest,
    pub downstream_dependencies: Vec<DownstreamDependency>,
    pub mutation_intents: Vec<MutationIntent>,
    pub limits: SnapshotLimits,
}

impl StateSnapshot {
    pub fn new(input: StateSnapshotInput) -> Result<Self, String> {
        let mut snapshot = Self {
            contract_version: LAZARUS_CONTRACT_VERSION,
            snapshot_id: input.snapshot_id,
            trace_id: input.trace_id,
            operation: input.operation,
            status: StateSnapshotStatus::Complete,
            context: input.context,
            trace_tags: BTreeMap::new(),
            upstream: input.upstream,
            downstream_dependencies: input.downstream_dependencies,
            mutation_intents: input.mutation_intents,
            limits: input.limits,
            snapshot_hash: String::new(),
        };
        snapshot.validate_without_hash()?;
        snapshot.snapshot_hash = snapshot.compute_hash()?;
        Ok(snapshot)
    }

    pub fn validate_ingestable(&self) -> Result<(), String> {
        self.validate_hash()?;
        if self.status != StateSnapshotStatus::Complete {
            return Err(format!(
                "state snapshot {} is not complete: {:?}",
                self.snapshot_id, self.status
            ));
        }
        self.validate_limits()?;
        self.validate_masking()?;
        Ok(())
    }

    pub fn validate_hash(&self) -> Result<(), String> {
        self.validate_without_hash()?;
        let actual = self.compute_hash()?;
        if actual != self.snapshot_hash {
            return Err(format!(
                "state snapshot hash mismatch: expected {}, actual {actual}",
                self.snapshot_hash
            ));
        }
        Ok(())
    }

    pub fn compute_hash(&self) -> Result<String, String> {
        let material = StateSnapshotHashMaterial {
            contract_version: self.contract_version,
            snapshot_id: &self.snapshot_id,
            trace_id: &self.trace_id,
            operation: &self.operation,
            status: &self.status,
            context: &self.context,
            trace_tags: &self.trace_tags,
            upstream: &self.upstream,
            downstream_dependencies: &self.downstream_dependencies,
            mutation_intents: &self.mutation_intents,
            limits: &self.limits,
        };
        stable_hash(&material)
    }

    fn validate_without_hash(&self) -> Result<(), String> {
        if self.contract_version != LAZARUS_CONTRACT_VERSION {
            return Err(format!(
                "unsupported state snapshot contract version: {}",
                self.contract_version
            ));
        }
        require_non_empty("snapshot_id", &self.snapshot_id)?;
        require_non_empty("trace_id", &self.trace_id)?;
        require_non_empty("operation", &self.operation)?;
        require_non_empty("upstream.method", &self.upstream.method)?;
        require_non_empty("upstream.uri", &self.upstream.uri)?;
        if self.limits.max_dependency_rows == 0 {
            return Err("limits.max_dependency_rows must be > 0".to_string());
        }
        if self.limits.max_snapshot_bytes == 0 {
            return Err("limits.max_snapshot_bytes must be > 0".to_string());
        }
        for dependency in &self.downstream_dependencies {
            require_non_empty("dependency.dependency_id", &dependency.dependency_id)?;
            require_non_empty("dependency.target", &dependency.target)?;
            if !dependency.deterministic {
                return Err(format!(
                    "dependency {} was not captured deterministically",
                    dependency.dependency_id
                ));
            }
        }
        for intent in &self.mutation_intents {
            require_non_empty("mutation.intent_id", &intent.intent_id)?;
            require_non_empty("mutation.target", &intent.target)?;
        }
        Ok(())
    }

    fn validate_limits(&self) -> Result<(), String> {
        let bytes = serde_json::to_vec(self).map_err(|error| error.to_string())?;
        if bytes.len() > self.limits.max_snapshot_bytes {
            return Err(format!(
                "state snapshot {} exceeds max_snapshot_bytes: {} > {}",
                self.snapshot_id,
                bytes.len(),
                self.limits.max_snapshot_bytes
            ));
        }
        for dependency in &self.downstream_dependencies {
            if dependency.rows.len() > self.limits.max_dependency_rows {
                return Err(format!(
                    "dependency {} exceeds max_dependency_rows: {} > {}",
                    dependency.dependency_id,
                    dependency.rows.len(),
                    self.limits.max_dependency_rows
                ));
            }
        }
        Ok(())
    }

    fn validate_masking(&self) -> Result<(), String> {
        assert_masked_value(
            "context.env",
            &serde_json::to_value(&self.context.env).unwrap(),
        )?;
        assert_masked_value(
            "upstream.headers",
            &serde_json::to_value(&self.upstream.headers).unwrap(),
        )?;
        assert_masked_value("upstream.body", &self.upstream.body)?;
        for dependency in &self.downstream_dependencies {
            assert_masked_value(
                &format!("dependency.{}.rows", dependency.dependency_id),
                &serde_json::to_value(&dependency.rows).map_err(|error| error.to_string())?,
            )?;
            assert_masked_value(
                &format!("dependency.{}.response", dependency.dependency_id),
                &dependency.response,
            )?;
        }
        for intent in &self.mutation_intents {
            assert_masked_value(
                &format!("mutation.{}.params", intent.intent_id),
                &intent.params,
            )?;
        }
        Ok(())
    }
}

#[derive(Serialize)]
struct StateSnapshotHashMaterial<'a> {
    contract_version: u32,
    snapshot_id: &'a str,
    trace_id: &'a str,
    operation: &'a str,
    status: &'a StateSnapshotStatus,
    context: &'a SnapshotContext,
    trace_tags: &'a BTreeMap<String, String>,
    upstream: &'a UpstreamRequest,
    downstream_dependencies: &'a [DownstreamDependency],
    mutation_intents: &'a [MutationIntent],
    limits: &'a SnapshotLimits,
}

pub fn project_state_snapshot_to_traffic_snapshot(
    snapshot: &StateSnapshot,
) -> Result<TrafficSnapshot, String> {
    snapshot.validate_ingestable()?;
    let observations = snapshot
        .downstream_dependencies
        .iter()
        .map(|dependency| ContextObservation {
            kind: match dependency.kind {
                DependencyKind::JdbcRead => ObservationKind::DatabaseRead,
                DependencyKind::HttpResponse => ObservationKind::NetworkResponse,
                DependencyKind::CacheRead
                | DependencyKind::EnvRead
                | DependencyKind::ClockRead
                | DependencyKind::UnknownRead => ObservationKind::EnvRead,
                DependencyKind::FileRead => ObservationKind::FileRead,
            },
            target: dependency.target.clone(),
            value: if dependency.rows.is_empty() {
                dependency.response.clone()
            } else {
                serde_json::to_value(&dependency.rows).expect("rows serialize")
            },
            deterministic: dependency.deterministic,
        })
        .collect::<Vec<_>>();
    TrafficSnapshot::new(
        snapshot.snapshot_id.clone(),
        snapshot.operation.clone(),
        snapshot.context.captured_at_unix_ms,
        snapshot.upstream.body.clone(),
        observations,
    )
}

fn assert_masked_value(path: &str, value: &Value) -> Result<(), String> {
    match value {
        Value::Object(map) => {
            for (key, child) in map {
                let child_path = format!("{path}.{key}");
                if is_sensitive_key(key) && child != "***" {
                    return Err(format!("sensitive field must be masked: {child_path}"));
                }
                assert_masked_value(&child_path, child)?;
            }
        }
        Value::Array(items) => {
            for (index, child) in items.iter().enumerate() {
                assert_masked_value(&format!("{path}[{index}]"), child)?;
            }
        }
        _ => {}
    }
    Ok(())
}

fn is_sensitive_key(key: &str) -> bool {
    let lower = key.to_ascii_lowercase();
    [
        "password", "passwd", "token", "secret", "card", "ssn", "pin",
    ]
    .iter()
    .any(|needle| lower.contains(needle))
}
