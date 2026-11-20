// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only
//! Account-scoped direct GDK local inference. No HTTP server or external process.
use futures::StreamExt;
use goose_local_inference::{config_resolver, evict_model, LocalInferenceProvider};
use goose_local_inference::model::{ModelSettings, SamplingConfig, ToolCallingMode};

const MODEL_ID: &str = "lfm3-1.7b-q4-k-m";
const CONTEXT: usize = 8192;
use crate::{SigAgentConfig, SigAgentError, SigAgentProvider};
use async_trait::async_trait;
use goose_provider_types::{
    base::{MessageStream, Provider},
    conversation::{message::Message, token_usage::Usage},
    errors::ProviderError,
    model::ModelConfig,
};
use rmcp::model::Tool;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex,
};
use std::time::Duration;
use tokio::sync::{Mutex as AsyncMutex, OwnedMutexGuard};
use tokio_util::sync::CancellationToken;

#[derive(Clone, Debug, uniffi::Record)]
pub struct SigLocalModelStatus {
    pub model_id: String,
    pub engine: String,
    pub backend: String,
    pub gpu_required: bool,
    pub warmup_input_tokens: u64,
    pub warmup_output_tokens: u64,
}

#[derive(uniffi::Object)]
pub struct SigLocalModelEngine {
    state: Arc<State>,
}

struct State {
    model_id: String,
    path: String,
    gate: Arc<AsyncMutex<()>>,
    provider: Mutex<Option<(Arc<LocalInferenceProvider>, SigLocalModelStatus)>>,
    closed: AtomicBool,
    ready: AtomicBool,
    cancel: CancellationToken,
}

fn error() -> SigAgentError {
    SigAgentError::Generic {
        details: "The local model could not start on Metal. Free memory and try again.".into(),
    }
}

fn probe_requested() -> bool {
    #[cfg(any(test, feature = "ios-local-tool-probe"))]
    { std::env::var("SIG_DEMO_GDK_LOCAL_PROBE").as_deref() == Ok(MODEL_ID) }
    #[cfg(not(any(test, feature = "ios-local-tool-probe")))]
    { false }
}

fn local_settings(_: &str) -> anyhow::Result<Option<ModelSettings>> {
    Ok(Some(ModelSettings {
        context_size: Some(CONTEXT as u32),
        max_output_tokens: Some(512),
        n_gpu_layers: Some(u32::MAX),
        n_batch: Some(128),
        flash_attention: Some(true),
        enable_thinking: false,
        tool_calling: ToolCallingMode::ForceNative,
        repeat_penalty: 1.1,
        sampling: SamplingConfig::Temperature {
            temperature: 0.1, top_k: 50, top_p: 0.9, min_p: 0.0, seed: Some(42),
        },
        ..ModelSettings::default()
    }))
}

#[uniffi::export]
impl SigLocalModelEngine {
    #[uniffi::constructor]
    pub fn new(model_id: String, model_path: String) -> Result<Arc<Self>, SigAgentError> {
        if model_id != MODEL_ID
            || !std::path::Path::new(&model_path).is_absolute()
            || model_path.len() > 4096
            || model_path.chars().any(char::is_control)
        {
            return Err(error());
        }
        Ok(Arc::new(Self {
            state: Arc::new(State {
                model_id,
                path: model_path,
                gate: Arc::new(AsyncMutex::new(())),
                provider: Mutex::new(None),
                closed: AtomicBool::new(false),
                ready: AtomicBool::new(false),
                cancel: CancellationToken::new(),
            }),
        }))
    }

    pub async fn load(&self) -> Result<SigLocalModelStatus, SigAgentError> {
        let state = self.state.clone();
        crate::native_runtime()?
            .spawn(async move { state.load().await })
            .await
            .map_err(|_| error())?
    }

    pub fn cancel(&self) {
        self.state.closed.store(true, Ordering::Release);
        self.state.ready.store(false, Ordering::Release);
        self.state.cancel.cancel();
    }

