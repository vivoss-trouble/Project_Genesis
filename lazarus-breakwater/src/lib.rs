use lazarus_contracts::{DecisionIr, LAZARUS_CONTRACT_VERSION};
use lazarus_shadow_runner::ShadowRequest;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use sha2::{Digest as _, Sha256};
use std::collections::BTreeMap;

pub const DEFAULT_MAX_DEPENDENCY_ROWS: usize = 500;
pub const DEFAULT_MAX_SNAPSHOT_BYTES: usize = 1024 * 1024;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ObservationKind {
    Request,
    HttpHeader,
    DatabaseRead,
    FileRead,
    TimeRead,
    RandomRead,
    EnvRead,
    NetworkResponse,
    DatabaseWrite,
    FileWrite,
    NetworkWrite,
    Unknown,
}

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

impl ObservationKind {
    pub fn is_replay_safe(&self) -> bool {
        matches!(
            self,
            Self::Request
                | Self::HttpHeader
                | Self::DatabaseRead
                | Self::FileRead
                | Self::TimeRead
                | Self::RandomRead
                | Self::EnvRead
                | Self::NetworkResponse
        )
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ContextObservation {
    pub kind: ObservationKind,
    pub target: String,
    pub value: Value,
    pub deterministic: bool,
}

impl ContextObservation {
    pub fn validate(&self) -> Result<(), String> {
        require_non_empty("observation.target", &self.target)?;
        if !self.kind.is_replay_safe() {
            return Err(format!(
                "observation target {} is not replay safe: {:?}",
                self.target, self.kind
            ));
        }
        if !self.deterministic {
            return Err(format!(
                "observation target {} was not captured deterministically",
                self.target
            ));
        }
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct TrafficSnapshot {
    pub contract_version: u32,
    pub snapshot_id: String,
    pub operation: String,
    pub captured_at_unix_ms: u64,
    pub payload: Value,
    pub observations: Vec<ContextObservation>,
    pub snapshot_hash: String,
}

impl TrafficSnapshot {
    pub fn new(
        snapshot_id: impl Into<String>,
        operation: impl Into<String>,
        captured_at_unix_ms: u64,
        payload: Value,
        observations: Vec<ContextObservation>,
    ) -> Result<Self, String> {
        let mut snapshot = Self {
            contract_version: LAZARUS_CONTRACT_VERSION,
            snapshot_id: snapshot_id.into(),
            operation: operation.into(),
            captured_at_unix_ms,
            payload,
            observations,
            snapshot_hash: String::new(),
        };
        snapshot.validate_without_hash()?;
        snapshot.snapshot_hash = snapshot.compute_hash()?;
        Ok(snapshot)
    }

    pub fn validate_hash(&self) -> Result<(), String> {
        self.validate_without_hash()?;
        let actual = self.compute_hash()?;
        if actual != self.snapshot_hash {
            return Err(format!(
                "snapshot hash mismatch: expected {}, actual {actual}",
                self.snapshot_hash
            ));
        }
        Ok(())
    }

    pub fn validate_replay_safe(&self) -> Result<(), String> {
        self.validate_hash()?;
        for observation in &self.observations {
            observation.validate()?;
        }
        Ok(())
    }

    pub fn pointer_root(&self) -> Value {
        serde_json::json!({
            "snapshot_id": self.snapshot_id,
            "operation": self.operation,
            "captured_at_unix_ms": self.captured_at_unix_ms,
            "payload": self.payload,
            "observations": self.observations,
        })
    }

    fn validate_without_hash(&self) -> Result<(), String> {
        if self.contract_version != LAZARUS_CONTRACT_VERSION {
            return Err(format!(
                "unsupported snapshot contract version: {}",
                self.contract_version
            ));
        }
        require_non_empty("snapshot_id", &self.snapshot_id)?;
        require_non_empty("operation", &self.operation)?;
        if !self.payload.is_object() {
            return Err("snapshot payload must be a JSON object".to_string());
        }
        Ok(())
    }

    fn compute_hash(&self) -> Result<String, String> {
        let material = SnapshotHashMaterial {
            contract_version: self.contract_version,
            snapshot_id: &self.snapshot_id,
            operation: &self.operation,
            captured_at_unix_ms: self.captured_at_unix_ms,
            payload: &self.payload,
            observations: &self.observations,
        };
        stable_hash(&material)
    }
}

#[derive(Serialize)]
struct SnapshotHashMaterial<'a> {
    contract_version: u32,
    snapshot_id: &'a str,
    operation: &'a str,
    captured_at_unix_ms: u64,
    payload: &'a Value,
    observations: &'a [ContextObservation],
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct HydrationPlan {
    pub operation: String,
    pub bindings: BTreeMap<String, String>,
    pub require_replay_safe_observations: bool,
    pub enforce_input_domain: bool,
}

impl HydrationPlan {
    pub fn new(operation: impl Into<String>, bindings: BTreeMap<String, String>) -> Self {
        Self {
            operation: operation.into(),
            bindings,
            require_replay_safe_observations: true,
            enforce_input_domain: true,
        }
    }

    pub fn validate_for_ir(&self, ir: &DecisionIr) -> Result<(), String> {
        require_non_empty("hydration operation", &self.operation)?;
        ir.validate_bounded()?;
        for name in ir
            .input_domains
            .keys()
            .filter(|name| name.as_str() != "__unit")
        {
            let pointer = self
                .bindings
                .get(name)
                .ok_or_else(|| format!("missing hydration binding for input: {name}"))?;
            if !pointer.starts_with('/') {
                return Err(format!(
                    "hydration binding for {name} must be a JSON Pointer, got {pointer}"
                ));
            }
        }
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct HydratedReplay {
    pub snapshot_id: String,
    pub snapshot_hash: String,
    pub request: ShadowRequest,
    pub payload_hash: String,
}

pub fn hydrate_snapshot(
    snapshot: &TrafficSnapshot,
    ir: &DecisionIr,
    plan: &HydrationPlan,
) -> Result<HydratedReplay, String> {
    plan.validate_for_ir(ir)?;
    if plan.require_replay_safe_observations {
        snapshot.validate_replay_safe()?;
    } else {
        snapshot.validate_hash()?;
    }

    let root = snapshot.pointer_root();
    let mut payload = Map::new();
    for (name, domain) in &ir.input_domains {
        if name == "__unit" {
            payload.insert(name.clone(), Value::from(0));
            continue;
        }
        let pointer = plan
            .bindings
            .get(name)
            .ok_or_else(|| format!("missing hydration binding for input: {name}"))?;
        let value = root
            .pointer(pointer)
            .ok_or_else(|| format!("snapshot pointer not found for {name}: {pointer}"))?;
        let value = value
            .as_i64()
            .ok_or_else(|| format!("hydration value for {name} must be i64"))?;
        if plan.enforce_input_domain && !domain.contains(&value) {
            return Err(format!(
                "hydrated value {value} for {name} is outside verified input domain"
            ));
        }
        payload.insert(name.clone(), Value::from(value));
    }

    let payload = Value::Object(payload);
    let request = ShadowRequest {
        request_id: snapshot.snapshot_id.clone(),
        operation: plan.operation.clone(),
        payload: payload.clone(),
    };
    request.validate()?;
    Ok(HydratedReplay {
        snapshot_id: snapshot.snapshot_id.clone(),
        snapshot_hash: snapshot.snapshot_hash.clone(),
        payload_hash: stable_hash(&payload)?,
        request,
    })
}

pub fn hydrate_snapshots(
    snapshots: &[TrafficSnapshot],
    ir: &DecisionIr,
    plan: &HydrationPlan,
) -> Result<Vec<HydratedReplay>, String> {
    snapshots
        .iter()
        .map(|snapshot| hydrate_snapshot(snapshot, ir, plan))
        .collect()
}

pub fn shadow_requests(replays: &[HydratedReplay]) -> Vec<ShadowRequest> {
    replays
        .iter()
        .map(|replay| replay.request.clone())
        .collect()
}

fn stable_hash<T: Serialize>(value: &T) -> Result<String, String> {
    let bytes = serde_json::to_vec(value).map_err(|error| error.to_string())?;
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    Ok(format!("{:x}", hasher.finalize()))
}

fn require_non_empty(field: &str, value: &str) -> Result<(), String> {
    if value.trim().is_empty() {
        Err(format!("{field} must not be empty"))
    } else {
        Ok(())
    }
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

#[cfg(test)]
mod tests {
    use super::*;
    use lazarus_contracts::DecisionExpr;

    #[test]
    fn hydrates_snapshot_payload_into_shadow_request() {
        let snapshot = TrafficSnapshot::new(
            "snap-1",
            "fee",
            1_700_000_000,
            serde_json::json!({"amount": 2, "trace": "ignored"}),
            vec![ContextObservation {
                kind: ObservationKind::DatabaseRead,
                target: "account.balance".to_string(),
                value: serde_json::json!({"balance": 100}),
                deterministic: true,
            }],
        )
        .unwrap();
        let ir = sample_ir(vec![0, 1, 2, 3]);
        let plan = HydrationPlan::new(
            "fee",
            BTreeMap::from([("amount".to_string(), "/payload/amount".to_string())]),
        );

        let replay = hydrate_snapshot(&snapshot, &ir, &plan).unwrap();

        assert_eq!(replay.request.request_id, "snap-1");
        assert_eq!(replay.request.payload, serde_json::json!({"amount": 2}));
        assert_eq!(replay.snapshot_hash, snapshot.snapshot_hash);
        assert_eq!(replay.payload_hash.len(), 64);
    }

    #[test]
    fn rejects_mutating_observation_before_shadow() {
        let snapshot = TrafficSnapshot::new(
            "snap-2",
            "fee",
            1,
            serde_json::json!({"amount": 2}),
            vec![ContextObservation {
                kind: ObservationKind::DatabaseWrite,
                target: "account.balance".to_string(),
                value: serde_json::json!({"delta": -10}),
                deterministic: true,
            }],
        )
        .unwrap();
        let plan = HydrationPlan::new(
            "fee",
            BTreeMap::from([("amount".to_string(), "/payload/amount".to_string())]),
        );

        let error = hydrate_snapshot(&snapshot, &sample_ir(vec![0, 1, 2]), &plan).unwrap_err();

        assert!(error.contains("not replay safe"));
    }

    #[test]
    fn rejects_domain_escape_not_covered_by_verification() {
        let snapshot = TrafficSnapshot::new(
            "snap-3",
            "fee",
            1,
            serde_json::json!({"amount": 99}),
            vec![],
        )
        .unwrap();
        let plan = HydrationPlan::new(
            "fee",
            BTreeMap::from([("amount".to_string(), "/payload/amount".to_string())]),
        );

        let error = hydrate_snapshot(&snapshot, &sample_ir(vec![0, 1, 2]), &plan).unwrap_err();

        assert!(error.contains("outside verified input domain"));
    }

    #[test]
    fn detects_snapshot_tampering() {
        let mut snapshot =
            TrafficSnapshot::new("snap-4", "fee", 1, serde_json::json!({"amount": 2}), vec![])
                .unwrap();
        snapshot.payload = serde_json::json!({"amount": 3});

        let error = snapshot.validate_hash().unwrap_err();

        assert!(error.contains("snapshot hash mismatch"));
    }

    #[test]
    fn can_hydrate_from_observation_pointer() {
        let snapshot = TrafficSnapshot::new(
            "snap-5",
            "fee",
            1,
            serde_json::json!({"request_id": "abc"}),
            vec![ContextObservation {
                kind: ObservationKind::DatabaseRead,
                target: "account.balance".to_string(),
                value: serde_json::json!({"balance": 7}),
                deterministic: true,
            }],
        )
        .unwrap();
        let plan = HydrationPlan::new(
            "fee",
            BTreeMap::from([(
                "amount".to_string(),
                "/observations/0/value/balance".to_string(),
            )]),
        );

        let replay = hydrate_snapshot(&snapshot, &sample_ir(vec![7]), &plan).unwrap();

        assert_eq!(replay.request.payload, serde_json::json!({"amount": 7}));
    }

    #[test]
    fn state_snapshot_accepts_masked_complete_capture() {
        let snapshot = sample_state_snapshot().unwrap();

        snapshot.validate_ingestable().unwrap();
        let projected = project_state_snapshot_to_traffic_snapshot(&snapshot).unwrap();

        assert_eq!(projected.operation, "fee");
        assert_eq!(
            projected.payload,
            serde_json::json!({"amount": 7, "card": "***"})
        );
        assert_eq!(projected.observations.len(), 1);
    }

    #[test]
    fn state_snapshot_rejects_unmasked_sensitive_fields() {
        let mut snapshot = sample_state_snapshot().unwrap();
        snapshot.upstream.body =
            serde_json::json!({"amount": 7, "card_number": "4111111111111111"});
        snapshot.snapshot_hash = snapshot.compute_hash().unwrap();

        let error = snapshot.validate_ingestable().unwrap_err();

        assert!(error.contains("sensitive field must be masked"));
    }

    #[test]
    fn state_snapshot_rejects_truncated_invalid_capture() {
        let mut snapshot = sample_state_snapshot().unwrap();
        snapshot.status = StateSnapshotStatus::TruncatedInvalid;
        snapshot.snapshot_hash = snapshot.compute_hash().unwrap();

        let error = snapshot.validate_ingestable().unwrap_err();

        assert!(error.contains("not complete"));
    }

    #[test]
    fn state_snapshot_rejects_row_limit_escape() {
        let mut snapshot = sample_state_snapshot().unwrap();
        snapshot.limits.max_dependency_rows = 1;
        snapshot.downstream_dependencies[0]
            .rows
            .push(BTreeMap::from([(
                "balance".to_string(),
                serde_json::json!(8),
            )]));
        snapshot.snapshot_hash = snapshot.compute_hash().unwrap();

        let error = snapshot.validate_ingestable().unwrap_err();

        assert!(error.contains("exceeds max_dependency_rows"));
    }

    fn sample_ir(domain: Vec<i64>) -> DecisionIr {
        DecisionIr {
            ir_id: "fee-ir".to_string(),
            source_unit_id: "bank/src/lib.rs".to_string(),
            input_domains: BTreeMap::from([("amount".to_string(), domain)]),
            expression: DecisionExpr::Mul {
                left: Box::new(DecisionExpr::Var {
                    name: "amount".to_string(),
                }),
                right: Box::new(DecisionExpr::Const { value: 2 }),
            },
            side_effects: Vec::new(),
            invariants: Vec::new(),
        }
    }

    fn sample_state_snapshot() -> Result<StateSnapshot, String> {
        StateSnapshot::new(StateSnapshotInput {
            snapshot_id: "snap-state-1".to_string(),
            trace_id: "trace-1".to_string(),
            operation: "fee".to_string(),
            context: SnapshotContext {
                captured_at_unix_ms: 1_700_000_000,
                epoch_unix_ms: 1_700_000_000,
                locale: Some("en_US".to_string()),
                principal: Some("user-1".to_string()),
                thread_name: Some("http-1".to_string()),
                env: BTreeMap::from([("JAVA_HOME".to_string(), serde_json::json!("/opt/jdk"))]),
            },
            upstream: UpstreamRequest {
                method: "POST".to_string(),
                uri: "/fee".to_string(),
                headers: BTreeMap::from([("authorization_token".to_string(), "***".to_string())]),
                body: serde_json::json!({"amount": 7, "card": "***"}),
                raw_body_sha256: None,
            },
            downstream_dependencies: vec![DownstreamDependency {
                dependency_id: "jdbc-1".to_string(),
                kind: DependencyKind::JdbcRead,
                target: "accounts".to_string(),
                query_or_request: Some("select balance from accounts where id = ?".to_string()),
                rows: vec![BTreeMap::from([(
                    "balance".to_string(),
                    serde_json::json!(7),
                )])],
                response: serde_json::json!(null),
                deterministic: true,
            }],
            mutation_intents: vec![MutationIntent {
                intent_id: "write-1".to_string(),
                kind: MutationKind::DbUpdate,
                target: "accounts".to_string(),
                statement_or_request: Some(
                    "update accounts set balance = ? where id = ?".to_string(),
                ),
                params: serde_json::json!({"account_id": 1, "card": "***"}),
            }],
            limits: SnapshotLimits::default(),
        })
    }
}
