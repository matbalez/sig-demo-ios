// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

//! The native GDK state machine and its deliberately small UniFFI entry point.

mod brave;
mod compat_provider;
mod context;
mod errors;
mod local;
mod runtime;
mod sessions;
mod tool_compat;
pub use local::{SigLocalModelEngine, SigLocalModelStatus};

use std::sync::{Arc, OnceLock};
use tokio::sync::Mutex;
use tokio_util::sync::CancellationToken;

uniffi::setup_scaffolding!("sig_demo_agent");

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum SigAgentProvider {
    MeshLlm,
    Chatgpt,
    Phala,
    LocalInference,
}

#[derive(Clone, uniffi::Record)]
pub struct SigAgentConfig {
    pub provider: SigAgentProvider,
    pub model: String,
    pub base_url: Option<String>,
    pub target_node_id: Option<String>,
    pub api_key: Option<String>,
    pub brave_api_key: Option<String>,
    pub phala_api_key: Option<String>,
}

impl SigAgentProvider {
    fn uses_local_search(self) -> bool {
        matches!(self, Self::MeshLlm | Self::Phala | Self::LocalInference)
    }
}

#[derive(Clone, Copy, Debug, serde::Serialize, uniffi::Enum)]
#[serde(rename_all = "lowercase")]
pub enum SigHistoryRole {
    User,
    Assistant,
    /// Ordinary outgoing message from the account invoking Sig (never inferred from its label).
    #[serde(rename = "user")]
    Requester,
}

#[derive(Clone, Debug, serde::Serialize, uniffi::Record)]
pub struct SigHistoryMessage {
    #[serde(skip_serializing)]
    pub id: String,
    pub role: SigHistoryRole,
    pub author: String,
    pub text: String,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct SigAgentRequest {
    pub mode: SigAgentMode,
    pub query_id: String,
    pub response_id: String,
    pub source_text: String,
    pub prompt: String,
    pub author: Option<String>,
    pub history: Vec<SigHistoryMessage>,
    pub current_date: Option<String>,
    #[uniffi(default = None)]
    pub reply_to: Option<SigHistoryMessage>,
    #[uniffi(default = false)]
    pub reply_target_unavailable: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum SigAgentMode {
    Answer,
    Warmup,
}

#[derive(Clone, Copy, Debug, uniffi::Enum)]
pub enum SigAgentStatus {
    Responding,
    Searching,
}

#[derive(Clone, Debug, uniffi::Enum)]
pub enum SigAgentEvent {
    Text {
        text: String,
    },
    Status {
        status: SigAgentStatus,
    },
    Timing {
        phase: String,
        duration_ms: u64,
    },
    Done,
    Error {
        code: String,
        message: String,
        http_status: Option<u16>,
        reason_code: Option<String>,
    },
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum SigAgentError {
    #[error("{details}")]
    Generic { details: String },
}

impl SigAgentError {
    fn internal() -> Self {
        Self::Generic {
            details: "Sig's native agent could not start.".into(),
        }
    }
}

#[derive(uniffi::Object)]
pub struct SigAgentStream {
    receiver: Mutex<tokio::sync::mpsc::UnboundedReceiver<SigAgentEvent>>,
    cancellation: CancellationToken,
    task: Mutex<Option<tokio::task::JoinHandle<()>>>,
    local_engine: Option<Arc<SigLocalModelEngine>>,
}

#[uniffi::export]
impl SigAgentStream {
    pub async fn next_event(&self) -> Result<Option<SigAgentEvent>, SigAgentError> {
        Ok(self.receiver.lock().await.recv().await)
    }

    pub fn cancel(&self) {
        self.cancellation.cancel();
    }

    pub async fn shutdown(&self) {
        self.cancellation.cancel();
        let mut task = self.task.lock().await;
        if let Some(task) = task.take() {
            if self.local_engine.is_none() {
                task.abort();
            }
            let _ = task.await;
        }
    }
}

impl Drop for SigAgentStream {
    fn drop(&mut self) {
        self.cancellation.cancel();
        if let Some(task) = self.task.get_mut().take() {
            if self.local_engine.is_none() {
                task.abort();
            }
        }
    }
}

fn native_runtime() -> Result<&'static tokio::runtime::Runtime, SigAgentError> {
    static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    if let Some(runtime) = RUNTIME.get() {
        return Ok(runtime);
    }
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .map_err(|_| SigAgentError::internal())?;
    if let Err(unused) = RUNTIME.set(runtime) {
        unused.shutdown_background();
    }
    RUNTIME.get().ok_or_else(SigAgentError::internal)
}

#[uniffi::export]
pub async fn start_sig_agent(
    config: SigAgentConfig,
    request: SigAgentRequest,
) -> Result<Arc<SigAgentStream>, SigAgentError> {
    start_stream(config, request, Arc::new(runtime::Memory::default()), None)
}

#[derive(uniffi::Object)]
pub struct SigAgentSession {
    memory: Arc<runtime::Memory>,
    local_engine: Option<Arc<SigLocalModelEngine>>,
}

#[uniffi::export]
pub fn create_sig_agent_session(
    account_id: String,
    chat_id: String,
) -> Result<Arc<SigAgentSession>, SigAgentError> {
    if [&account_id, &chat_id]
        .iter()
        .any(|id| id.is_empty() || id.len() > 1024 || id.chars().any(char::is_control))
    {
        return Err(SigAgentError::internal());
    }
    // The owned handle is the scope. Scope identifiers never enter a prompt,
    // credential cache, global registry, or provider payload.
    Ok(Arc::new(SigAgentSession {
        memory: Arc::new(runtime::Memory::default()),
        local_engine: None,
    }))
}

#[uniffi::export]
pub fn create_local_sig_agent_session(
    account_id: String,
    chat_id: String,
    engine: Arc<SigLocalModelEngine>,
) -> Result<Arc<SigAgentSession>, SigAgentError> {
    let mut session = create_sig_agent_session(account_id, chat_id)?;
    Arc::get_mut(&mut session)
        .ok_or_else(SigAgentError::internal)?
        .local_engine = Some(engine);
    Ok(session)
}

#[uniffi::export]
impl SigAgentSession {
    pub async fn run(
        &self,
        config: SigAgentConfig,
        request: SigAgentRequest,
    ) -> Result<Arc<SigAgentStream>, SigAgentError> {
        start_stream(
            config,
            request,
            Arc::clone(&self.memory),
            self.local_engine.clone(),
        )
    }
}

fn start_stream(
    config: SigAgentConfig,
    request: SigAgentRequest,
    memory: Arc<runtime::Memory>,
    local_engine: Option<Arc<SigLocalModelEngine>>,
) -> Result<Arc<SigAgentStream>, SigAgentError> {
    let cancellation = CancellationToken::new();
    let (sender, receiver) = tokio::sync::mpsc::unbounded_channel();
    let cancel = cancellation.clone();
    let engine = local_engine.clone();
    let task = native_runtime()?.spawn(async move {
        runtime::run(config, request, sender, cancel, memory, engine).await;
    });
    Ok(Arc::new(SigAgentStream {
        receiver: Mutex::new(receiver),
        cancellation,
        task: Mutex::new(Some(task)),
        local_engine,
    }))
}
