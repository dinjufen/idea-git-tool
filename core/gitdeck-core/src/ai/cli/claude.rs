//! Claude Code（`claude`）评审后端：禁用其内置文件/命令工具，只允许 GitDeck 的 MCP 工具。

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::Value;

use super::super::AiTask;
use super::super::provider::{ToolSpec, Usage};
use super::super::review::{
    ReviewEvent, ReviewFinding, ReviewListener, ReviewResult, extract_json, parse_submission_input,
};
use super::super::tools::ToolContext;
use super::{DetectedAiCli, mcp};
use crate::error::{CoreError, Result};
use crate::repo::Repository;

/// 构造传给 `claude -p` 的参数（便于单测断言写权限与内置工具被关掉）。
pub fn command_args(
    system_prompt_file: &str,
    mcp_config_file: &str,
    max_turns: u32,
    allowed_tools: &str,
) -> Vec<String> {
    vec![
        "-p".into(),
        "--output-format".into(),
        "stream-json".into(),
        "--verbose".into(),
        "--include-partial-messages".into(),
        "--system-prompt-file".into(),
        system_prompt_file.into(),
        "--mcp-config".into(),
        mcp_config_file.into(),
        "--strict-mcp-config".into(),
        "--tools".into(),
        String::new(), // 禁用所有内置工具（Read / Write / Bash / Edit 等）
        "--allowedTools".into(),
        allowed_tools.into(),
        "--permission-mode".into(),
        "dontAsk".into(),
        "--permission-prompts".into(),
        "none".into(),
        "--max-turns".into(),
        max_turns.to_string(),
        "--no-session-persistence".into(),
        "--disable-slash-commands".into(),
    ]
}

pub fn allowed_tools_value() -> &'static str {
    "mcp__gitdeck__*"
}

