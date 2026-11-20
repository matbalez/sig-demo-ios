// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

//! Eredu's MLX session is thread-affine. GDK receives complete semantic tool
//! calls and remains the sole owner of permission, dispatch and result handling.
use eredu::api::{
    GenerationRequest, LoadedModel, OutputMode, PlannedModel, PreparedChatGenerationSettings,
    PreparedChatInput,
};
use eredu::runtime::chat::{
    ChatTemplateRequest, NativeToolSupport, ParallelToolCallPolicy, PreparedChat, ToolChoice,
};
use eredu_backend_mlx::{backend::MlxBackend, native::MlxDrafter, MlxBackendFactory};
use eredu_core::{
    DevicePlan, ExecutionPlan, GenerationCancellationToken, GenerationConfigOverrides,
    RealizedDrafting, SemanticEvent,
};
use goose_provider_types::{
    base::MessageStream,
    conversation::{
        message::Message,
        token_usage::{ProviderUsage, Usage},
    },
    errors::ProviderError,
    formats::openai,
    images::ImageFormat,
};
use rmcp::model::{CallToolRequestParams, Tool};
use serde_json::{json, Value};
use std::sync::mpsc as worker;
use std::time::{Duration, Instant};
use tokio::sync::{mpsc, oneshot};

type Session = PlannedModel<MlxBackend<'static>, RealizedDrafting<MlxDrafter>>;
type Item = Result<(Option<Message>, Option<ProviderUsage>), ProviderError>;
type Measured = (usize, usize);

pub const MODEL_ID: &str = "lfm3-1.7b-q4-k-m";
const CONTEXT: usize = 8192;

fn error(e: impl std::fmt::Display) -> ProviderError {
    ProviderError::ExecutionError(format!("Eredu: {e}"))
}

enum Command {
    Generate(Turn),
    Drain(oneshot::Sender<()>),
    Shutdown(oneshot::Sender<()>),
}

struct Turn {
    system: String,
    messages: Vec<Message>,
    tools: Vec<Tool>,
    max_tokens: usize,
    cancellation: GenerationCancellationToken,
    output: mpsc::Sender<Item>,
    progress: Option<mpsc::UnboundedSender<crate::SigAgentEvent>>,
}

impl Turn {
    fn timing(&self, phase: &'static str, duration: Duration) {
        if let Some(events) = &self.progress {
            let _ = events.send(crate::SigAgentEvent::Timing {
                phase: phase.to_owned(),
                duration_ms: duration.as_millis().min(u64::MAX as u128) as u64,
            });
        }
    }
}

#[derive(Clone)]
pub struct Worker(worker::Sender<Command>);

struct CancelOnDrop(GenerationCancellationToken);
impl Drop for CancelOnDrop {
    fn drop(&mut self) {
        self.0.cancel()
    }
}

impl Worker {
    pub async fn start(
        path: String,
        cancel: GenerationCancellationToken,
    ) -> Result<(Self, Measured), ProviderError> {
        let (commands, receiver) = worker::channel();
        let (ready, result) = oneshot::channel();
        std::thread::Builder::new()
            .name("sig-local-metal".to_owned())
            .spawn(move || {
                let mut session = match load(&path) {
                    Ok(session) => session,
                    Err(error) => {
                        let _ = ready.send(Err(error));
                        return;
                    }
                };
                let (output, _unused) = mpsc::channel(8);
                let warmup = Turn {
                    system: String::new(),
                    messages: vec![Message::user().with_text("Hello")],
                    tools: Vec::new(),
                    max_tokens: 1,
                    cancellation: cancel.clone(),
                    output,
                    progress: None,
                };
                let measured = generate(&mut session, &warmup).and_then(|count| {
                    session.model_mut().synchronize().map_err(error)?;
                    if count.0 == 0 || count.1 == 0 || cancel.is_cancelled() {
                        return Err(error("Metal warmup did not complete"));
                    }
                    Ok(count)
                });
                let success = measured.is_ok();
                if ready.send(measured).is_err() || !success {
                    return;
                }
                while let Ok(command) = receiver.recv() {
                    match command {
                        Command::Generate(turn) => {
                            if let Err(e) = generate(&mut session, &turn) {
                                let _ = turn.output.blocking_send(Err(e));
                            }
                        }
                        Command::Shutdown(done) => {
                            drop(session);
                            let _ = done.send(());
                            return;
                        }
                        Command::Drain(done) => {
                            let _ = done.send(());
                        }
                    }
                }
            })
            .map_err(error)?;
        Ok((Self(commands), result.await.map_err(error)??))
    }

