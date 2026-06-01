use genesis_platform::desktop::DesktopPlatformAdapter;
use genesis_platform::{PlatformAdapter, RuntimeProfile};
use std::time::Duration;

const DEFAULT_SENSE_URL: &str = "http://127.0.0.1:4767/state";

pub fn build_tick_payload(tick_id: u64, last_outcome: Option<serde_json::Value>) -> String {
    let sense_url = std::env::var("GENESIS_SENSE_URL").unwrap_or_else(|_| DEFAULT_SENSE_URL.into());
    let sense_key =
        std::env::var("GENESIS_SENSE_KEY").unwrap_or_else(|_| default_sense_key(&sense_url));

    let mut context = serde_json::Map::new();
    context.insert("tick_id".to_string(), serde_json::json!(tick_id));
    context.insert(
        "signal".to_string(),
        serde_json::json!(format!("第 {} 波高频电流", tick_id)),
    );
    context.insert(
        sense_key,
        read_state_url(&sense_url).unwrap_or(serde_json::Value::Null),
    );
    if let Ok(goal) = std::env::var("GENESIS_MACRO_GOAL")
        && !goal.trim().is_empty()
    {
        context.insert("macro_goal".to_string(), serde_json::json!(goal));
    }
    if let Some(outcome) = last_outcome {
        context.insert("last_outcome".to_string(), outcome);
    }

    serde_json::to_string(&context).unwrap_or_else(|_| {
        format!(
            "{{\"tick_id\":{},\"signal\":\"第 {} 波高频电流\"}}",
            tick_id, tick_id
        )
    })
}

pub fn attach_last_outcome(payload: &str, outcome: serde_json::Value) -> String {
    attach_value(payload, "last_outcome", outcome)
}

pub fn attach_active_step(payload: &str, active_step: serde_json::Value) -> String {
    attach_value(payload, "active_step", active_step)
}

fn attach_value(payload: &str, key: &str, value_to_attach: serde_json::Value) -> String {
    let Ok(mut value) = serde_json::from_str::<serde_json::Value>(payload) else {
        return payload.to_string();
    };
    let Some(context) = value.as_object_mut() else {
        return payload.to_string();
    };

    context.insert(key.to_string(), value_to_attach);
    serde_json::to_string(context).unwrap_or_else(|_| payload.to_string())
}

const MAX_RESPONSE_BODY: usize = 1_048_576; // 1 MB

fn read_state_url(url: &str) -> Option<serde_json::Value> {
    let adapter = DesktopPlatformAdapter::legacy_runtime(RuntimeProfile::DesktopSafe);
    let body = adapter
        .http_get(url, Duration::from_millis(8), MAX_RESPONSE_BODY)
        .ok()?;
    serde_json::from_slice(&body).ok()
}

fn default_sense_key(url: &str) -> String {
    if url.contains("127.0.0.1:4767") || url.contains("localhost:4767") {
        "fantasy_state".to_string()
    } else {
        "web_state".to_string()
    }
}
