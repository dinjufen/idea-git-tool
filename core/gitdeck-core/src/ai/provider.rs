//! 两种协议的对话适配：Anthropic Messages API 与 OpenAI 兼容的 Chat Completions。
//!
//! 历史消息按各协议的原生 JSON 保存并且只追加不修改：Claude 的 thinking 块必须原样回传，
//! 且要求它之前的内容（system、tools、更早的消息）保持逐字节一致。

use std::collections::BTreeMap;
use std::io::BufRead;

use serde_json::{Value, json};

use super::http::{self, io_error};
use super::sse::SseReader;
use super::{AiProviderConfig, AiProviderKind, AiTask};
use crate::error::{CoreError, Result};

/// 提供给模型的工具定义。
pub(crate) struct ToolSpec {
    pub name: &'static str,
    pub description: &'static str,
    pub schema: Value,
}

#[derive(Debug, Clone)]
pub(crate) struct ToolCall {
    pub id: String,
    pub name: String,
    /// 解析后的参数；不是合法 JSON 对象时为 `Err(原始文本)`。
    pub input: std::result::Result<Value, String>,
}

pub(crate) struct ToolOutput {
    pub id: String,
    pub content: String,
    pub is_error: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum StopReason {
    EndTurn,
    ToolUse,
    MaxTokens,
    Refusal(Option<String>),
    Other(String),
}

#[derive(Debug, Clone, Copy, Default)]
pub(crate) struct Usage {
    /// 含缓存读写的全部输入 token。
    pub input_tokens: u64,
    pub output_tokens: u64,
}

pub(crate) struct Turn {
    pub text: String,
    pub tool_calls: Vec<ToolCall>,
    pub stop: StopReason,
    pub usage: Usage,
}

pub(crate) trait Conversation: Send {
    fn push_user_text(&mut self, text: &str);
    /// 回传工具结果；`note` 非空时作为同一条用户消息中的附加文本（例如提醒尽快提交结果）。
    fn push_tool_results(&mut self, results: Vec<ToolOutput>, note: Option<&str>);
    /// 发送当前历史并把模型回复追加到历史中；`on_text` 接收流式输出的正文片段。
    fn send(&mut self, task: &AiTask, on_text: &mut dyn FnMut(&str)) -> Result<Turn>;
}

pub(crate) fn conversation(
    config: &AiProviderConfig,
    api_key: &str,
    system: String,
    tools: Vec<ToolSpec>,
) -> Box<dyn Conversation> {
    match config.kind {
        AiProviderKind::Anthropic => Box::new(Anthropic {
            config: config.clone(),
            api_key: api_key.to_owned(),
            system,
            tools,
            messages: Vec::new(),
        }),
        AiProviderKind::OpenAiCompatible => Box::new(OpenAi {
            config: config.clone(),
            api_key: api_key.to_owned(),
            system,
            tools,
            messages: Vec::new(),
            next_call_id: 0,
        }),
    }
}

fn endpoint(base_url: &str, path: &str) -> String {
    let base = base_url.trim().trim_end_matches('/');
    match path.strip_prefix("/v1") {
        Some(rest) if base.ends_with("/v1") => format!("{base}{rest}"),
        _ => format!("{base}{path}"),
    }
}

fn host_is(base_url: &str, host: &str) -> bool {
    let rest = base_url.trim().strip_prefix("https://").unwrap_or_default();
    let authority = rest.split('/').next().unwrap_or_default();
    authority.eq_ignore_ascii_case(host)
}

fn parse_data(data: &str) -> Result<Value> {
    serde_json::from_str(data).map_err(|e| CoreError::AiInvalidResponse {
        detail: format!("{e}: {}", data.chars().take(200).collect::<String>()),
    })
}

fn parse_tool_input(raw: &str) -> std::result::Result<Value, String> {
    let text = if raw.trim().is_empty() { "{}" } else { raw };
    match serde_json::from_str::<Value>(text) {
        Ok(v @ Value::Object(_)) => Ok(v),
        _ => Err(raw.to_owned()),
    }
}

// MARK: - Anthropic

struct Anthropic {
    config: AiProviderConfig,
    api_key: String,
    system: String,
    tools: Vec<ToolSpec>,
    messages: Vec<Value>,
}

impl Anthropic {
    /// 直连官方 API 时才启用服务端回退与工具参数流式输出，代理或网关可能不认识这些字段。
    fn official(&self) -> bool {
        host_is(&self.config.base_url, "api.anthropic.com")
    }