    pub fn stream(
        &self,
        system: &str,
        messages: &[Message],
        tools: &[Tool],
        max_tokens: usize,
        engine_cancel: &GenerationCancellationToken,
        progress: mpsc::UnboundedSender<crate::SigAgentEvent>,
    ) -> Result<MessageStream, ProviderError> {
        let (output, mut events) = mpsc::channel(32);
        let cancellation = GenerationCancellationToken::new().linked(engine_cancel);
        let guard = CancelOnDrop(cancellation.clone());
        self.0
            .send(Command::Generate(Turn {
                system: system.to_owned(),
                messages: messages.to_owned(),
                tools: tools.to_owned(),
                max_tokens,
                cancellation,
                output,
                progress: Some(progress),
            }))
            .map_err(|_| error("model worker stopped"))?;
        Ok(Box::pin(async_stream::stream! {
            let _guard = guard;
            while let Some(item) = events.recv().await { yield item; }
        }))
    }

    pub async fn shutdown(&self) {
        let (done, wait) = oneshot::channel();
        if self.0.send(Command::Shutdown(done)).is_ok() {
            let _ = wait.await;
        }
    }

    pub async fn drain(&self) {
        let (done, wait) = oneshot::channel();
        if self.0.send(Command::Drain(done)).is_ok() {
            let _ = wait.await;
        }
    }
}

fn load(path: &str) -> Result<Session, ProviderError> {
    #[cfg(target_os = "ios")]
    {
        // MLX defines the library path process-wide, before its first array.
        // New account or foreground sessions share that immutable bundle resource.
        static LIBRARY: std::sync::OnceLock<Result<(), String>> = std::sync::OnceLock::new();
        LIBRARY
            .get_or_init(|| {
                let bundle = std::env::current_exe().map_err(|e| e.to_string())?;
                let metallib = bundle.with_file_name("mlx.metallib");
                if !metallib.is_file() {
                    return Err("bundled mlx.metallib is missing".into());
                }
                eredu_backend_mlx::set_accelerator_library_path(metallib).map_err(|e| e.to_string())
            })
            .as_ref()
            .map_err(error)?;
    }
    eredu_backend_mlx::initialize_allocator_cache_policy(false).map_err(error)?;
    let plan = ExecutionPlan::fully_resident(DevicePlan::new("mlx", "metal:0").map_err(error)?);
    LoadedModel::load_execution_plan(&MlxBackendFactory::default(), path, &plan).map_err(error)
}

// The GDK formatter preserves tool IDs, responses and message visibility. Eredu's
// text checkpoint Jinja template expects text content and decoded argument objects.
fn prepare(
    session: &mut Session,
    system: &str,
    messages: &[Message],
    tools: &[Value],
) -> Result<PreparedChat, ProviderError> {
    let mut wire = Vec::new();
    if !system.is_empty() {
        wire.push(json!({"role": "system", "content": system}));
    }
    let visible: Vec<_> = messages
        .iter()
        .filter(|m| m.is_agent_visible())
        .cloned()
        .collect();
    for mut message in openai::format_messages(&visible, &ImageFormat::OpenAi) {
        if let Some(parts) = message["content"].as_array() {
            let text = parts
                .iter()
                .map(|part| {
                    part["text"]
                        .as_str()
                        .ok_or_else(|| error("expected text input for LFM3"))
                })
                .collect::<Result<Vec<_>, _>>()?
                .join("\n");
            message["content"] = Value::String(text);
        }
        if let Some(calls) = message["tool_calls"].as_array_mut() {
            for call in calls {
                if let Some(arguments) = call["function"]["arguments"].as_str() {
                    call["function"]["arguments"] =
                        serde_json::from_str(arguments).map_err(error)?;
                }
            }
        }
        wire.push(message);
    }
    let chat = session
        .model_mut()
        .prepare_chat(ChatTemplateRequest {
            messages: wire,
            tools: tools.to_vec(),
            tool_choice: if tools.is_empty() {
                ToolChoice::None
            } else {
                ToolChoice::Auto
            },
            parallel_tool_calls: ParallelToolCallPolicy::Disabled,
            // Match Sig's local GDK request and close the checkpoint's reasoning prefix.
            enable_thinking: Some(false),
            add_generation_prompt: true,
            ..Default::default()
        })
        .map_err(error)?;
    if !tools.is_empty() && !matches!(chat.native_tool_support(), NativeToolSupport::Supported) {
        return Err(error("checkpoint did not enable native tools"));
    }
    Ok(chat)
}