    pub async fn stop(&self) {
        self.cancel();
        let state = self.state.clone();
        if let Ok(runtime) = crate::native_runtime() {
            let _ = runtime
                .spawn(async move {
                    let _guard = state.gate.lock().await;
                    let entry = state.provider.lock().unwrap().take();
                    if let Some((provider, _)) = entry {
                        provider.wait_for_model_idle(&state.path).await;
                        let _ = evict_model(&state.path).await;
                    }
                })
                .await;
        }
    }
}

impl State {
    async fn load(&self) -> Result<SigLocalModelStatus, SigAgentError> {
        let _guard = self.gate.lock().await;
        if self.closed.load(Ordering::Acquire) {
            return Err(error());
        }
        if let Some((_, status)) = self.provider.lock().unwrap().as_ref() {
            return Ok(status.clone());
        }
        config_resolver::set_model_settings_resolver(local_settings);
        let provider = Arc::new(LocalInferenceProvider::from_env().await.map_err(|_| error())?);
        let warmup = async {
            let config = ModelConfig::new(&self.path).with_max_tokens(Some(1));
            let messages = [Message::user().with_text("Reply OK.")];
            let mut stream = provider.stream(&config, "", &messages, &[]).await?;
            let mut tokens = (0, 0);
            while let Some(item) = stream.next().await {
                if let (_, Some(usage)) = item? {
                    tokens = (usage.usage.input_tokens.unwrap_or_default(), usage.usage.output_tokens.unwrap_or_default());
                }
            }
            if tokens.0 <= 0 || tokens.1 <= 0 {
                return Err(ProviderError::ExecutionError("Metal warmup returned no tokens".into()));
            }
            Ok(tokens)
        };
        let result = tokio::select! {
            result = tokio::time::timeout(Duration::from_secs(120), warmup) => result.ok().and_then(|r| r.map_err(|e| {
                if probe_requested() { eprintln!("SIG_LOCAL_GDK_LOAD_ERROR {e}"); }
            }).ok()),
            _ = self.cancel.cancelled() => None,
        };
        let Some((input, output)) = result.filter(|_| !self.closed.load(Ordering::Acquire)) else {
            let _ = evict_model(&self.path).await;
            return Err(error());
        };
        let status = SigLocalModelStatus {
            model_id: self.model_id.clone(),
            engine: "goose-local-inference".into(),
            backend: "metal".into(),
            gpu_required: true,
            warmup_input_tokens: input as u64,
            warmup_output_tokens: output as u64,
        };
        *self.provider.lock().unwrap() = Some((provider, status.clone()));
        self.ready.store(true, Ordering::Release);
        Ok(status)
    }
}

impl SigLocalModelEngine {
    pub(crate) fn acquire(
        &self,
        config: &SigAgentConfig,
    ) -> Result<OwnedMutexGuard<()>, crate::errors::Failure> {
        if probe_requested()
            || config.provider != SigAgentProvider::LocalInference
            || config.model != self.state.model_id
            || config.api_key.is_some()
            || config.base_url.is_some()
            || config.target_node_id.is_some()
            || config.phala_api_key.is_some()
            || self.state.closed.load(Ordering::Acquire)
            || !self.state.ready.load(Ordering::Acquire)
        {
            return Err(crate::errors::Failure::new(
                "local-unavailable",
                "The local model is unavailable. Check Sig agent settings.",
            ));
        }
        self.state.gate.clone().try_lock_owned().map_err(|_| {
            crate::errors::Failure::new(
                "local-busy",
                "The local model is answering another Sig request. Try again shortly.",
            )
        })
    }
    pub(crate) fn provider(
        self: &Arc<Self>,
        progress: tokio::sync::mpsc::UnboundedSender<crate::SigAgentEvent>,
        explicit_reply: bool,
        cancel: CancellationToken,
    ) -> Arc<dyn Provider> {
        Arc::new(LocalProvider {
            engine: self.clone(),
            progress,
            // Each invocation owns a fresh provider, including across its GDK tool turns.
            recovery_available: explicit_reply.then(|| Arc::new(AtomicBool::new(true))),
            cancel,
        })
    }
    pub(crate) async fn cancelled(&self) {
        self.state.cancel.cancelled().await;
    }
    pub(crate) async fn drain(&self) {
        let entry = self.state.provider.lock().unwrap().clone();
        if let Some((provider, _)) = entry {
            provider.wait_for_model_idle(&self.state.path).await;
        }
    }
}

