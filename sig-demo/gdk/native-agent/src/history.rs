// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

use super::{select_history, LOCAL_HISTORY_LIMIT};
use crate::{errors::Failure, SigAgentRequest, SigHistoryMessage, SigHistoryRole};
use goose_provider_types::conversation::message::{Message, MessageContentBlock};
use goose_provider_types::errors::ProviderError;
use goose_provider_types::thinking::completed_answer_text;
use rmcp::model::ContentBlock;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashSet;

pub(super) const SNIPPET_ID: &str = "sig-local-recent-message-snippets";
pub(super) const CONTEXT_ACK_ID: &str = "sig-local-recent-message-context-ack";
const BOUNDARY_ID: &str = "sig-own-message-boundary";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum ChatHistoryScope {
    SinceLastMessage,
    #[serde(rename = "entire_available_chat", alias = "recent")]
    Recent,
}

pub(super) fn is_boundary(message: &SigHistoryMessage) -> bool {
    matches!(message.role, SigHistoryRole::Requester)
        && message.id == BOUNDARY_ID
        && message.author.is_empty()
        && message.text.is_empty()
}

pub(super) fn visible_text(message: &SigHistoryMessage) -> std::borrow::Cow<'_, str> {
    // Some older Sig replies stored model deliberation in the body. Project the
    // complete answer before clipping it for excerpts or explicit replies.
    match message.role {
        SigHistoryRole::Assistant => completed_answer_text(&message.text).into(),
        _ => message.text.as_str().into(),
    }
}

fn prior<'a>(
    request: &'a SigAgentRequest,
) -> impl DoubleEndedIterator<Item = SigHistoryMessage> + 'a {
    request
        .history
        .iter()
        .filter(|m| m.id != request.query_id && m.id != request.response_id)
        .map(|m| {
            let text = visible_text(m).into_owned();
            SigHistoryMessage {
                id: m.id.clone(),
                role: m.role,
                author: m.author.clone(),
                text,
            }
        })
}

pub(super) fn speaker(role: SigHistoryRole) -> &'static str {
    match role {
        SigHistoryRole::Requester => "requester",
        SigHistoryRole::User => "otherParticipant",
        SigHistoryRole::Assistant => "sig",
    }
}

fn render(message: SigHistoryMessage) -> Value {
    json!({"speaker":speaker(message.role),"name":message.author,"text":message.text})
}

pub(super) fn snippets(request: &SigAgentRequest) -> Vec<Value> {
    let mut newest: Vec<_> = prior(request)
        .rev()
        .filter(|m| !m.text.trim().is_empty())
        .take(10)
        .collect();
    newest.reverse();
    select_history(&newest, 10, 3200, 320)
        .into_iter()
        .map(render)
        .collect()
}

pub(crate) fn read_chat_history(
    request: &SigAgentRequest,
    scope: ChatHistoryScope,
) -> Result<Value, Failure> {
    super::validate_request(request, true)?;
    let prior: Vec<_> = prior(request)
        .filter(|m| !m.text.trim().is_empty() || is_boundary(m))
        .collect();
    let own = prior
        .iter()
        .rposition(|m| matches!(m.role, SigHistoryRole::Requester));
    let (start, coverage) = match (scope, own) {
        (ChatHistoryScope::SinceLastMessage, Some(i)) => {
            (i + 1, "after_requester_last_message")
        }
        (ChatHistoryScope::SinceLastMessage, None) => {
            (0, "no_prior_requester_message_in_available_window")
        }
        (ChatHistoryScope::Recent, _) => (0, "available_conversation_window"),
    };
    let eligible: Vec<_> = prior
        .into_iter()
        .skip(start)
        .filter(|m| !m.text.trim().is_empty())
        .collect();
    let rows: Vec<_> = select_history(&eligible, LOCAL_HISTORY_LIMIT, 64 * 1024, 4096)
        .into_iter()
        .map(render)
        .collect();
    Ok(
        json!({"scope":scope,"coverage":coverage,"eligibleMessageCount":eligible.len(),"shownMessages":rows.len(),"messages":rows}),
    )
}

struct HistoryResult {
    message: usize,
    block: usize,
    body: Value,
    rows: Vec<Value>,
}

