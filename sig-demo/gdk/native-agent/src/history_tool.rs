// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

use super::ToolProvider;
use super::{Emitter, Flow, Session, SigAgentEvent, SigAgentRequest};
use crate::context::{read_chat_history, ChatHistoryScope};
use crate::errors::Failure;
use anyhow::Result;
use async_trait::async_trait;
use rmcp::model::{CallToolRequestParams, CallToolResult, ContentBlock, ErrorData, Tool};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{sync::Arc, time::Instant};

pub(super) const NAME: &str = "read_chat_history";
pub(super) const NO_PRIOR_MESSAGE_NOTE: &str =
    "I couldn’t find a previous message from you in the available chat history. This covers the available messages.\n\n";

pub(super) fn limit() -> Failure {
    Failure::new(
        "local-tool-limit",
        "Sig reached the tool limit for this request. Please try again.",
    )
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Arguments {
    #[serde(default)]
    include_before_my_last_message: bool,
}

impl Arguments {
    fn scope(&self) -> ChatHistoryScope {
        if self.include_before_my_last_message {
            ChatHistoryScope::Recent
        } else {
            ChatHistoryScope::SinceLastMessage
        }
    }
}

pub(super) struct HistoryTools {
    pub(super) request: SigAgentRequest,
    pub(super) flow: Arc<Flow>,
}

#[async_trait]
impl ToolProvider<Session> for HistoryTools {
    async fn tools(&self, _session: &Session) -> Result<Vec<Tool>> {
        Ok(vec![Tool::new(NAME,
            "Read messages posted after the requester last spoke in this private chat. For a catch-up or missed updates, call with empty arguments. This tool can also return earlier history if specifically requested. Always call this tool when asked to summarize a stretch of the conversation, including the whole discussion: the initial snippets cannot establish that coverage. A short follow-up can be answered directly from those snippets. Use returned records to answer the current question. For a requested summary, cover only its scope and identify speakers accurately. If no previous requester message was found, say so when summarizing the available window. An empty update window means no newer messages.",
            Arc::new(serde_json::from_value(json!({
                "type": "object",
                "properties": {"include_before_my_last_message": {
                    "type": "boolean",
                    "default": false,
                    "description": "Leave false for updates and catch-ups. Set true only if the user explicitly wants the whole discussion, or asks for a particular detail from before their own last message."
                }},
                "additionalProperties": false
            })).expect("fixed chat history tool schema")),
        )])
    }

    async fn call(
        &self,
        _session: &Session,
        _request_id: &str,
        call: CallToolRequestParams,
        _emit: &Emitter,
    ) -> Result<CallToolResult, ErrorData> {
        let invalid = || ErrorData::invalid_params("Invalid chat history request", None);
        if self.flow.failure().is_some() {
            return Err(invalid());
        }
        let args: Arguments = serde_json::from_value(Value::Object(
            call.arguments.unwrap_or_default(),
        ))
        .map_err(|_| {
            self.flow.fail(Failure::new(
                "tool-arguments-invalid",
                "Sig requested an invalid chat history scope.",
            ));
            invalid()
        })?;
        let scope = args.scope();
        let phase = match scope {
            ChatHistoryScope::SinceLastMessage => "history-read-since-last-message",
            ChatHistoryScope::Recent => "history-read-recent",
        };
        if !self
            .flow
            .counts
            .lock()
            .unwrap()
            .history_scopes
            .insert(phase)
        {
            self.flow.fail(limit());
            return Err(invalid());
        }
        let started = Instant::now();
        self.flow.emit(SigAgentEvent::Timing {
            phase: "history-started".into(),
            duration_ms: 0,
        });
        let history = read_chat_history(&self.request, scope).map_err(|failure| {
            self.flow.fail(failure);
            invalid()
        })?;
        let result = CallToolResult::success(vec![ContentBlock::text(history.to_string())]);
        {
            let mut counts = self.flow.counts.lock().unwrap();
            counts.completed_history_reads += 1;
            counts.history_has_no_requester_boundary =
                history["coverage"] == "no_prior_requester_message_in_available_window";
        }
        self.flow.timing("history", started);
        self.flow.timing(phase, started);
        Ok(result)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scope_defaults_to_updates_and_only_accepts_known_arguments() {
        let default: Arguments = serde_json::from_value(json!({})).unwrap();
        assert!(matches!(default.scope(), ChatHistoryScope::SinceLastMessage));
        let full: Arguments = serde_json::from_value(json!({"include_before_my_last_message": true})).unwrap();
        assert!(matches!(full.scope(), ChatHistoryScope::Recent));
        assert!(serde_json::from_value::<Arguments>(json!({"include_before_my_last_message":"all_accounts"})).is_err());
        assert!(serde_json::from_value::<Arguments>(json!({"thread_id":"other"})).is_err());
    }
}