struct LocalProvider {
    engine: Arc<SigLocalModelEngine>,
    progress: tokio::sync::mpsc::UnboundedSender<crate::SigAgentEvent>,
    recovery_available: Option<Arc<AtomicBool>>,
    cancel: CancellationToken,
}
// Only an explicit reply can start with a true permit. The flag is shared
// across all streams in the invocation so later GDK turns cannot grant another retry.
fn take_reply_recovery(permit: Option<&AtomicBool>, committed: bool, finished: bool) -> bool {
    !committed && finished && permit.is_some_and(|p| p.swap(false, Ordering::AcqRel))
}

const RECOVERY_GUIDANCE: &str = "Answer briefly. If the selected text is incomplete, ask for the missing detail. If verifying a public claim requires evidence you do not have, use the available web search. If you cannot verify it, say so.";
const INCONCLUSIVE_REPLY: &str = "I couldn’t verify the selected message reliably. You can ask me to search public sources or share more detail.";

/// Public evidence enters the conversation only through a matching successful GDK web-tool response.
/// Text in the selected message and earlier chat snippets is never evidence of tool execution.
fn has_web_evidence(messages: &[Message]) -> bool {
    let mut requests = std::collections::HashSet::new();
    for block in messages.iter().flat_map(|message| &message.content) {
        if let Some(request) = block.as_tool_request() {
            if request.tool_call.as_ref().is_ok_and(|call| call.name == "brave_web_search") {
                requests.insert(request.id.as_str());
            }
        }
        let Some(response) = block.as_tool_response() else { continue };
        let Ok(result) = &response.tool_result else { continue };
        if !requests.contains(response.id.as_str()) || result.is_error == Some(true) {
            continue;
        }
        if result.structured_content.as_ref()
            .and_then(|body| body.get("sources"))
            .and_then(|sources| sources.as_array())
            .is_some_and(|sources| sources.iter().any(|source| {
                source.get("url").and_then(|url| url.as_str())
                    .and_then(|url| reqwest::Url::parse(url).ok())
                    .is_some_and(|url| matches!(url.scheme(), "https" | "http") && url.has_host())
            }))
        {
            return true;
        }
    }
    false
}

fn inconclusive_reply() -> Message {
    Message::assistant().with_text(INCONCLUSIVE_REPLY)
}