#[allow(clippy::too_many_arguments)]
pub fn run(
    resolved: &DetectedAiCli,
    repo: &Repository,
    system: &str,
    prompt: &str,
    context: ToolContext<'_>,
    tools: Vec<ToolSpec>,
    max_turns: u32,
    _budget: u64,
    task: &AiTask,
    listener: &dyn ReviewListener,
    revision: Option<String>,
) -> Result<ReviewResult> {
    let tmp = unique_tempdir()?;
    let system_path = tmp.join("system.txt");
    let mcp_path = tmp.join("mcp.json");
    let prompt_path = tmp.join("prompt.txt");
    fs::write(&system_path, system)?;
    fs::write(&prompt_path, prompt)?;
    let _prompt_path = prompt_path;
    struct Cleanup(std::path::PathBuf);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    let _cleanup = Cleanup(tmp.clone());

    let (tcp, port, token) = mcp::bind()?;
    let mcp_json = mcp::mcp_config(port, &token);
    fs::write(&mcp_path, mcp_json.to_string())?;

    let shutdown = Arc::new(AtomicBool::new(false));
    let submission = Arc::new(Mutex::new(None::<(String, Vec<ReviewFinding>)>));
    let write_permission = context.write_permission;
    let revision_for_mcp = context.revision.clone();

    let args = command_args(
        &system_path.to_string_lossy(),
        &mcp_path.to_string_lossy(),
        max_turns,
        allowed_tools_value(),
    );

    std::thread::scope(|scope| -> Result<ReviewResult> {
        let shutdown_mcp = Arc::clone(&shutdown);
        let submission_mcp = Arc::clone(&submission);
        scope.spawn(|| {
            mcp::spawn(
                &tcp,
                token,
                shutdown_mcp,
                repo,
                context.filter,
                revision_for_mcp,
                write_permission,
                tools,
                listener,
                submission_mcp,
            );
        });

        let mut child = Command::new(&resolved.path)
            .args(&args)
            .current_dir(&repo.root)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .env("CI", "1")
            .spawn()
            .map_err(|e| CoreError::AiCliFailed {
                message: format!("failed to start {}: {e}", resolved.path),
            })?;

        if let Some(mut stdin) = child.stdin.take() {
            let _ = stdin.write_all(prompt.as_bytes());
            let _ = stdin.flush();
            drop(stdin);
        }

        let stdout = child.stdout.take().ok_or_else(|| CoreError::AiCliFailed {
            message: "claude stdout is not available".into(),
        })?;
        let mut reader = BufReader::new(stdout);
        let mut final_text = String::new();
        let mut usage = Usage::default();
        let mut turns = 0u32;
        let mut mcp_errors = Vec::new();
        let mut line = String::new();
        let result = loop {
            if task.is_cancelled() {
                super::kill_child(&mut child);
                shutdown.store(true, Ordering::SeqCst);
                break Err(CoreError::AiCancelled);
            }
            line.clear();
            match reader.read_line(&mut line) {
                Ok(0) => break Ok(()),
                Ok(_) => {}
                Err(e) => {
                    super::kill_child(&mut child);
                    shutdown.store(true, Ordering::SeqCst);
                    if task.is_cancelled() {
                        break Err(CoreError::AiCancelled);
                    }
                    break Err(CoreError::AiCliFailed {
                        message: format!("failed to read claude output: {e}"),
                    });
                }
            }
            if let Some(event) = parse_stream_line(line.trim()) {
                match event {
                    StreamEvent::Init { errors } => {
                        mcp_errors.extend(errors);
                    }
                    StreamEvent::Text(chunk) => {
                        if !chunk.is_empty() {
                            final_text.push_str(&chunk);
                            listener.on_event(ReviewEvent::Text { text: chunk });
                        }
                    }
                    StreamEvent::Thinking => {
                        turns += 1;
                        listener.on_event(ReviewEvent::Thinking { turn: turns });
                    }
                    StreamEvent::Usage { input, output } => {
                        usage.input_tokens = usage.input_tokens.max(input);
                        usage.output_tokens = usage.output_tokens.max(output);
                        listener.on_event(ReviewEvent::Usage {
                            input_tokens: usage.input_tokens,
                            output_tokens: usage.output_tokens,
                        });
                    }
                    StreamEvent::Result {
                        text,
                        is_error,
                        usage: result_usage,
                        message,
                    } => {
                        if result_usage.input_tokens > 0 || result_usage.output_tokens > 0 {
                            usage = result_usage;
                            listener.on_event(ReviewEvent::Usage {
                                input_tokens: usage.input_tokens,
                                output_tokens: usage.output_tokens,
                            });
                        }
                        if is_error {
                            shutdown.store(true, Ordering::SeqCst);
                            let _ = child.wait();
                            break Err(CoreError::AiCliFailed {
                                message: if message.is_empty() { text } else { message },
                            });
                        }
                        if !text.is_empty() {
                            final_text = text;
                        }
                    }
                    StreamEvent::Other => {}
                }
            }
        };

        shutdown.store(true, Ordering::SeqCst);
        if !task.is_cancelled() {
            let _ = child.try_wait();
            // 给 MCP 与子进程一点时间收尾。
            let _ = wait_brief(&mut child, Duration::from_secs(2));
            super::kill_child(&mut child);
        }

        result?;
        if !mcp_errors.is_empty() {
            return Err(CoreError::AiCliFailed {
                message: format!("MCP server failed to load: {}", mcp_errors.join("; ")),
            });
        }

        if let Some((summary, findings)) =
            submission.lock().unwrap_or_else(|e| e.into_inner()).clone()
        {
            return Ok(ReviewResult {
                summary,
                findings,
                revision,
                turns: turns.max(1),
                input_tokens: usage.input_tokens,
                output_tokens: usage.output_tokens,
                incomplete: false,
            });
        }
        if let Some(value) = extract_json(&final_text)
            && let Ok((summary, findings)) = parse_submission_input(context.filter, &value)
        {
            return Ok(ReviewResult {
                summary,
                findings,
                revision,
                turns: turns.max(1),
                input_tokens: usage.input_tokens,
                output_tokens: usage.output_tokens,
                incomplete: false,
            });
        }
        Ok(ReviewResult {
            summary: final_text.trim().to_owned(),
            findings: Vec::new(),
            revision,
            turns: turns.max(1),
            input_tokens: usage.input_tokens,
            output_tokens: usage.output_tokens,
            incomplete: true,
        })
    })
}