// Eredu accepts the standard function declaration. GDK's OpenAI transport
// additionally writes an API-specific "strict" flag which Eredu rejects.
fn tool_declarations(tools: &[Tool]) -> Vec<Value> {
    tools
        .iter()
        .map(|tool| {
            let mut function = json!({"name": tool.name, "parameters": tool.input_schema});
            if let Some(description) = &tool.description {
                function["description"] = json!(description);
            }
            json!({"type":"function", "function":function})
        })
        .collect()
}

#[cfg(all(target_os = "ios", feature = "ios-local-tool-probe"))]
fn log_probe_stage(stage: &str, tokens: usize) {
    if matches!(
        std::env::var("SIG_DEMO_LOCAL_PROBE_REPLY").as_deref(),
        Ok("pi-tools" | "search-tools")
    ) {
        if let Ok(m) = eredu_backend_mlx::allocator_memory() {
            eprintln!(
                "SIG_DEMO_LOCAL_NATIVE_STAGE={stage} tokens={tokens} active={} cached={} peak={}",
                m.active_bytes(),
                m.cached_bytes(),
                m.peak_bytes()
            );
        }
    }
}

fn generate(session: &mut Session, turn: &Turn) -> Result<Measured, ProviderError> {
    if turn.cancellation.is_cancelled() || turn.output.is_closed() {
        return Err(error("generation cancelled"));
    }
    #[cfg(all(target_os = "ios", feature = "ios-local-tool-probe"))]
    log_probe_stage("prepare", 0);
    let prepare_started = Instant::now();
    session.model_mut().reset().map_err(error)?;
    let tools = tool_declarations(&turn.tools);
    let mut pack = |messages: &[Message]| -> Result<_, ProviderError> {
        let chat = prepare(session, &turn.system, messages, &tools)?;
        let tokens = session
            .model()
            .encode(chat.rendered_prompt(), false)
            .map_err(error)?;
        Ok((chat, tokens))
    };
    let mut last = None;
    let messages = crate::context::fit_local_history(
        CONTEXT,
        &turn.messages,
        !tools.is_empty(),
        |candidate| {
            let (chat, tokens) = pack(candidate)?;
            let length = tokens.len();
            last = Some((candidate.to_vec(), chat, tokens));
            Ok(length)
        },
    )?;
    // Reuse the engine's rendered prompt and constraint grammar on the usual
    // fast path where all the eligible messages already fit.
    let (chat, tokens) = match last {
        Some((candidate, chat, tokens)) if messages == candidate => (chat, tokens),
        _ => pack(&messages)?,
    };
    let input_count = tokens.len();
    turn.timing("local-context-ready", prepare_started.elapsed());
    #[cfg(all(target_os = "ios", feature = "ios-local-tool-probe"))]
    log_probe_stage("generate", input_count);
    if input_count.saturating_add(turn.max_tokens) > CONTEXT {
        return Err(ProviderError::ContextLengthExceeded(
            "Local prompt exceeds the context window".into(),
        ));
    }
    let id = Message::assistant().with_generated_id().id;
    let mut rejected = false;
    let mut assistant_text = String::new();
    let mut requests = Vec::new();
    let generation_started = Instant::now();
    let mut saw_semantic_output = false;
    let output = session
        .generate(GenerationRequest {
            input: PreparedChatInput::token_ids(&chat, tokens),
            output_mode: OutputMode::Semantic,
            settings: PreparedChatGenerationSettings {
                // Bound peak Metal intermediates while preserving the full logical prompt.
                #[cfg(target_os = "ios")]
                prefill: eredu_core::PrefillChunkPolicy::Bounded(
                    std::num::NonZeroUsize::new(128).expect("128 is nonzero"),
                ),
                overrides: GenerationConfigOverrides {
                    // Liquid's recommended tool-calling sampling profile.
                    do_sample: Some(true),
                    temperature: Some(0.1),
                    top_k: Some(50),
                    repetition_penalty: Some(1.1),
                    max_new_tokens: Some(turn.max_tokens),
                    ..Default::default()
                },
                ..Default::default()
            },
            cancellation: turn.cancellation.clone(),
            caller_stop_sequences: &[],
            control_handle: None,
            on_event: |event| {
                // Emit stage timing only. Text and reasoning remain private until
                // native tool selection and visible-answer parsing finish.
                if !saw_semantic_output && !matches!(event, SemanticEvent::Finished { .. }) {
                    saw_semantic_output = true;
                    turn.timing("local-generating", generation_started.elapsed());
                }
                match event {
                    SemanticEvent::TextDelta(text) => assistant_text.push_str(&text),
                    SemanticEvent::ToolCallCompleted {
                        id,
                        name,
                        arguments,
                        ..
                    } => {
                        requests.push(Message::assistant().with_tool_request(
                            id,
                            Ok(CallToolRequestParams::new(name).with_arguments(arguments)),
                        ));
                    }
                    SemanticEvent::ToolCallRejected { .. } => rejected = true,
                    _ => {}
                }
            },
        })
        .map_err(error)?;
    if let Some(first) = output.timing().time_to_first_token() {
        turn.timing("local-first-token", first);
        turn.timing(
            "local-decode",
            generation_started.elapsed().saturating_sub(first),
        );
    }
    if rejected {
        return Err(error("model generated invalid tool arguments"));
    }
    if turn.cancellation.is_cancelled() {
        return Err(error("generation cancelled"));
    }
    // Hold the bounded turn until Eredu identifies whether it is a tool turn.
    // A tool turn delivers only its validated requests; GDK executes them and
    // obtains a separate final answer after the tool results arrive.
    if requests.is_empty() {
        let answer = visible_answer(&assistant_text);
        if !answer.trim().is_empty() {
            requests.push(Message::assistant().with_text(answer));
        }
    }
    for mut message in requests {
        message.id = id.clone();
        if turn
            .output
            .blocking_send(Ok((Some(message), None)))
            .is_err()
        {
            return Err(error("generation cancelled"));
        }
    }
    let output_count = output.token_ids.len();
    #[cfg(all(target_os = "ios", feature = "ios-local-tool-probe"))]
    log_probe_stage("complete", output_count);
    let usage = Usage::new(Some(input_count as i32), Some(output_count as i32), None);
    let _ = turn
        .output
        .blocking_send(Ok((None, Some(ProviderUsage::new(MODEL_ID.into(), usage)))));
    Ok((input_count, output_count))
}

