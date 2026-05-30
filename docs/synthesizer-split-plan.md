# Lazarus Synthesizer Split Plan

## Objective

Split `lazarus-synthesizer/src/lib.rs` without changing the public API or runtime behavior.

The split must reduce regression blast radius before adding more oracle providers or prompt strategies.

## Current Evidence

- `lazarus-synthesizer/src/lib.rs` is 1751 lines.
- It currently contains:
  - public synthesis domain types;
  - prompt compilation and snapshot minification;
  - Java method to snapshot correlation;
  - OpenAI-compatible and Ollama HTTP adapter;
  - local concurrency limiter;
  - source safety and maintainability policy;
  - corpus train/blind splitting;
  - rustc Wasm compilation;
  - semantic validation;
  - test fixtures.

## Non-Negotiables

1. Preserve all existing public names and signatures:
   - `SynthesizerConfig`
   - `SynthesisInput`
   - `OracleClient`
   - `OpenAiOracleAdapter`
   - `PromptCompiler`
   - `synthesize_with_oracle`
   - `validate_source_policy`
   - `analyze_maintainability`
   - `correlate_snapshots_by_trace_tag`
2. Do not change CLI behavior.
3. Do not alter prompt template file paths.
4. Do not alter oracle environment variable names.
5. Run `cargo test -p lazarus-synthesizer --all-targets` after every move.

## Target Module Map

```text
lazarus-synthesizer/src/
  lib.rs
  types.rs
  prompt.rs
  correlator.rs
  oracle.rs
  safety.rs
  corpus.rs
  artifact.rs
  validation.rs
  hash.rs
  tests.rs
```

### `types.rs`

Owns public domain types and constants:

- `DEFAULT_MAX_ITERATIONS`
- `DEFAULT_TRAINING_PERCENT`
- `DEFAULT_SYNTHESIS_FUEL`
- `SynthesisVerdict`
- `SynthesizerConfig`
- `BehaviorCase`
- `SynthesisInput`
- `OracleFeedback`
- `OraclePrompt`
- `OracleCandidate`
- `PromptStage`
- `CompileFailure`
- `SemanticMismatch`
- `CorpusSplit`
- `IterationReport`
- `SynthesisReport`

Visibility:

- Keep currently public items `pub`.
- Helper validation calls may use `crate::util` or remain in `types.rs`.

### `prompt.rs`

Owns prompt compilation and snapshot trimming:

- `PromptCompilerConfig`
- `CompiledPrompt`
- `PromptCompiler`
- `render_prompt_template`
- `infer_prompt_stage`
- `minify_state_snapshot`
- `truncate_value`
- `trim_feedback`
- `truncate_str`
- template constants using `include_str!`.

Visibility:

- `PromptCompilerConfig`, `CompiledPrompt`, `PromptCompiler` stay public.
- Internal helpers become `pub(crate)` only if used by tests or oracle.

### `correlator.rs`

Owns source/snapshot routing:

- `JavaMethodSource`
- `MethodCorpus`
- `correlate_snapshots_by_trace_tag`

Visibility:

- Preserve all current public names.

### `oracle.rs`

Owns oracle protocol and HTTP adapter:

- `OracleClient`
- `OracleHttpProtocol`
- `OracleHttpConfig`
- `OpenAiOracleAdapter`
- `ConcurrencyLimiter`
- `ConcurrencyPermit`
- `OracleHttpError`
- `default_oracle_endpoint`
- `oracle_request_body`
- `extract_oracle_text`
- `extract_openai_text`
- `extract_openai_chat_text`
- `extract_rust_source`
- `extract_fenced_block`
- `is_retryable_http_status`

Visibility:

- Public protocol/config/adapter remain `pub`.
- Extraction helpers stay private, with tests moved into `oracle` test module or `tests.rs`.

### `safety.rs`

Owns generated source quality gates:

- `SourcePolicyReport`
- `MaintainabilityReport`
- `validate_source_policy`
- `analyze_maintainability`
- `count_branch_tokens`
- source policy constants.

Visibility:

- Public reports and functions remain `pub`.
- `count_branch_tokens` private.

### `corpus.rs`

Owns training/blind split:

- `CorpusPlan`
- `split_corpus`
- `split_items`

Visibility:

- `CorpusPlan` and functions should be `pub(crate)`.

### `artifact.rs`

Owns rustc compile handoff:

- `compile_candidate_source`

Visibility:

- `pub(crate)`.

### `validation.rs`

Owns behavior-case execution against Wasm:

- `validate_cases`
- `summarize_mismatches`

Visibility:

- `pub(crate)`.

### `hash.rs`

Owns stable hashing:

- `stable_hash_bytes`

Visibility:

- `pub(crate)`.

### `lib.rs`

Becomes the public facade and orchestration owner:

- module declarations;
- public re-exports;
- `synthesize_with_oracle`;
- minimal helpers only if required.

Expected shape:

```rust
mod artifact;
mod correlator;
mod corpus;
mod hash;
mod oracle;
mod prompt;
mod safety;
mod types;
mod validation;

pub use correlator::{correlate_snapshots_by_trace_tag, JavaMethodSource, MethodCorpus};
pub use oracle::{OpenAiOracleAdapter, OracleClient, OracleHttpConfig, OracleHttpProtocol};
pub use prompt::{CompiledPrompt, PromptCompiler, PromptCompilerConfig};
pub use safety::{analyze_maintainability, validate_source_policy, MaintainabilityReport, SourcePolicyReport};
pub use types::*;
```

## Move Order

1. Move pure constants and data types to `types.rs`.
   - Run `cargo test -p lazarus-synthesizer --all-targets`.
2. Move `stable_hash_bytes` to `hash.rs`.
   - Run tests.
3. Move safety policy to `safety.rs`.
   - Run tests.
4. Move corpus split to `corpus.rs`.
   - Run tests.
5. Move artifact compile and validation functions to `artifact.rs` and `validation.rs`.
   - Run tests.
6. Move prompt compiler and templates to `prompt.rs`.
   - Run tests.
7. Move HTTP oracle adapter to `oracle.rs`.
   - Run tests.
8. Move trace correlator to `correlator.rs`.
   - Run tests.
9. Move test fixtures into `tests.rs` or keep test modules colocated by concern.
   - Run `cargo test -p lazarus-synthesizer --all-targets`.
10. Run workspace gate:
   - `bash scripts/validate_all.sh`

## Failure Guards

- If a move causes widespread `E0432 unresolved import`, stop and re-export from `lib.rs` instead of widening visibility everywhere.
- Prefer `pub(crate)` over `pub` for internal helpers.
- Do not change `OracleHttpConfig::openai_from_env` behavior during the split.
- Do not change `PromptCompiler` template rendering semantics during the split.
- Do not change `synthesize_with_oracle` loop logic during the split.

## Acceptance Criteria

- `cargo test -p lazarus-synthesizer --all-targets` passes after each phase.
- `bash scripts/validate_all.sh` passes after the final split.
- `RUN_LOCAL_LM_SMOKE=1 LAZARUS_LM_MODEL='huihui-ai/qwen/claude-4.7-opus--q8_0.gguf' bash scripts/validate_all.sh` remains a valid manual smoke.
- Public API consumers, especially `genesis-cli`, compile without source changes except import formatting if required.

## Explicit Non-Goals

- No new oracle provider.
- No prompt template rewrite.
- No behavior change in source policy.
- No CLI command refactor in the same branch.
- No release stress or NVD scan coupling to this branch.
