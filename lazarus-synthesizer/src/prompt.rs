use crate::hash::stable_hash_bytes;
use crate::types::{OracleFeedback, OraclePrompt, PromptStage};
use lazarus_breakwater::StateSnapshot;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PromptCompilerConfig {
    pub max_snapshot_bytes: usize,
    pub max_rows_per_dependency: usize,
    pub max_headers: usize,
    pub max_string_bytes: usize,
    pub max_feedback_chars: usize,
    pub max_legacy_source_chars: usize,
}

impl Default for PromptCompilerConfig {
    fn default() -> Self {
        Self {
            max_snapshot_bytes: 32 * 1024,
            max_rows_per_dependency: 5,
            max_headers: 16,
            max_string_bytes: 2048,
            max_feedback_chars: 12 * 1024,
            max_legacy_source_chars: 64 * 1024,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CompiledPrompt {
    pub stage: PromptStage,
    pub text: String,
    pub prompt_hash: String,
}

#[derive(Clone, Debug)]
pub struct PromptCompiler {
    config: PromptCompilerConfig,
    initial_generation_template: String,
    compile_fix_template: String,
    semantic_fix_template: String,
}

impl Default for PromptCompiler {
    fn default() -> Self {
        Self {
            config: PromptCompilerConfig::default(),
            initial_generation_template: INITIAL_GENERATION_TEMPLATE.to_string(),
            compile_fix_template: COMPILE_FIX_TEMPLATE.to_string(),
            semantic_fix_template: SEMANTIC_FIX_TEMPLATE.to_string(),
        }
    }
}

impl PromptCompiler {
    pub fn new(config: PromptCompilerConfig) -> Self {
        Self {
            config,
            ..Self::default()
        }
    }

    pub fn with_template(mut self, stage: PromptStage, template: impl Into<String>) -> Self {
        match stage {
            PromptStage::InitialGeneration => self.initial_generation_template = template.into(),
            PromptStage::CompileFix => self.compile_fix_template = template.into(),
            PromptStage::SemanticFix => self.semantic_fix_template = template.into(),
        }
        self
    }

    pub fn compile(
        &self,
        stage: PromptStage,
        prompt: &OraclePrompt,
    ) -> Result<CompiledPrompt, String> {
        let snapshots = prompt
            .visible_state_snapshots
            .iter()
            .map(|snapshot| minify_state_snapshot(snapshot, &self.config))
            .collect::<Vec<_>>();
        let snapshots_json =
            serde_json::to_string_pretty(&snapshots).map_err(|error| error.to_string())?;
        let cases_json = serde_json::to_string_pretty(&prompt.visible_behavior_cases)
            .map_err(|error| error.to_string())?;
        let feedback_json = serde_json::to_string_pretty(&trim_feedback(
            &prompt.prior_feedback,
            self.config.max_feedback_chars,
        ))
        .map_err(|error| error.to_string())?;
        let input_order_json =
            serde_json::to_string(&prompt.input_order).map_err(|error| error.to_string())?;
        let legacy_source =
            truncate_str(&prompt.legacy_source, self.config.max_legacy_source_chars);
        let template = match stage {
            PromptStage::InitialGeneration => &self.initial_generation_template,
            PromptStage::CompileFix => &self.compile_fix_template,
            PromptStage::SemanticFix => &self.semantic_fix_template,
        };
        let text = render_prompt_template(
            template,
            minijinja::context! {
                iteration => prompt.iteration,
                function_name => prompt.function_name,
                input_order_json => input_order_json,
                legacy_source => legacy_source,
                snapshots_json => snapshots_json,
                behavior_cases_json => cases_json,
                prior_feedback_json => feedback_json,
            },
        )?;
        let prompt_hash = stable_hash_bytes(text.as_bytes());
        Ok(CompiledPrompt {
            stage,
            text,
            prompt_hash,
        })
    }
}

pub(crate) fn infer_prompt_stage(feedback: &[OracleFeedback]) -> PromptStage {
    match feedback.last().map(|item| item.kind.as_str()) {
        Some("compile_error") => PromptStage::CompileFix,
        Some("semantic_mismatch") => PromptStage::SemanticFix,
        _ => PromptStage::InitialGeneration,
    }
}

fn render_prompt_template<S: Serialize>(template: &str, context: S) -> Result<String, String> {
    let mut env = minijinja::Environment::new();
    env.add_template("prompt", template)
        .map_err(|error| error.to_string())?;
    env.get_template("prompt")
        .map_err(|error| error.to_string())?
        .render(context)
        .map_err(|error| error.to_string())
}

fn minify_state_snapshot(snapshot: &StateSnapshot, config: &PromptCompilerConfig) -> Value {
    let headers = snapshot
        .upstream
        .headers
        .iter()
        .take(config.max_headers)
        .map(|(key, value)| {
            (
                key.clone(),
                Value::String(truncate_str(value, config.max_string_bytes)),
            )
        })
        .collect::<Map<_, _>>();
    let dependencies = snapshot
        .downstream_dependencies
        .iter()
        .map(|dependency| {
            let rows = dependency
                .rows
                .iter()
                .take(config.max_rows_per_dependency)
                .map(|row| {
                    row.iter()
                        .map(|(key, value)| {
                            (key.clone(), truncate_value(value, config.max_string_bytes))
                        })
                        .collect::<Map<_, _>>()
                })
                .collect::<Vec<_>>();
            let row_count_visible = rows.len();
            let row_count_captured = dependency.rows.len();
            json!({
                "dependency_id": &dependency.dependency_id,
                "kind": &dependency.kind,
                "target": &dependency.target,
                "query_or_request": &dependency.query_or_request,
                "rows": rows,
                "row_count_visible": row_count_visible,
                "row_count_captured": row_count_captured,
                "response": truncate_value(&dependency.response, config.max_string_bytes),
                "deterministic": dependency.deterministic
            })
        })
        .collect::<Vec<_>>();
    let mutations = snapshot
        .mutation_intents
        .iter()
        .map(|intent| {
            json!({
                "intent_id": &intent.intent_id,
                "kind": &intent.kind,
                "target": &intent.target,
                "statement_or_request": &intent.statement_or_request,
                "params": truncate_value(&intent.params, config.max_string_bytes)
            })
        })
        .collect::<Vec<_>>();
    let mut compact = json!({
        "snapshot_id": &snapshot.snapshot_id,
        "trace_id": &snapshot.trace_id,
        "operation": &snapshot.operation,
        "status": &snapshot.status,
        "trace_tags": &snapshot.trace_tags,
        "context": {
            "locale": &snapshot.context.locale,
            "principal": &snapshot.context.principal,
            "thread_name": &snapshot.context.thread_name
        },
        "upstream": {
            "method": &snapshot.upstream.method,
            "uri": &snapshot.upstream.uri,
            "headers": headers,
            "body": truncate_value(&snapshot.upstream.body, config.max_string_bytes),
            "raw_body_sha256": &snapshot.upstream.raw_body_sha256
        },
        "downstream_dependencies": dependencies,
        "mutation_intents": mutations
    });
    while serde_json::to_vec(&compact).map_or(usize::MAX, |bytes| bytes.len())
        > config.max_snapshot_bytes
    {
        let Some(deps) = compact
            .get_mut("downstream_dependencies")
            .and_then(Value::as_array_mut)
        else {
            break;
        };
        if deps.pop().is_none() {
            compact["upstream"]["body"] = Value::String("<truncated>".to_string());
            break;
        }
    }
    compact
}

fn truncate_value(value: &Value, max_string_bytes: usize) -> Value {
    match value {
        Value::String(text) => Value::String(truncate_str(text, max_string_bytes)),
        Value::Array(items) => Value::Array(
            items
                .iter()
                .take(32)
                .map(|item| truncate_value(item, max_string_bytes))
                .collect(),
        ),
        Value::Object(map) => Value::Object(
            map.iter()
                .take(64)
                .map(|(key, value)| (key.clone(), truncate_value(value, max_string_bytes)))
                .collect(),
        ),
        other => other.clone(),
    }
}

fn trim_feedback(feedback: &[OracleFeedback], max_chars: usize) -> Vec<OracleFeedback> {
    feedback
        .iter()
        .rev()
        .take(4)
        .rev()
        .map(|item| OracleFeedback {
            kind: item.kind.clone(),
            message: truncate_str(&item.message, max_chars),
        })
        .collect()
}

fn truncate_str(value: &str, max_chars: usize) -> String {
    if value.chars().count() <= max_chars {
        return value.to_string();
    }
    let mut truncated = value.chars().take(max_chars).collect::<String>();
    truncated.push_str("\n<truncated>");
    truncated
}

const INITIAL_GENERATION_TEMPLATE: &str = include_str!("../templates/initial_synthesis.jinja");
const COMPILE_FIX_TEMPLATE: &str = include_str!("../templates/compile_feedback.jinja");
const SEMANTIC_FIX_TEMPLATE: &str = include_str!("../templates/semantic_feedback.jinja");