// The checkpoint can resume reasoning from its assistant prefix even with
// thinking disabled, emitting only the closing marker in its completion.
// Supply that implicit opening to GDK's reasoning-channel parser.
fn visible_answer(text: &str) -> String {
    use goose_provider_types::thinking::split_think_blocks;
    if let Some(close) = text.find("</think>") {
        if text.find("<think>").is_none_or(|open| close < open) {
            return split_think_blocks(&format!("<think>{text}")).0;
        }
    }
    split_think_blocks(text).0
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn final_answer_excludes_generated_and_prefilled_reasoning() {
        for (raw, visible) in [
            ("plain answer", "plain answer"),
            ("<think>hidden</think>answer", "answer"),
            ("hidden</think>answer", "answer"),
            ("hidden</think>", ""),
            ("<think>incomplete", ""),
        ] {
            assert_eq!(visible_answer(raw), visible);
        }
    }
    #[test]
    fn gdk_tool_schema_is_passed_intact_in_eredus_function_envelope() {
        let schema = json!({"type":"object","properties":{"query":{"type":"string"},"freshness":{"type":"string","enum":["pm","py"]}},"required":["query"],"additionalProperties":false});
        let tool = Tool::new(
            "brave_web_search",
            "Look up public facts",
            std::sync::Arc::new(schema.as_object().unwrap().clone()),
        );
        assert_eq!(
            tool_declarations(&[tool]),
            vec![json!({
                "type":"function", "function":{"name":"brave_web_search", "description":"Look up public facts","parameters":schema}
            })]
        );
    }
}