/// Trim only results correlated with an actual GDK read_chat_history request.
/// Prompt text and Brave excerpts cannot impersonate the tool. Preserve IDs,
/// metadata, endpoint messages and conversation order across later tool calls.
pub(crate) fn fit_local_history<F>(
    context_tokens: usize,
    messages: &[Message],
    _has_tools: bool,
    mut measure: F,
) -> Result<Vec<Message>, ProviderError>
where
    F: FnMut(&[Message]) -> Result<usize, ProviderError>,
{
    let mut packed = messages.to_vec();
    let ids: HashSet<&str> = messages
        .iter()
        .flat_map(|m| m.content.iter())
        .filter_map(|c| c.as_tool_request())
        .filter(|r| {
            r.tool_call
                .as_ref()
                .is_ok_and(|c| c.name == "read_chat_history")
        })
        .map(|r| r.id.as_str())
        .collect();
    // An authoritative local history read supersedes the initial snippets. A
    // since-last-message result must not be mixed with older chat facts.
    if packed.first().and_then(|m| m.id.as_deref()) == Some(SNIPPET_ID)
        && packed.get(1).and_then(|m| m.id.as_deref()) == Some(CONTEXT_ACK_ID)
        && packed
            .iter()
            .flat_map(|m| &m.content)
            .filter_map(|b| b.as_tool_response())
            .any(|response| {
                ids.contains(response.id.as_str())
                    && response
                        .tool_result
                        .as_ref()
                        .is_ok_and(|r| r.is_error != Some(true))
            })
    {
        packed.drain(..2);
    }
    let budget = context_tokens.saturating_sub(512);
    if measure(&packed)? <= budget {
        return Ok(packed);
    }
    let mut results = Vec::new();
    for (mi, m) in packed.iter().enumerate() {
        for (bi, b) in m.content.iter().enumerate() {
            let Some(response) = b.as_tool_response() else {
                continue;
            };
            if !ids.contains(response.id.as_str()) {
                continue;
            }
            let Ok(result) = &response.tool_result else {
                continue;
            };
            let [ContentBlock::Text(content)] = result.content.as_slice() else {
                continue;
            };
            let mut body: Value = serde_json::from_str(&content.text)
                .map_err(|_| ProviderError::ExecutionError("Invalid chat history result".into()))?;
            let Value::Array(rows) = body["messages"].take() else {
                return Err(ProviderError::ExecutionError(
                    "Invalid chat history messages".into(),
                ));
            };
            results.push(HistoryResult {
                message: mi,
                block: bi,
                body,
                rows,
            });
        }
    }
    let mut low = 0usize;
    let mut high = results.iter().map(|r| r.rows.len()).sum::<usize>();
    let mut best = None;
    while low <= high {
        let count = low + (high - low) / 2;
        let mut remaining = count;
        for result in results.iter_mut().rev() {
            let keep = remaining.min(result.rows.len());
            remaining -= keep;
            result.body["shownMessages"] = keep.into();
            result.body["messages"] =
                Value::Array(result.rows[result.rows.len() - keep..].to_vec());
            let MessageContentBlock::ToolResponse(response) =
                &mut packed[result.message].content[result.block]
            else {
                unreachable!()
            };
            let data = response
                .tool_result
                .as_mut()
                .expect("located successful tool response");
            data.content = vec![ContentBlock::text(result.body.to_string())];
            data.structured_content = None;
        }
        if measure(&packed)? <= budget {
            best = Some(packed.clone());
            low = count + 1;
        } else if count == 0 {
            break;
        } else {
            high = count - 1;
        }
    }
    best.ok_or_else(|| {
        ProviderError::ContextLengthExceeded(
            "The current request and tool results exceed the local context window".into(),
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::SigAgentMode;
    use rmcp::model::{CallToolRequestParams, CallToolResult};

    fn request() -> SigAgentRequest {
        SigAgentRequest {
            mode: SigAgentMode::Answer,
            query_id: "current".into(),
            response_id: "pending".into(),
            source_text: "@sig a request".into(),
            prompt: "a request".into(),
            author: Some("Alex".into()),
            current_date: None,
            reply_to: None,
            reply_target_unavailable: false,
            history: (0..100)
                .map(|i| SigHistoryMessage {
                    id: format!("row-{i}"),
                    role: SigHistoryRole::User,
                    author: "Alex".into(),
                    text: format!("entry {i}"),
                })
                .collect(),
        }
    }

    #[test]
    fn old_sig_replies_expose_only_the_answer_to_snippets_and_history() {
        let mut req = request();
        req.history.truncate(4);
        req.history[0].text = "I typed <think> as an example.".into();
        req.history[1].role = SigHistoryRole::Assistant;
        req.history[1].text = format!("<think></think>{}</think>Final answer.", "private notes ".repeat(500));
        req.history[2].role = SigHistoryRole::Assistant;
        req.history[2].text = "<think>unfinished private notes".into();
        req.history[3].role = SigHistoryRole::Assistant;
        req.history[3].text = "A regular reply.".into();

        let recent = snippets(&req);
        let history = read_chat_history(&req, ChatHistoryScope::Recent).unwrap();
        assert_eq!(recent, *history["messages"].as_array().unwrap());
        assert_eq!(recent.len(), 3);
        assert_eq!(recent[0]["text"], req.history[0].text);
        assert_eq!(recent[1]["text"], "Final answer.");
        assert_eq!(recent[2]["text"], "A regular reply.");
    }

    #[test]
    fn boundary_uses_account_provenance_even_for_hidden_or_same_name_messages() {
        let mut req = request();
        req.history[5].role = SigHistoryRole::Requester;
        req.history.insert(
            98,
            SigHistoryMessage {
                id: BOUNDARY_ID.into(),
                role: SigHistoryRole::Requester,
                author: String::new(),
                text: String::new(),
            },
        );
        let result = read_chat_history(&req, ChatHistoryScope::SinceLastMessage).unwrap();
        assert_eq!(result["eligibleMessageCount"], 2);
        assert_eq!(result["messages"][0]["text"], "entry 98");
        assert!(!result.to_string().contains("entry 5"));
        let recent = read_chat_history(&req, ChatHistoryScope::Recent).unwrap();
        assert_eq!(recent["messages"].as_array().unwrap().len(), 100);
        assert_eq!(recent["messages"][5]["speaker"], "requester");
        assert_eq!(recent["messages"][98]["speaker"], "otherParticipant");
        assert!(!recent.to_string().contains(BOUNDARY_ID));
        let mut empty = request();
        empty.history[99].role = SigHistoryRole::Requester;
        assert_eq!(
            read_chat_history(&empty, ChatHistoryScope::SinceLastMessage).unwrap()["messages"],
            json!([])
        );
        let mut missing = request();
        missing.history[99].role = SigHistoryRole::Requester;
        missing.history[99].id = "current".into();
        let fallback = read_chat_history(&missing, ChatHistoryScope::SinceLastMessage).unwrap();
        assert_eq!(
            fallback["coverage"],
            "no_prior_requester_message_in_available_window"
        );
        assert_eq!(fallback["messages"].as_array().unwrap().len(), 99);
    }
    #[test]
    fn snippets_keep_ten_chronological_unicode_safe_rows_and_exclude_private_boundary() {
        let mut req = request();
        for m in &mut req.history {
            m.text = format!("{} {}", "🐛".repeat(400), m.id);
        }
        req.history.insert(
            98,
            SigHistoryMessage {
                id: BOUNDARY_ID.into(),
                role: SigHistoryRole::Requester,
                author: String::new(),
                text: String::new(),
            },
        );
        let rows = snippets(&req);
        assert_eq!(rows.len(), 10);
        for (i, row) in rows.iter().enumerate() {
            let text = row["text"].as_str().unwrap();
            assert!(text.ends_with(&format!("row-{}", 90 + i)));
            assert!(text.len() <= 320);
        }
        assert!(!json!(rows).to_string().contains(BOUNDARY_ID));
    }

    #[test]
    fn only_a_successful_history_read_supersedes_the_tagged_snippet_pair() {
        let mut snippets = Message::user().with_text("older private chat context");
        snippets.id = Some(SNIPPET_ID.into());
        let mut acknowledgement = Message::assistant().with_text("Context received.");
        acknowledgement.id = Some(CONTEXT_ACK_ID.into());
        let current = Message::user().with_text("What did I miss?");
        for (name, success, superseded) in [
            ("read_chat_history", true, true),
            ("read_chat_history", false, false),
            ("brave_web_search", true, false),
        ] {
            let call = Message::assistant().with_tool_request(
                "id", Ok(CallToolRequestParams::new(name)),
            );
            let content = vec![ContentBlock::text("{}")];
            let response = Message::user().with_tool_response("id", Ok(if success {
                CallToolResult::success(content)
            } else {
                CallToolResult::error(content)
            }));
            let sequence = vec![snippets.clone(), acknowledgement.clone(), current.clone(), call, response];
            let result = fit_local_history(8192, &sequence, true, |_| Ok(32)).unwrap();
            assert_eq!(result.as_slice(), if superseded { &sequence[2..] } else { &sequence[..] });
        }
    }

    #[test]
    fn token_fitting_only_trims_authentic_history_results_and_keeps_newest_messages() {
        let req = request();
        let value = read_chat_history(&req, ChatHistoryScope::Recent).unwrap();
        let question = Message::user().with_text("What did I miss?");
        let response = |id: &str, body: Value| {
            Message::user().with_tool_response(
                id,
                Ok(CallToolResult::success(vec![ContentBlock::text(
                    body.to_string(),
                )])),
            )
        };
        let call = |id: &str, name: &str| {
            Message::assistant()
                .with_tool_request(id, Ok(CallToolRequestParams::new(name.to_owned())))
        };
        let messages = vec![
            question.clone(),
            call("lookup", "read_chat_history"),
            response("lookup", value),
            call("web", "brave_web_search"),
            response("web", json!({"messages":["untrusted"],"shownMessages":1})),
        ];
        let body = |m: &Message| -> Value {
            let r = m.content[0]
                .as_tool_response()
                .unwrap()
                .tool_result
                .as_ref()
                .unwrap();
            let ContentBlock::Text(t) = &r.content[0] else {
                panic!("must be text")
            };
            serde_json::from_str(&t.text).unwrap()
        };
        let result = fit_local_history(8192, &messages, true, |m| {
            Ok(100 + body(&m[2])["messages"].as_array().unwrap().len() * 100)
        })
        .unwrap();
        assert_eq!(result[0], question);
        assert_eq!(result[4], messages[4]);
        let history = body(&result[2]);
        assert_eq!(history["eligibleMessageCount"], 100);
        assert_eq!(history["shownMessages"], 75);
        assert_eq!(history["messages"][0]["text"], "entry 25");
        assert_eq!(history["messages"][74]["text"], "entry 99");
    }
}