    fn request_body(&self) -> Value {
        let official = self.official();
        let mut body = json!({
            "model": self.config.model,
            "max_tokens": self.config.max_tokens,
            "stream": true,
            "system": [{
                "type": "text",
                "text": self.system,
                "cache_control": { "type": "ephemeral" },
            }],
            "messages": self.messages,
            "thinking": { "type": "adaptive" },
        });
        if let Some(effort) = self.config.effort.as_deref().filter(|e| !e.is_empty()) {
            body["output_config"] = json!({ "effort": effort });
        }
        if !self.tools.is_empty() {
            body["tools"] = self
                .tools
                .iter()
                .map(|t| {
                    let mut tool = json!({
                        "name": t.name,
                        "description": t.description,
                        "input_schema": t.schema,
                    });
                    if official {
                        tool["eager_input_streaming"] = json!(true);
                    }
                    tool
                })
                .collect();
        }
        if official {
            // 自动缓存不断增长的对话尾部；system 上的显式断点保证静态前缀命中。
            body["cache_control"] = json!({ "type": "ephemeral" });
            // 安全分类器拒绝时由服务端改用推荐的回退模型重试。
            body["fallbacks"] = json!("default");
        }
        body
    }

    fn headers(&self) -> Vec<(&'static str, String)> {
        let mut headers = vec![
            ("x-api-key", self.api_key.clone()),
            ("anthropic-version", "2023-06-01".to_owned()),
        ];
        if self.official() {
            headers.push((
                "anthropic-beta",
                "server-side-fallback-2026-07-01".to_owned(),
            ));
        }
        headers
    }
}

impl Conversation for Anthropic {
    fn push_user_text(&mut self, text: &str) {
        self.messages.push(json!({
            "role": "user",
            "content": [{ "type": "text", "text": text }],
        }));
    }

    fn push_tool_results(&mut self, results: Vec<ToolOutput>, note: Option<&str>) {
        let mut content: Vec<Value> = results
            .into_iter()
            .map(|r| {
                json!({
                    "type": "tool_result",
                    "tool_use_id": r.id,
                    "content": r.content,
                    "is_error": r.is_error,
                })
            })
            .collect();
        if let Some(note) = note {
            content.push(json!({ "type": "text", "text": note }));
        }
        self.messages
            .push(json!({ "role": "user", "content": content }));
    }

