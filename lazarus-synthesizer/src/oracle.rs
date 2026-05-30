use crate::prompt::{CompiledPrompt, PromptCompiler, infer_prompt_stage};
use crate::types::{OracleCandidate, OracleClient, OraclePrompt};
use serde_json::{Value, json};
use std::env;
use std::fs;
use std::path::PathBuf;
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::runtime::Runtime;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OracleHttpProtocol {
    OpenAiResponses,
    OpenAiChat,
    OllamaGenerate,
}

impl OracleHttpProtocol {
    fn from_env_value(value: &str) -> Result<Self, String> {
        match value {
            "openai_responses" | "responses" => Ok(Self::OpenAiResponses),
            "openai_chat" | "chat_completions" | "chat" => Ok(Self::OpenAiChat),
            "ollama_generate" | "ollama" => Ok(Self::OllamaGenerate),
            _ => Err(format!(
                "unsupported LAZARUS_ORACLE_PROTOCOL: {value}; expected openai_responses, openai_chat, or ollama_generate"
            )),
        }
    }
}

#[derive(Clone, Debug)]
pub struct OracleHttpConfig {
    pub endpoint: String,
    pub api_key: String,
    pub model: String,
    pub protocol: OracleHttpProtocol,
    pub max_retries: usize,
    pub base_backoff_ms: u64,
    pub max_concurrency: usize,
    pub timeout_ms: u64,
    pub max_output_tokens: u64,
    pub max_prompt_chars: usize,
    pub log_dir: Option<PathBuf>,
}

impl OracleHttpConfig {
    pub fn openai_from_env() -> Result<Self, String> {
        let protocol = env::var("LAZARUS_ORACLE_PROTOCOL")
            .ok()
            .map(|value| OracleHttpProtocol::from_env_value(&value))
            .transpose()?
            .unwrap_or_else(|| {
                if env::var("LAZARUS_LM_ENDPOINT").is_ok() {
                    OracleHttpProtocol::OpenAiChat
                } else {
                    OracleHttpProtocol::OpenAiResponses
                }
            });
        let api_key = env::var("LAZARUS_ORACLE_API_KEY")
            .or_else(|_| env::var("LAZARUS_OPENAI_API_KEY"))
            .or_else(|_| env::var("LAZARUS_LM_API_KEY"))
            .unwrap_or_default();
        if protocol == OracleHttpProtocol::OpenAiResponses && api_key.trim().is_empty() {
            return Err(
                "LAZARUS_ORACLE_API_KEY is required for openai_responses protocol".to_string(),
            );
        }
        Ok(Self {
            endpoint: env::var("LAZARUS_ORACLE_ENDPOINT")
                .or_else(|_| env::var("LAZARUS_OPENAI_ENDPOINT"))
                .or_else(|_| env::var("LAZARUS_LM_ENDPOINT"))
                .unwrap_or_else(|_| default_oracle_endpoint(protocol).to_string()),
            api_key,
            model: env::var("LAZARUS_ORACLE_MODEL")
                .or_else(|_| env::var("LAZARUS_OPENAI_MODEL"))
                .or_else(|_| env::var("LAZARUS_LM_MODEL"))
                .unwrap_or_else(|_| "gpt-4.1".to_string()),
            protocol,
            max_retries: env::var("LAZARUS_ORACLE_MAX_RETRIES")
                .ok()
                .and_then(|value| value.parse().ok())
                .unwrap_or(3),
            base_backoff_ms: env::var("LAZARUS_ORACLE_BASE_BACKOFF_MS")
                .ok()
                .and_then(|value| value.parse().ok())
                .unwrap_or(250),
            max_concurrency: env::var("LAZARUS_ORACLE_MAX_CONCURRENCY")
                .ok()
                .and_then(|value| value.parse().ok())
                .unwrap_or(1),
            timeout_ms: env::var("LAZARUS_ORACLE_TIMEOUT_MS")
                .ok()
                .and_then(|value| value.parse().ok())
                .unwrap_or(60_000),
            max_output_tokens: env::var("LAZARUS_ORACLE_MAX_OUTPUT_TOKENS")
                .ok()
                .and_then(|value| value.parse().ok())
                .unwrap_or(2_048),
            max_prompt_chars: env::var("LAZARUS_ORACLE_MAX_PROMPT_CHARS")
                .ok()
                .and_then(|value| value.parse().ok())
                .unwrap_or(120_000),
            log_dir: env::var("LAZARUS_ORACLE_LOG_DIR").ok().map(PathBuf::from),
        })
    }
}

pub struct OpenAiOracleAdapter {
    client: reqwest::Client,
    config: OracleHttpConfig,
    prompt_compiler: PromptCompiler,
    limiter: ConcurrencyLimiter,
    runtime: Runtime,
}

