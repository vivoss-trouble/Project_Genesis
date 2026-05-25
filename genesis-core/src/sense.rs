use std::io::{Read, Write};
use std::net::TcpStream;
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
    let Ok(mut value) = serde_json::from_str::<serde_json::Value>(payload) else {
        return payload.to_string();
    };
    let Some(context) = value.as_object_mut() else {
        return payload.to_string();
    };

    context.insert("last_outcome".to_string(), outcome);
    serde_json::to_string(context).unwrap_or_else(|_| payload.to_string())
}

fn read_state_url(url: &str) -> Option<serde_json::Value> {
    let (host, port, path) = parse_http_url(url)?;
    let mut stream = TcpStream::connect((host.as_str(), port)).ok()?;
    let _ = stream.set_read_timeout(Some(Duration::from_millis(8)));
    let _ = stream.set_write_timeout(Some(Duration::from_millis(4)));

    let request = format!("GET {path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n");
    stream.write_all(request.as_bytes()).ok()?;

    let mut response = String::new();
    stream.read_to_string(&mut response).ok()?;
    let (_, body) = response.split_once("\r\n\r\n")?;
    serde_json::from_str(body).ok()
}

fn parse_http_url(url: &str) -> Option<(String, u16, String)> {
    let stripped = url.strip_prefix("http://")?;
    let (authority, path) = stripped.split_once('/').unwrap_or((stripped, ""));
    let (host, port) = authority
        .split_once(':')
        .map(|(host, port)| (host, port.parse::<u16>().ok()))
        .map(|(host, port)| Some((host.to_string(), port?)))
        .unwrap_or_else(|| Some((authority.to_string(), 80)))?;

    Some((host, port, format!("/{path}")))
}

fn default_sense_key(url: &str) -> String {
    if url.contains("127.0.0.1:4767") || url.contains("localhost:4767") {
        "fantasy_state".to_string()
    } else {
        "web_state".to_string()
    }
}