    fn send(&mut self, task: &AiTask, on_text: &mut dyn FnMut(&str)) -> Result<Turn> {
        let url = endpoint(&self.config.base_url, "/v1/messages");
        let reader = http::post(&url, &self.headers(), &self.request_body(), task)?;
        let (content, stop, usage) = read_anthropic_stream(reader, task, on_text)?;

        // 发生过回退时，最后一个 fallback 块之前的 thinking / tool_use 等内部块不回传，也不执行。
        let boundary = content
            .iter()
            .rposition(|b| b["type"] == "fallback")
            .unwrap_or(0);
        let content: Vec<Value> = content
            .into_iter()
            .enumerate()
            .filter(|(i, b)| *i >= boundary || b["type"] == "text")
            .map(|(_, b)| b)
            .collect();

        let mut text = String::new();
        let mut tool_calls = Vec::new();
        let mut history = Vec::with_capacity(content.len());
        for mut block in content {
            match block["type"].as_str() {
                Some("text") => text.push_str(block["text"].as_str().unwrap_or_default()),
                Some("tool_use") => {
                    let raw = block
                        .as_object_mut()
                        .and_then(|o| o.remove("partial_json"))
                        .and_then(|v| v.as_str().map(str::to_owned))
                        .unwrap_or_default();
                    let input = parse_tool_input(&raw);
                    block["input"] = input.clone().unwrap_or_else(|_| json!({}));
                    tool_calls.push(ToolCall {
                        id: block["id"].as_str().unwrap_or_default().to_owned(),
                        name: block["name"].as_str().unwrap_or_default().to_owned(),
                        input,
                    });
                }
                _ => {}
            }
            history.push(block);
        }
        if !history.is_empty() {
            self.messages
                .push(json!({ "role": "assistant", "content": history }));
        }
        Ok(Turn {
            text,
            tool_calls,
            stop,
            usage,
        })
    }
}

type AnthropicStream = (Vec<Value>, StopReason, Usage);

fn read_anthropic_stream(
    reader: impl BufRead,
    task: &AiTask,
    on_text: &mut dyn FnMut(&str),
) -> Result<AnthropicStream> {
    let mut sse = SseReader::new(reader);
    let mut blocks: BTreeMap<u64, Value> = BTreeMap::new();
    let mut stop = None;
    let mut usage = Usage::default();
    while let Some(event) = sse.next_event().map_err(io_error)? {
        task.check()?;
        if event.data.is_empty() {
            continue;
        }
        let data = parse_data(&event.data)?;
        let index = data["index"].as_u64().unwrap_or(0);
        match data["type"].as_str().unwrap_or(event.event.as_str()) {
            "message_start" => {
                let u = &data["message"]["usage"];
                usage.input_tokens = [
                    "input_tokens",
                    "cache_read_input_tokens",
                    "cache_creation_input_tokens",
                ]
                .iter()
                .filter_map(|k| u[*k].as_u64())
                .sum();
                usage.output_tokens = u["output_tokens"].as_u64().unwrap_or(0);
            }
            "content_block_start" => {
                let mut block = data["content_block"].clone();
                if block["type"] == "tool_use" {
                    block["partial_json"] = json!("");
                }
                blocks.insert(index, block);
            }
            "content_block_delta" => {
                let Some(block) = blocks.get_mut(&index) else {
                    continue;
                };
                let delta = &data["delta"];
                let (field, piece) = match delta["type"].as_str() {
                    Some("text_delta") => ("text", &delta["text"]),
                    Some("thinking_delta") => ("thinking", &delta["thinking"]),
                    Some("signature_delta") => ("signature", &delta["signature"]),
                    Some("input_json_delta") => ("partial_json", &delta["partial_json"]),
                    _ => continue,
                };
                let piece = piece.as_str().unwrap_or_default();
                if field == "text" {
                    on_text(piece);
                }
                let current = block[field].as_str().unwrap_or_default().to_owned();
                block[field] = json!(current + piece);
            }
            "message_delta" => {
                if let Some(reason) = data["delta"]["stop_reason"].as_str() {
                    stop = Some(match reason {
                        "end_turn" | "stop_sequence" => StopReason::EndTurn,
                        "tool_use" => StopReason::ToolUse,
                        "max_tokens" => StopReason::MaxTokens,
                        "refusal" => StopReason::Refusal(
                            data["delta"]["stop_details"]["category"]
                                .as_str()
                                .map(str::to_owned),
                        ),
                        other => StopReason::Other(other.to_owned()),
                    });
                }
                if let Some(output) = data["usage"]["output_tokens"].as_u64() {
                    usage.output_tokens = output;
                }
            }
            "message_stop" => break,
            "error" => return Err(http::stream_error(&data)),
            _ => {}
        }
    }
    let stop = stop.ok_or_else(|| CoreError::AiNetwork {
        detail: "stream ended before the response was complete".into(),
    })?;
    Ok((blocks.into_values().collect(), stop, usage))
}

// MARK: - OpenAI 兼容

struct OpenAi {
    config: AiProviderConfig,
    api_key: String,
    system: String,
    tools: Vec<ToolSpec>,
    messages: Vec<Value>,
    next_call_id: u32,
}

impl OpenAi {
    fn request_body(&self) -> Value {
        let mut messages = vec![json!({ "role": "system", "content": self.system })];
        messages.extend(self.messages.iter().cloned());
        let mut body = json!({
            "model": self.config.model,
            "messages": messages,
            "stream": true,
            "stream_options": { "include_usage": true },
        });
        // OpenAI 官方的新模型只接受 max_completion_tokens，其他兼容服务普遍只认 max_tokens。
        let limit_key = if host_is(&self.config.base_url, "api.openai.com") {
            "max_completion_tokens"
        } else {
            "max_tokens"
        };
        body[limit_key] = json!(self.config.max_tokens);
        if !self.tools.is_empty() {
            body["tools"] = self
                .tools
                .iter()
                .map(|t| {
                    json!({
                        "type": "function",
                        "function": {
                            "name": t.name,
                            "description": t.description,
                            "parameters": t.schema,
                        },
                    })
                })
                .collect();
        }
        body
    }
}

impl Conversation for OpenAi {
    fn push_user_text(&mut self, text: &str) {
        self.messages
            .push(json!({ "role": "user", "content": text }));
    }