impl OpenAiOracleAdapter {
    pub fn new(config: OracleHttpConfig, prompt_compiler: PromptCompiler) -> Result<Self, String> {
        let client = reqwest::Client::builder()
            .timeout(Duration::from_millis(config.timeout_ms))
            .build()
            .map_err(|error| error.to_string())?;
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_io()
            .enable_time()
            .build()
            .map_err(|error| error.to_string())?;
        Ok(Self {
            client,
            limiter: ConcurrencyLimiter::new(config.max_concurrency.max(1)),
            config,
            prompt_compiler,
            runtime,
        })
    }

    pub fn from_env() -> Result<Self, String> {
        Self::new(
            OracleHttpConfig::openai_from_env()?,
            PromptCompiler::default(),
        )
    }
}

impl OracleClient for OpenAiOracleAdapter {
    fn propose(&mut self, prompt: &OraclePrompt) -> Result<OracleCandidate, String> {
        let stage = infer_prompt_stage(&prompt.prior_feedback);
        let compiled = self.prompt_compiler.compile(stage, prompt)?;
        if compiled.text.chars().count() > self.config.max_prompt_chars {
            return Err(format!(
                "oracle prompt exceeds LAZARUS_ORACLE_MAX_PROMPT_CHARS: {} > {}",
                compiled.text.chars().count(),
                self.config.max_prompt_chars
            ));
        }
        let _permit = self.limiter.acquire();
        self.runtime.block_on(async {
            let mut last_error = None;
            for attempt in 0..=self.config.max_retries {
                match self.request_candidate(&compiled, attempt).await {
                    Ok(candidate) => return Ok(candidate),
                    Err(error) if error.retryable && attempt < self.config.max_retries => {
                        last_error = Some(error.message);
                        let multiplier = 1u64 << attempt.min(8);
                        let delay = self.config.base_backoff_ms.saturating_mul(multiplier);
                        tokio::time::sleep(Duration::from_millis(delay)).await;
                    }
                    Err(error) => return Err(error.message),
                }
            }
            Err(last_error.unwrap_or_else(|| "oracle request failed".to_string()))
        })
    }
}

impl OpenAiOracleAdapter {
    async fn request_candidate(
        &self,
        compiled: &CompiledPrompt,
        attempt: usize,
    ) -> Result<OracleCandidate, OracleHttpError> {
        let request_body = oracle_request_body(&self.config, &compiled.text);
        let mut request = self.client.post(&self.config.endpoint).json(&request_body);
        if !self.config.api_key.trim().is_empty() {
            request = request.bearer_auth(&self.config.api_key);
        }
        let response = tokio::time::timeout(
            Duration::from_millis(self.config.timeout_ms),
            request.send(),
        )
        .await
        .map_err(|_| OracleHttpError::retryable("oracle request timed out".to_string()))?
        .map_err(|error| OracleHttpError::retryable(error.to_string()))?;
        let status = response.status();
        let body_text = response
            .text()
            .await
            .map_err(|error| OracleHttpError::retryable(error.to_string()))?;
        self.write_oracle_log(
            compiled,
            attempt,
            status.as_u16(),
            &request_body,
            &body_text,
        )
        .map_err(OracleHttpError::fatal)?;
        if !status.is_success() {
            let message = format!("oracle HTTP {}: {}", status.as_u16(), body_text);
            if is_retryable_http_status(status.as_u16()) {
                return Err(OracleHttpError::retryable(message));
            }
            return Err(OracleHttpError::fatal(message));
        }
        let body: Value = serde_json::from_str(&body_text)
            .map_err(|error| OracleHttpError::fatal(format!("invalid oracle JSON: {error}")))?;
        let text = extract_oracle_text(&body, self.config.protocol)
            .ok_or_else(|| OracleHttpError::fatal(format!("missing oracle text: {body}")))?;
        let rust_source = extract_rust_source(&text);
        Ok(OracleCandidate {
            rust_source,
            rationale: format!(
                "{:?} response via {}",
                self.config.protocol, self.config.model
            ),
        })
    }

    fn write_oracle_log(
        &self,
        compiled: &CompiledPrompt,
        attempt: usize,
        status: u16,
        request_body: &Value,
        response_body: &str,
    ) -> Result<(), String> {
        let Some(log_dir) = &self.config.log_dir else {
            return Ok(());
        };
        fs::create_dir_all(log_dir).map_err(|error| error.to_string())?;
        let now_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_millis())
            .unwrap_or_default();
        let path = log_dir.join(format!(
            "oracle-{}-{}-attempt-{}.json",
            now_ms, compiled.prompt_hash, attempt
        ));
        let record = json!({
            "timestamp_ms": now_ms,
            "endpoint": self.config.endpoint,
            "model": self.config.model,
            "stage": compiled.stage,
            "prompt_hash": compiled.prompt_hash,
            "attempt": attempt,
            "status": status,
            "request": request_body,
            "response_body": response_body,
        });
        fs::write(
            path,
            serde_json::to_vec_pretty(&record).map_err(|error| error.to_string())?,
        )
        .map_err(|error| error.to_string())
    }
}

#[derive(Clone)]
struct ConcurrencyLimiter {
    state: Arc<(Mutex<usize>, Condvar)>,
    max: usize,
}