fn unique_tempdir() -> Result<std::path::PathBuf> {
    let dir = std::env::temp_dir().join(format!(
        "gitdeck-cli-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0)
    ));
    fs::create_dir_all(&dir)?;
    Ok(dir)
}

fn wait_brief(child: &mut std::process::Child, timeout: Duration) -> bool {
    let start = std::time::Instant::now();
    loop {
        if child.try_wait().ok().flatten().is_some() {
            return true;
        }
        if start.elapsed() >= timeout {
            return false;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StreamEvent {
    Init {
        errors: Vec<String>,
    },
    Text(String),
    Thinking,
    Usage {
        input: u64,
        output: u64,
    },
    Result {
        text: String,
        is_error: bool,
        usage: Usage,
        message: String,
    },
    Other,
}

pub fn parse_stream_line(line: &str) -> Option<StreamEvent> {
    if line.is_empty() {
        return None;
    }
    let value: Value = serde_json::from_str(line).ok()?;
    Some(classify_stream_event(&value))
}

fn classify_stream_event(value: &Value) -> StreamEvent {
    match value["type"].as_str().unwrap_or_default() {
        "system" if value["subtype"].as_str() == Some("init") => {
            let mut errors = Vec::new();
            if let Some(list) = value["mcp_server_errors"].as_array() {
                for item in list {
                    let name = item["name"].as_str().unwrap_or("mcp");
                    let message = item["message"].as_str().unwrap_or("failed");
                    errors.push(format!("{name}: {message}"));
                }
            }
            StreamEvent::Init { errors }
        }
        "stream_event" => {
            let event = &value["event"];
            let typ = event["type"]
                .as_str()
                .or_else(|| event["delta"]["type"].as_str())
                .unwrap_or_default();
            if typ == "text_delta" || event["delta"]["type"].as_str() == Some("text_delta") {
                let text = event["delta"]["text"]
                    .as_str()
                    .or_else(|| event["delta"]["delta"].as_str())
                    .unwrap_or_default()
                    .to_owned();
                if text.is_empty() {
                    StreamEvent::Other
                } else {
                    StreamEvent::Text(text)
                }
            } else if typ.contains("message_start") || typ == "content_block_start" {
                StreamEvent::Thinking
            } else {
                StreamEvent::Other
            }
        }
        "assistant" => {
            let mut text = String::new();
            if let Some(items) = value["message"]["content"].as_array() {
                for item in items {
                    if item["type"].as_str() == Some("text")
                        && let Some(chunk) = item["text"].as_str()
                    {
                        text.push_str(chunk);
                    }
                }
            } else if let Some(chunk) = value["message"]["content"].as_str() {
                text.push_str(chunk);
            }
            if text.is_empty() {
                StreamEvent::Thinking
            } else {
                StreamEvent::Text(text)
            }
        }
        "result" => {
            let usage = parse_usage(&value["usage"]);
            let text = value["result"]
                .as_str()
                .or_else(|| value["structured_output"].as_str())
                .unwrap_or_default()
                .to_owned();
            let is_error = value["is_error"].as_bool().unwrap_or(false)
                || value["subtype"].as_str() == Some("error");
            let message = value["error"]
                .as_str()
                .or_else(|| value["errors"].as_str())
                .unwrap_or_default()
                .to_owned();
            StreamEvent::Result {
                text,
                is_error,
                usage,
                message,
            }
        }
        _ => {
            if value.get("usage").is_some() {
                let usage = parse_usage(&value["usage"]);
                if usage.input_tokens > 0 || usage.output_tokens > 0 {
                    return StreamEvent::Usage {
                        input: usage.input_tokens,
                        output: usage.output_tokens,
                    };
                }
            }
            StreamEvent::Other
        }
    }
}

fn parse_usage(value: &Value) -> Usage {
    Usage {
        input_tokens: value["input_tokens"]
            .as_u64()
            .or_else(|| value["input"].as_u64())
            .unwrap_or(0),
        output_tokens: value["output_tokens"]
            .as_u64()
            .or_else(|| value["output"].as_u64())
            .unwrap_or(0),
    }
}

#[cfg(test)]
mod tests {
    use super::super::tools::tool_specs;
    use super::*;

    #[test]
    fn disables_builtin_tools_and_allows_only_gitdeck_mcp() {
        let args = command_args("/tmp/sys.txt", "/tmp/mcp.json", 24, allowed_tools_value());
        let tools_idx = args.iter().position(|a| a == "--tools").unwrap();
        assert_eq!(args[tools_idx + 1], "");
        assert!(args.contains(&"--strict-mcp-config".into()));
        let allowed_idx = args.iter().position(|a| a == "--allowedTools").unwrap();
        assert_eq!(args[allowed_idx + 1], "mcp__gitdeck__*");
        assert!(args.contains(&"--permission-mode".into()));
        assert!(args.contains(&"dontAsk".into()));
    }

    #[test]
    fn write_file_is_only_registered_when_enabled() {
        let off: Vec<_> = tool_specs(false).iter().map(|t| t.name).collect();
        let on: Vec<_> = tool_specs(true).iter().map(|t| t.name).collect();
        assert!(!off.contains(&"write_file"));
        assert!(on.contains(&"write_file"));
        // 允许规则使用通配；真正的写入门控在 MCP / ToolContext。
        assert_eq!(allowed_tools_value(), "mcp__gitdeck__*");
    }

    #[test]
    fn parses_stream_json_text_usage_and_errors() {
        let text = parse_stream_line(
            r#"{"type":"stream_event","event":{"delta":{"type":"text_delta","text":"Hello"}}}"#,
        );
        assert_eq!(text, Some(StreamEvent::Text("Hello".into())));

        let assistant = parse_stream_line(
            r#"{"type":"assistant","message":{"content":[{"type":"text","text":"World"}]}}"#,
        );
        assert_eq!(assistant, Some(StreamEvent::Text("World".into())));

        let result = parse_stream_line(
            r#"{"type":"result","result":"{\"summary\":\"ok\",\"findings\":[]}","is_error":false,"usage":{"input_tokens":10,"output_tokens":4}}"#,
        );
        match result {
            Some(StreamEvent::Result {
                text,
                is_error,
                usage,
                ..
            }) => {
                assert!(!is_error);
                assert!(text.contains("summary"));
                assert_eq!(usage.input_tokens, 10);
                assert_eq!(usage.output_tokens, 4);
            }
            other => panic!("unexpected {other:?}"),
        }

        let err = parse_stream_line(
            r#"{"type":"result","subtype":"error","is_error":true,"result":"not logged in"}"#,
        );
        match err {
            Some(StreamEvent::Result { is_error, text, .. }) => {
                assert!(is_error);
                assert_eq!(text, "not logged in");
            }
            other => panic!("unexpected {other:?}"),
        }

        let init = parse_stream_line(
            r#"{"type":"system","subtype":"init","mcp_server_errors":[{"name":"gitdeck","message":"invalid_config"}]}"#,
        );
        match init {
            Some(StreamEvent::Init { errors }) => {
                assert!(errors.join(" ").contains("gitdeck"));
            }
            other => panic!("unexpected {other:?}"),
        }
    }
}