    fn push_tool_results(&mut self, results: Vec<ToolOutput>, note: Option<&str>) {
        for r in results {
            let content = if r.is_error {
                format!("Error: {}", r.content)
            } else {
                r.content
            };
            self.messages.push(json!({
                "role": "tool",
                "tool_call_id": r.id,
                "content": content,
            }));
        }
        if let Some(note) = note {
            self.push_user_text(note);
        }
    }

    fn send(&mut self, task: &AiTask, on_text: &mut dyn FnMut(&str)) -> Result<Turn> {
        let url = endpoint(&self.config.base_url, "/chat/completions");
        let mut headers = Vec::new();
        if !self.api_key.is_empty() {
            headers.push(("authorization", format!("Bearer {}", self.api_key)));
        }
        let reader = http::post(&url, &headers, &self.request_body(), task)?;
        let mut sse = SseReader::new(reader);

        let mut text = String::new();
        let mut reasoning = String::new();
        // index → (id, name, arguments)
        let mut calls: BTreeMap<u64, (String, String, String)> = BTreeMap::new();
        let mut finish: Option<String> = None;
        let mut usage = Usage::default();
        let mut done = false;
        while let Some(event) = sse.next_event().map_err(io_error)? {
            task.check()?;
            let data = event.data.trim();
            if data == "[DONE]" {
                done = true;
                break;
            }
            if data.is_empty() {
                continue;
            }
            let chunk = parse_data(data)?;
            if chunk.get("error").is_some() {
                return Err(http::stream_error(&chunk));
            }
            if let Some(u) = chunk.get("usage").filter(|u| u.is_object()) {
                usage.input_tokens = u["prompt_tokens"].as_u64().unwrap_or(0);
                usage.output_tokens = u["completion_tokens"].as_u64().unwrap_or(0);
            }
            let Some(choice) = chunk["choices"].get(0) else {
                continue;
            };
            let delta = &choice["delta"];
            if let Some(piece) = delta["content"].as_str() {
                text.push_str(piece);
                on_text(piece);
            }
            if let Some(piece) = delta["reasoning_content"].as_str() {
                reasoning.push_str(piece);
            }
            for call in delta["tool_calls"].as_array().into_iter().flatten() {
                let index = call["index"].as_u64().unwrap_or(calls.len() as u64);
                let entry = calls.entry(index).or_default();
                if let Some(id) = call["id"].as_str() {
                    entry.0 = id.to_owned();
                }
                if let Some(name) = call["function"]["name"].as_str() {
                    entry.1.push_str(name);
                }
                if let Some(args) = call["function"]["arguments"].as_str() {
                    entry.2.push_str(args);
                }
            }
            if let Some(reason) = choice["finish_reason"].as_str() {
                finish = Some(reason.to_owned());
            }
        }
        if !done && finish.is_none() {
            return Err(CoreError::AiNetwork {
                detail: "stream ended before the response was complete".into(),
            });
        }

        let mut tool_calls = Vec::new();
        let mut history_calls = Vec::new();
        for (_, (id, name, arguments)) in calls {
            let id = if id.is_empty() {
                self.next_call_id += 1;
                format!("call_{}", self.next_call_id)
            } else {
                id
            };
            history_calls.push(json!({
                "id": id,
                "type": "function",
                "function": { "name": name, "arguments": arguments },
            }));
            tool_calls.push(ToolCall {
                id,
                name,
                input: parse_tool_input(&arguments),
            });
        }
        let mut message = json!({
            "role": "assistant",
            "content": if text.is_empty() { Value::Null } else { json!(text) },
        });
        if !history_calls.is_empty() {
            message["tool_calls"] = json!(history_calls);
        }
        if !reasoning.is_empty() {
            // 部分推理模型（如 DeepSeek）要求在工具调用的后续轮次中回传推理内容。
            message["reasoning_content"] = json!(reasoning);
        }
        self.messages.push(message);

        let stop = match finish.as_deref() {
            Some("length") => StopReason::MaxTokens,
            Some("content_filter") => StopReason::Refusal(Some("content_filter".into())),
            _ if !tool_calls.is_empty() => StopReason::ToolUse,
            Some("stop") | None => StopReason::EndTurn,
            Some(other) => StopReason::Other(other.to_owned()),
        };
        Ok(Turn {
            text,
            tool_calls,
            stop,
            usage,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn joins_endpoints() {
        assert_eq!(
            endpoint("https://api.anthropic.com/", "/v1/messages"),
            "https://api.anthropic.com/v1/messages"
        );
        assert_eq!(
            endpoint("https://proxy.example.com/v1", "/v1/messages"),
            "https://proxy.example.com/v1/messages"
        );
        assert_eq!(
            endpoint("http://localhost:11434/v1", "/chat/completions"),
            "http://localhost:11434/v1/chat/completions"
        );
        assert!(host_is("https://api.anthropic.com", "api.anthropic.com"));
        assert!(!host_is("http://api.anthropic.com", "api.anthropic.com"));
        assert!(!host_is(
            "https://api.anthropic.com.evil.test",
            "api.anthropic.com"
        ));
    }

    #[test]
    fn parses_anthropic_stream_with_tool_use() {
        let stream = concat!(
            "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":10,\"cache_read_input_tokens\":90,\"output_tokens\":1}}}\n\n",
            "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}\n\n",
            "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"sig\"}}\n\n",
            "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n",
            "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n",
            "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hi\"}}\n\n",
            "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":2,\"content_block\":{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"read_file\",\"input\":{}}}\n\n",
            "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":2,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\":\"}}\n\n",
            "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":2,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\\\"a.rs\\\"}\"}}\n\n",
            "event: ping\ndata: {\"type\":\"ping\"}\n\n",
            "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":42}}\n\n",
            "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
        );
        let task = AiTask::default();
        let mut streamed = String::new();
        let (blocks, stop, usage) =
            read_anthropic_stream(stream.as_bytes(), &task, &mut |t| streamed.push_str(t)).unwrap();
        assert_eq!(stop, StopReason::ToolUse);
        assert_eq!(usage.input_tokens, 100);
        assert_eq!(usage.output_tokens, 42);
        assert_eq!(streamed, "Hi");
        assert_eq!(blocks[0]["signature"], "sig");
        assert_eq!(blocks[2]["partial_json"], "{\"path\":\"a.rs\"}");
    }

    #[test]
    fn rejects_truncated_stream_and_reports_errors() {
        let task = AiTask::default();
        let truncated = "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{}}}\n\n";
        assert!(matches!(
            read_anthropic_stream(truncated.as_bytes(), &task, &mut |_| {}),
            Err(CoreError::AiNetwork { .. })
        ));
        let overloaded = "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}\n\n";
        assert_eq!(
            read_anthropic_stream(overloaded.as_bytes(), &task, &mut |_| {}).err(),
            Some(CoreError::AiRequestFailed {
                status: 529,
                message: "Overloaded".into()
            })
        );
    }
}