impl ConcurrencyLimiter {
    fn new(max: usize) -> Self {
        Self {
            state: Arc::new((Mutex::new(0), Condvar::new())),
            max,
        }
    }

    fn acquire(&self) -> ConcurrencyPermit {
        let (lock, condvar) = &*self.state;
        let mut in_flight = lock.lock().expect("limiter mutex poisoned");
        while *in_flight >= self.max {
            in_flight = condvar.wait(in_flight).expect("limiter mutex poisoned");
        }
        *in_flight += 1;
        ConcurrencyPermit {
            state: Arc::clone(&self.state),
        }
    }
}

struct ConcurrencyPermit {
    state: Arc<(Mutex<usize>, Condvar)>,
}

impl Drop for ConcurrencyPermit {
    fn drop(&mut self) {
        let (lock, condvar) = &*self.state;
        let mut in_flight = lock.lock().expect("limiter mutex poisoned");
        *in_flight = in_flight.saturating_sub(1);
        condvar.notify_one();
    }
}

struct OracleHttpError {
    message: String,
    retryable: bool,
}

impl OracleHttpError {
    fn retryable(message: String) -> Self {
        Self {
            message,
            retryable: true,
        }
    }

    fn fatal(message: String) -> Self {
        Self {
            message,
            retryable: false,
        }
    }
}

fn default_oracle_endpoint(protocol: OracleHttpProtocol) -> &'static str {
    match protocol {
        OracleHttpProtocol::OpenAiResponses => "https://api.openai.com/v1/responses",
        OracleHttpProtocol::OpenAiChat => "http://127.0.0.1:1234/v1/chat/completions",
        OracleHttpProtocol::OllamaGenerate => "http://127.0.0.1:11434/api/generate",
    }
}

pub(crate) fn oracle_request_body(config: &OracleHttpConfig, prompt: &str) -> Value {
    match config.protocol {
        OracleHttpProtocol::OpenAiResponses => json!({
            "model": config.model,
            "input": prompt,
            "temperature": 0.0,
            "max_output_tokens": config.max_output_tokens,
            "store": false
        }),
        OracleHttpProtocol::OpenAiChat => json!({
            "model": config.model,
            "messages": [
                {
                    "role": "user",
                    "content": prompt
                }
            ],
            "temperature": 0.0,
            "max_tokens": config.max_output_tokens
        }),
        OracleHttpProtocol::OllamaGenerate => json!({
            "model": config.model,
            "prompt": prompt,
            "stream": false,
            "options": {
                "temperature": 0.0,
                "num_predict": config.max_output_tokens
            }
        }),
    }
}

pub(crate) fn extract_oracle_text(value: &Value, protocol: OracleHttpProtocol) -> Option<String> {
    match protocol {
        OracleHttpProtocol::OpenAiResponses => extract_openai_text(value),
        OracleHttpProtocol::OpenAiChat => extract_openai_chat_text(value),
        OracleHttpProtocol::OllamaGenerate => value
            .get("response")
            .and_then(Value::as_str)
            .map(str::to_string),
    }
}

fn extract_openai_text(value: &Value) -> Option<String> {
    if let Some(text) = value.get("output_text").and_then(Value::as_str) {
        return Some(text.to_string());
    }
    let output = value.get("output")?.as_array()?;
    let mut text = String::new();
    for item in output {
        if let Some(content) = item.get("content").and_then(Value::as_array) {
            for part in content {
                if let Some(part_text) = part.get("text").and_then(Value::as_str) {
                    text.push_str(part_text);
                    text.push('\n');
                }
            }
        }
    }
    if text.trim().is_empty() {
        None
    } else {
        Some(text)
    }
}

fn extract_openai_chat_text(value: &Value) -> Option<String> {
    let choices = value.get("choices")?.as_array()?;
    let mut text = String::new();
    for choice in choices {
        if let Some(content) = choice
            .get("message")
            .and_then(|message| message.get("content"))
            .and_then(Value::as_str)
        {
            text.push_str(content);
            text.push('\n');
        }
    }
    if text.trim().is_empty() {
        None
    } else {
        Some(text)
    }
}

pub(crate) fn extract_rust_source(text: &str) -> String {
    if let Some(source) = extract_fenced_block(text, "```rust") {
        return source;
    }
    if let Some(source) = extract_fenced_block(text, "```") {
        return source;
    }
    text.trim().to_string()
}

fn extract_fenced_block(text: &str, marker: &str) -> Option<String> {
    let start = text.find(marker)?;
    let after_marker = &text[start + marker.len()..];
    let after_newline = after_marker
        .strip_prefix('\n')
        .or_else(|| after_marker.strip_prefix("\r\n"))
        .unwrap_or(after_marker);
    let end = after_newline.find("```")?;
    Some(after_newline[..end].trim().to_string())
}

fn is_retryable_http_status(status: u16) -> bool {
    matches!(status, 429 | 500 | 502 | 503 | 504)
}
