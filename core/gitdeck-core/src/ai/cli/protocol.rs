//! GitDeck 驱动的行分隔 JSON 协议：CLI 充当模型后端，工具由 GitDeck 执行。
//!
//! 子进程的标准输入每行一个请求，标准输出每行一个事件，直到 `stop`：
//!
//! ```json
//! {"type":"request","system":"...","messages":[{"role":"user","content":"..."}],"tools":[...],"write_permission":false}
//! {"type":"text","text":"..."}
//! {"type":"tool_call","id":"1","name":"read_file","input":{"path":"src/main.rs"}}
//! {"type":"stop","reason":"tool_use","usage":{"input_tokens":0,"output_tokens":0}}
//! ```
//!
//! 后续轮次通过 `role: "tool"` 回传工具结果。启动时设置环境变量
//! `GITDECK_REVIEW_PROTOCOL=1`。

use std::io::{BufRead, BufReader, Write};
use std::path::Path;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};

use serde_json::{Value, json};

use super::super::AiTask;
use super::super::provider::{Conversation, ToolOutput, ToolSpec, Turn};
use super::super::provider::{StopReason, ToolCall, Usage};
use crate::error::{CoreError, Result};
use crate::repo::Repository;

pub fn conversation(
    executable: &str,
    system: String,
    tools: Vec<ToolSpec>,
    repo: &Repository,
    task: &AiTask,
) -> Result<Box<dyn Conversation>> {
    let _ = task;
    Ok(Box::new(ProtocolConversation::spawn(
        executable, system, tools, &repo.root,
    )?))
}

struct ProtocolConversation {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
    system: String,
    tools: Vec<ToolSpec>,
    messages: Vec<Value>,
    write_permission: bool,
}

impl ProtocolConversation {
    fn spawn(executable: &str, system: String, tools: Vec<ToolSpec>, cwd: &Path) -> Result<Self> {
        let write_permission = tools.iter().any(|t| t.name == "write_file");
        let mut child = Command::new(executable)
            .current_dir(cwd)
            .env("GITDECK_REVIEW_PROTOCOL", "1")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| CoreError::AiCliFailed {
                message: format!("failed to start {executable}: {e}"),
            })?;
        let stdin = child.stdin.take().ok_or_else(|| CoreError::AiCliFailed {
            message: "CLI stdin is not available".into(),
        })?;
        let stdout = child.stdout.take().ok_or_else(|| CoreError::AiCliFailed {
            message: "CLI stdout is not available".into(),
        })?;
        Ok(Self {
            child,
            stdin,
            stdout: BufReader::new(stdout),
            system,
            tools,
            messages: Vec::new(),
            write_permission,
        })
    }
}

impl Conversation for ProtocolConversation {
    fn push_user_text(&mut self, text: &str) {
        self.messages
            .push(json!({ "role": "user", "content": text }));
    }

    fn push_tool_results(&mut self, results: Vec<ToolOutput>, note: Option<&str>) {
        for result in results {
            self.messages.push(json!({
                "role": "tool",
                "id": result.id,
                "content": result.content,
                "is_error": result.is_error,
            }));
        }
        if let Some(note) = note.filter(|n| !n.is_empty()) {
            self.messages
                .push(json!({ "role": "user", "content": note }));
        }
    }

