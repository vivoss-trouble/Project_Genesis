mod hydration;
mod state_snapshot;

use lazarus_contracts::LAZARUS_CONTRACT_VERSION;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest as _, Sha256};

pub use hydration::{
    HydratedReplay, HydrationPlan, hydrate_snapshot, hydrate_snapshots, shadow_requests,
};
pub use state_snapshot::{
    DependencyKind, DownstreamDependency, MutationIntent, MutationKind, SnapshotContext,
    SnapshotLimits, StateSnapshot, StateSnapshotInput, StateSnapshotStatus, UpstreamRequest,
    project_state_snapshot_to_traffic_snapshot,
};

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

pub(crate) fn stable_hash<T: Serialize>(value: &T) -> Result<String, String> {
    let bytes = serde_json::to_vec(value).map_err(|error| error.to_string())?;
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    Ok(format!("{:x}", hasher.finalize()))
}

pub(crate) fn require_non_empty(field: &str, value: &str) -> Result<(), String> {
    if value.trim().is_empty() {
        Err(format!("{field} must not be empty"))
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use lazarus_contracts::{DecisionExpr, DecisionIr};
    use std::collections::BTreeMap;

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