#[async_trait]
impl Provider for LocalProvider {
    fn get_name(&self) -> &str {
        "local"
    }
    async fn stream(
        &self,
        model: &ModelConfig,
        system: &str,
        messages: &[Message],
        tools: &[Tool],
    ) -> Result<MessageStream, ProviderError> {
        let state = &self.engine.state;
        if state.closed.load(Ordering::Acquire) {
            return Err(ProviderError::ExecutionError("Local model stopped".into()));
        }
        let (provider, _) = state.provider.lock().unwrap().clone()
            .ok_or_else(|| ProviderError::ExecutionError("Local model unavailable".into()))?;
        let mut config = model.clone();
        config.model_name.clone_from(&state.path);
        config.context_limit = Some(CONTEXT);
        config.max_tokens = Some(model.max_tokens.unwrap_or(512).clamp(1, 512));
        let messages = provider.with_native_prompt_counter(&state.path, system, tools, |measure| {
            crate::context::fit_local_history(CONTEXT, messages, !tools.is_empty(), measure)
        }).await?;
        let start = std::time::Instant::now();
        let mut stream = provider.stream(&config, system, &messages, tools).await?;
        let progress = self.progress.clone();
        let recovery = self.recovery_available.clone();
        let cancelled = self.cancel.clone();
        let stopped = state.cancel.clone();
        let system = system.to_owned();
        let tools = tools.to_vec();
        Ok(Box::pin(async_stream::try_stream! {
            let mut previous_usage = Usage::default();
            loop {
                let needs_evidence = recovery.as_deref().is_some_and(|permit| !permit.load(Ordering::Acquire))
                    && !has_web_evidence(&messages);
                let mut produced_output = false;
                let mut limit_marker = None;
                let mut usage = None;
                while let Some(item) = tokio::select! {
                    biased;
                    _ = cancelled.cancelled() => Some(Err(ProviderError::ExecutionError("Local inference cancelled".into()))),
                    _ = stopped.cancelled() => Some(Err(ProviderError::ExecutionError("Local model stopped".into()))),
                    item = stream.next() => item,
                } {
                    let (message, item_usage) = item?;
                    if item_usage.is_some() { usage = item_usage; }
                    if let Some(mut message) = message {
                        if message.metadata.output_token_limit_reached && message.content.is_empty() {
                            limit_marker = Some(message);
                            continue;
                        }
                        if needs_evidence && !message.content.is_empty() {
                            // A recovered turn can request a real tool. It can make a
                            // factual claim only after that tool provided actual sources.
                            message.content.retain(|content| content.as_tool_request().is_some());
                            if message.content.is_empty() {
                                if produced_output { continue; }
                                message = inconclusive_reply();
                            }
                        }
                        // A published answer or tool request commits this attempt. Never
                        // replay any part of it, including an already dispatched search.
                        if !message.content.is_empty() {
                            if !produced_output {
                                let _ = progress.send(crate::SigAgentEvent::Timing {
                                    phase: "local-generating".into(), duration_ms: start.elapsed().as_millis() as u64,
                                });
                            }
                            produced_output = true;
                        }
                        yield (Some(message), None);
                    }
                }
                if !take_reply_recovery(recovery.as_deref(), produced_output, usage.is_some()) {
                    if let Some(marker) = limit_marker {
                        yield (Some(marker), None);
                    } else if needs_evidence && !produced_output && usage.is_some() {
                        yield (Some(inconclusive_reply()), None);
                    }
                    if let Some(mut usage) = usage {
                        usage.usage += previous_usage;
                        yield (None, Some(usage));
                    }
                    break;
                }
                // Only a protected, successfully finished attempt with zero semantic
                // output reaches this point. Repeat inference, never a GDK operation.
                previous_usage = usage.expect("completed local generation reported usage").usage;
                if cancelled.is_cancelled() || stopped.is_cancelled() {
                    Err(ProviderError::ExecutionError("Local inference cancelled".into()))?;
                }
                let _ = progress.send(crate::SigAgentEvent::Timing {
                    phase: "local-recovery".into(), duration_ms: start.elapsed().as_millis() as u64,
                });
                let recovery_prompt = format!("{system}\n{RECOVERY_GUIDANCE}");
                let fitted = provider.with_native_prompt_counter(&config.model_name, &recovery_prompt, &tools, |measure| {
                    crate::context::fit_local_history(CONTEXT, &messages, !tools.is_empty(), measure)
                }).await?;
                stream = provider.stream(&config, &recovery_prompt, &fitted, &tools).await?;
            }
        }))

    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn config() -> SigAgentConfig {
        SigAgentConfig {
            provider: SigAgentProvider::LocalInference,
            model: MODEL_ID.into(),
            base_url: None,
            target_node_id: None,
            api_key: None,
            brave_api_key: None,
            phala_api_key: None,
        }
    }
    #[test]
    fn completed_model_text_exposes_only_the_final_channel() {
        use goose_provider_types::thinking::completed_answer_text;
        for (raw, visible) in [
            ("Answer with no markup.", "Answer with no markup."),
            ("<think></think>6 - 1 = 5.</think>**5**", "**5**"),
            ("<think>draft</think>before</THINKING >answer", "answer"),
            ("private</think>more private</think>答え", "答え"),
            ("<think>draft<think>nested</think></think>answer", "answer"),
            ("<think>unfinished", ""),
            ("draft</thi", ""),
            ("answer<thin", "answer"),
            ("prefix<think>hidden</think>suffix", "prefixsuffix"),
            ("2 < 3", "2 < 3"),
        ] {
            assert_eq!(completed_answer_text(raw), visible);
        }
    }

    #[test]
    fn constructor_rejects_unknown_model_and_relative_path() {
        assert!(SigLocalModelEngine::new("unknown".into(), "/public/model.gguf".into()).is_err());
        assert!(SigLocalModelEngine::new(config().model, "relative.gguf".into()).is_err());
    }
    #[test]
    fn unavailable_or_cancelled_engine_cannot_admit_requests() {
        let engine = SigLocalModelEngine::new(config().model, "/public/model.gguf".into()).unwrap();
        assert!(engine.acquire(&config()).is_err());
        engine.state.ready.store(true, Ordering::Release);
        engine.cancel();
        engine.cancel();
        assert!(engine.acquire(&config()).is_err());
    }
    #[test]
    fn admission_is_shared_across_chats_and_rejects_remote_credentials() {
        let engine = SigLocalModelEngine::new(config().model, "/public/model.gguf".into()).unwrap();
        engine.state.ready.store(true, Ordering::Release);
        let lease = engine.acquire(&config()).unwrap();
        assert!(engine.acquire(&config()).is_err());
        drop(lease);
        assert!(engine.acquire(&config()).is_ok());
        let mut foreign = config();
        foreign.api_key = Some("public-fixture".into());
        assert!(engine.acquire(&foreign).is_err());
    }
}

#[cfg(test)]
mod recovery_tests {
    use super::take_reply_recovery;
    use std::sync::atomic::AtomicBool;