    fn send(&mut self, task: &AiTask, on_text: &mut dyn FnMut(&str)) -> Result<Turn> {
        task.check()?;
        if let Some(status) = self.child.try_wait().ok().flatten() {
            return Err(CoreError::AiCliFailed {
                message: format!("CLI exited early with {status}"),
            });
        }
        let tools: Vec<Value> = self
            .tools
            .iter()
            .map(|t| {
                json!({
                    "name": t.name,
                    "description": t.description,
                    "schema": t.schema,
                })
            })
            .collect();
        let request = json!({
            "type": "request",
            "system": self.system,
            "messages": self.messages,
            "tools": tools,
            "write_permission": self.write_permission,
        });
        writeln!(self.stdin, "{request}").map_err(|e| CoreError::AiCliFailed {
            message: format!("failed to write to CLI: {e}"),
        })?;
        self.stdin.flush().map_err(|e| CoreError::AiCliFailed {
            message: format!("failed to flush CLI stdin: {e}"),
        })?;

        let mut text = String::new();
        let mut tool_calls = Vec::new();
        let mut usage = Usage::default();
        #[allow(unused_assignments)]
        let mut stop = StopReason::EndTurn;

        loop {
            task.check()?;
            let line = read_line_interruptible(&mut self.stdout, task)?;
            if line.trim().is_empty() {
                continue;
            }
            let event: Value =
                serde_json::from_str(&line).map_err(|e| CoreError::AiInvalidResponse {
                    detail: format!(
                        "CLI event: {e}: {}",
                        line.chars().take(200).collect::<String>()
                    ),
                })?;
            match event["type"].as_str().unwrap_or_default() {
                "text" => {
                    let chunk = event["text"].as_str().unwrap_or_default();
                    if !chunk.is_empty() {
                        text.push_str(chunk);
                        on_text(chunk);
                    }
                }
                "tool_call" => {
                    let id = event["id"].as_str().unwrap_or("tool").to_owned();
                    let name = event["name"].as_str().unwrap_or_default().to_owned();
                    let input = match event.get("input") {
                        Some(Value::Object(_)) => Ok(event["input"].clone()),
                        Some(Value::String(raw)) => super::super::provider::parse_tool_input(raw),
                        _ => Err("missing input".into()),
                    };
                    tool_calls.push(ToolCall { id, name, input });
                }
                "stop" => {
                    usage.input_tokens = event["usage"]["input_tokens"].as_u64().unwrap_or(0);
                    usage.output_tokens = event["usage"]["output_tokens"].as_u64().unwrap_or(0);
                    stop = match event["reason"].as_str().unwrap_or("end_turn") {
                        "tool_use" | "tool_calls" => StopReason::ToolUse,
                        "max_tokens" => StopReason::MaxTokens,
                        "refusal" => {
                            StopReason::Refusal(event["category"].as_str().map(ToOwned::to_owned))
                        }
                        "end_turn" | "stop" | "" => StopReason::EndTurn,
                        other => StopReason::Other(other.to_owned()),
                    };
                    break;
                }
                "error" => {
                    return Err(CoreError::AiCliFailed {
                        message: event["message"]
                            .as_str()
                            .unwrap_or("CLI reported an error")
                            .to_owned(),
                    });
                }
                _ => {}
            }
        }

        if !tool_calls.is_empty() && matches!(stop, StopReason::EndTurn) {
            stop = StopReason::ToolUse;
        }
        // 把模型本轮输出记入历史，便于下一轮完整回传。
        if !text.is_empty() || !tool_calls.is_empty() {
            let mut rec = json!({ "role": "assistant", "content": text });
            if !tool_calls.is_empty() {
                rec["tool_calls"] = tool_calls
                    .iter()
                    .map(|c| {
                        json!({
                            "id": c.id,
                            "name": c.name,
                            "input": c.input.as_ref().ok().cloned().unwrap_or(Value::Null),
                        })
                    })
                    .collect();
            }
            self.messages.push(rec);
        }
        Ok(Turn {
            text,
            tool_calls,
            stop,
            usage,
        })
    }
}

impl Drop for ProtocolConversation {
    fn drop(&mut self) {
        super::kill_child(&mut self.child);
    }
}

/// 带取消检查的按行读取（短超时轮询）。
fn read_line_interruptible(reader: &mut BufReader<ChildStdout>, task: &AiTask) -> Result<String> {
    let mut buf = String::new();
    // 同步阻塞读取：协议 CLI 应立即响应；取消时由 Drop 杀死进程，使 read 返回。
    match reader.read_line(&mut buf) {
        Ok(0) => {
            task.check()?;
            Err(CoreError::AiCliFailed {
                message: "CLI closed stdout before sending stop".into(),
            })
        }
        Ok(_) => Ok(buf),
        Err(e) => {
            if task.is_cancelled() {
                Err(CoreError::AiCancelled)
            } else {
                Err(CoreError::AiCliFailed {
                    message: format!("failed to read CLI output: {e}"),
                })
            }
        }
    }
}
