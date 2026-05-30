use lazarus_contracts::DecisionIr;
use lazarus_shadow_runner::ShadowRequest;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::collections::BTreeMap;

use crate::{TrafficSnapshot, require_non_empty, stable_hash};

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