    #[test]
    fn two_protected_empty_attempts_end_after_one_recovery() {
        let permit = AtomicBool::new(true);
        assert!(take_reply_recovery(Some(&permit), false, true));
        assert!(!take_reply_recovery(Some(&permit), false, true));
    }

    #[test]
    fn committed_answer_or_tool_and_unfinished_stream_are_not_replayed() {
        let permit = AtomicBool::new(true);
        assert!(!take_reply_recovery(Some(&permit), true, true));
        assert!(!take_reply_recovery(Some(&permit), false, false));
        assert!(take_reply_recovery(Some(&permit), false, true));
        assert!(!take_reply_recovery(None, false, true));
    }

    #[test]
    fn requires_correlated_successful_public_sources_before_publishing_recovered_claims() {
        use super::{has_web_evidence, Message};
        use rmcp::model::{CallToolRequestParams, CallToolResult};
        use serde_json::json;
        let call = |name: &'static str| {
            Message::assistant().with_tool_request("call-7", Ok(CallToolRequestParams::new(name)))
        };
        let response = |id: &'static str, body, error| {
            let mut result = CallToolResult::structured(body);
            result.is_error = Some(error);
            Message::user().with_tool_response(id, Ok(result))
        };
        let sources = json!({"sources":[{"title":"Hours","url":"https://example.org/hours","text":"Saturday"}]});
        let brave = call("brave_web_search");
        let ok = response("call-7", sources.clone(), false);
        assert!(has_web_evidence(&[brave.clone(), ok.clone()]));
        assert!(!has_web_evidence(&[Message::user().with_text(sources.to_string())]));
        assert!(!has_web_evidence(&[call("read_chat_history"), ok.clone()]));
        assert!(!has_web_evidence(&[ok.clone(), brave.clone()]));
        assert!(!has_web_evidence(&[brave.clone(), response("other", sources.clone(), false)]));
        assert!(!has_web_evidence(&[brave.clone(), response("call-7", sources, true)]));
        assert!(!has_web_evidence(&[brave.clone(), response("call-7", json!({"sources":[]}), false)]));
        assert!(!has_web_evidence(&[brave, response("call-7", json!({"sources":[{"url":"invalid"}]}), false)]));
    }
}
