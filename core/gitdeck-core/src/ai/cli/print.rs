//! 非交互 print/exec 评审：把 GitDeck 的评审提示交给 CLI，再从最终文本解析结果。
//!
//! 这些 CLI 使用各自的只读（或按设置开放的写入）工具，而不是 GitDeck MCP。
//! 系统提示要求只回复评审 JSON，diff 已包含在用户提示中。

use std::io::{BufRead, BufReader, Read, Write};
use std::process::Stdio;
use std::time::Duration;

use serde_json::Value;

use super::super::AiTask;
use super::super::provider::Usage;
use super::super::review::{
    ReviewEvent, ReviewListener, ReviewResult, extract_json, parse_submission_input,
};
use super::super::tools::ToolContext;
use super::catalog::{OutputFormat, PromptInput};
use super::command::{TempDirCleanup, command, unique_tempdir};
use super::{DetectedAiCli, catalog};
use crate::error::{CoreError, Result};

#[allow(clippy::too_many_arguments)]
pub fn run(
    resolved: &DetectedAiCli,
    repo: &crate::repo::Repository,
    system: &str,
    prompt: &str,
    context: ToolContext<'_>,
    max_turns: u32,
    task: &AiTask,
    listener: &dyn ReviewListener,
    revision: Option<String>,
) -> Result<ReviewResult> {
    let spec = catalog::find(&resolved.id).ok_or_else(|| CoreError::AiCliNotFound {
        name: resolved.id.clone(),
    })?;
    let profile = spec
        .print
        .as_ref()
        .ok_or_else(|| CoreError::AiCliNotFound {
            name: resolved.id.clone(),
        })?;

    let tmp = unique_tempdir()?;
    let _cleanup = TempDirCleanup(tmp.clone());
    let system_path = tmp.join("system.txt");
    let prompt_path = tmp.join("prompt.txt");
    let combined = format!("{system}\n\n{prompt}");
    std::fs::write(&system_path, system)?;
    let prompt_body = match profile.prompt {
        PromptInput::SystemFileUserStdin => prompt.to_owned(),
        PromptInput::CombinedStdin
        | PromptInput::CombinedFile
        | PromptInput::CombinedAsPromptFlag => combined.clone(),
    };
    std::fs::write(&prompt_path, &prompt_body)?;

    let args = (profile.args)(&catalog::PrintArgCtx {
        system_file: &system_path,
        prompt_file: &prompt_path,
        write_permission: context.write_permission,
        max_turns,
    });

    listener.on_event(ReviewEvent::Thinking { turn: 1 });

    let mut child = command(&resolved.path)
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

    let stdin_payload = match profile.prompt {
        PromptInput::CombinedStdin => Some(combined.into_bytes()),
        PromptInput::SystemFileUserStdin => Some(prompt.as_bytes().to_vec()),
        PromptInput::CombinedFile | PromptInput::CombinedAsPromptFlag => None,
    };
    if let Some(payload) = stdin_payload {
        if let Some(mut stdin) = child.stdin.take() {
            let _ = stdin.write_all(&payload);
            let _ = stdin.flush();
        }
    } else {
        drop(child.stdin.take());
    }

    let stdout = child.stdout.take().ok_or_else(|| CoreError::AiCliFailed {
        message: format!("{} stdout is not available", resolved.id),
    })?;
    let stderr = child.stderr.take().ok_or_else(|| CoreError::AiCliFailed {
        message: format!("{} stderr is not available", resolved.id),
    })?;

    let stderr_buf = std::thread::spawn(move || {
        let mut text = String::new();
        let mut reader = BufReader::new(stderr);
        let mut chunk = String::new();
        loop {
            chunk.clear();
            match reader.read_line(&mut chunk) {
                Ok(0) => break,
                Ok(_) => text.push_str(&chunk),
                Err(_) => break,
            }
            if text.len() > 64 * 1024 {
                break;
            }
        }
        // 若还未到上限，把剩余内容也读完（截断保存）。
        let mut rest = String::new();
        let _ = reader.read_to_string(&mut rest);
        if text.len() < 64 * 1024 {
            let room = 64 * 1024 - text.len();
            text.push_str(&rest.chars().take(room).collect::<String>());
        }
        text
    });

    let mut stdout_text = String::new();
    let mut reader = BufReader::new(stdout);
    let mut line = String::new();
    let read_result = loop {
        if task.is_cancelled() {
            super::kill_child(&mut child);
            break Err(CoreError::AiCancelled);
        }
        line.clear();
        match reader.read_line(&mut line) {
            Ok(0) => break Ok(()),
            Ok(_) => {
                stdout_text.push_str(&line);
            }
            Err(e) => {
                super::kill_child(&mut child);
                if task.is_cancelled() {
                    break Err(CoreError::AiCancelled);
                }
                break Err(CoreError::AiCliFailed {
                    message: format!("failed to read {} output: {e}", resolved.id),
                });
            }
        }
    };
    read_result?;

    let status = {
        let start = std::time::Instant::now();
        loop {
            if task.is_cancelled() {
                super::kill_child(&mut child);
                return Err(CoreError::AiCancelled);
            }
            if let Some(status) = child.try_wait()? {
                break status;
            }
            if start.elapsed() >= Duration::from_millis(50) && task.is_cancelled() {
                super::kill_child(&mut child);
                return Err(CoreError::AiCancelled);
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    };
    let stderr_text = stderr_buf.join().unwrap_or_default();

    if !status.success() {
        let detail = first_nonempty(&stderr_text)
            .or_else(|| first_nonempty(&stdout_text))
            .unwrap_or_else(|| format!("exited with {status}"));
        return Err(CoreError::AiCliFailed {
            message: format!("{} failed: {detail}", resolved.display_name),
        });
    }

    let (final_text, usage, error) = decode_output(profile.output, &stdout_text);
    if let Some(message) = error {
        return Err(CoreError::AiCliFailed {
            message: format!("{}: {message}", resolved.display_name),
        });
    }
    if !final_text.is_empty() {
        listener.on_event(ReviewEvent::Text {
            text: final_text.clone(),
        });
    }
    if usage.input_tokens > 0 || usage.output_tokens > 0 {
        listener.on_event(ReviewEvent::Usage {
            input_tokens: usage.input_tokens,
            output_tokens: usage.output_tokens,
        });
    }

    if let Some(value) = extract_json(&final_text)
        && let Ok((summary, findings)) = parse_submission_input(context.filter, &value)
    {
        return Ok(ReviewResult {
            summary,
            findings,
            revision,
            turns: 1,
            input_tokens: usage.input_tokens,
            output_tokens: usage.output_tokens,
            incomplete: false,
        });
    }
    Ok(ReviewResult {
        summary: final_text.trim().to_owned(),
        findings: Vec::new(),
        revision,
        turns: 1,
        input_tokens: usage.input_tokens,
        output_tokens: usage.output_tokens,
        incomplete: true,
    })
}

fn decode_output(format: OutputFormat, stdout: &str) -> (String, Usage, Option<String>) {
    match format {
        OutputFormat::PlainStdout => (stdout.to_owned(), Usage::default(), None),
        OutputFormat::ResponseEnvelope => parse_response_envelope(stdout),
    }
}

fn parse_response_envelope(stdout: &str) -> (String, Usage, Option<String>) {
    let trimmed = stdout.trim();
    let Ok(value) = serde_json::from_str::<Value>(trimmed) else {
        // 非 JSON 时退回原文，让上层再尝试 extract_json。
        return (stdout.to_owned(), Usage::default(), None);
    };
    if let Some(message) = envelope_error(&value) {
        return (String::new(), Usage::default(), Some(message));
    }
    let text = value["response"].as_str().unwrap_or_default().to_owned();
    let stats = &value["stats"];
    let usage = Usage {
        input_tokens: stats["input_tokens"]
            .as_u64()
            .or_else(|| stats["input"].as_u64())
            .or_else(|| value["usage"]["input_tokens"].as_u64())
            .unwrap_or(0),
        output_tokens: stats["output_tokens"]
            .as_u64()
            .or_else(|| stats["output"].as_u64())
            .or_else(|| value["usage"]["output_tokens"].as_u64())
            .unwrap_or(0),
    };
    (text, usage, None)
}

fn envelope_error(value: &Value) -> Option<String> {
    if let Some(status) = value.get("status").and_then(Value::as_str) {
        let lower = status.to_ascii_lowercase();
        if matches!(lower.as_str(), "error" | "failed" | "failure") {
            if let Some(message) = value
                .get("error")
                .and_then(|e| {
                    e.as_str()
                        .map(str::to_owned)
                        .or_else(|| e.get("message").and_then(Value::as_str).map(str::to_owned))
                })
                .map(|s| s.trim().to_owned())
                .filter(|s| !s.is_empty())
            {
                return Some(message);
            }
            return Some(status.to_owned());
        }
    }
    gemini_error(value)
}

fn gemini_error(value: &Value) -> Option<String> {
    let error = value.get("error")?;
    if error.is_null() {
        return None;
    }
    if let Some(message) = error.as_str().map(str::trim).filter(|s| !s.is_empty()) {
        return Some(message.to_owned());
    }
    if let Some(message) = error["message"]
        .as_str()
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        return Some(message.to_owned());
    }
    let raw = error.to_string();
    (!raw.is_empty() && raw != "null" && raw != "{}").then_some(raw)
}

fn first_nonempty(text: &str) -> Option<String> {
    let line = text.lines().map(str::trim).find(|l| !l.is_empty())?;
    Some(line.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_gemini_json_response_and_errors() {
        let (text, usage, err) = parse_response_envelope(
            r#"{"response":"{\"summary\":\"ok\",\"findings\":[]}","stats":{"input_tokens":9,"output_tokens":3}}"#,
        );
        assert!(err.is_none());
        assert!(text.contains("summary"));
        assert_eq!(usage.input_tokens, 9);
        assert_eq!(usage.output_tokens, 3);

        let (_, _, err) = parse_response_envelope(r#"{"error":{"message":"not logged in"}}"#);
        assert_eq!(err.as_deref(), Some("not logged in"));
    }

    #[test]
    fn gemini_json_falls_back_to_raw_text() {
        let (text, usage, err) = parse_response_envelope("just a review");
        assert!(err.is_none());
        assert_eq!(text, "just a review");
        assert_eq!(usage.input_tokens, 0);
    }

    #[test]
    fn parses_agy_json_envelope_and_usage() {
        let (text, usage, err) = parse_response_envelope(
            r#"{"status":"ok","response":"looks good","error":null,"usage":{"input_tokens":4,"output_tokens":2}}"#,
        );
        assert!(err.is_none());
        assert_eq!(text, "looks good");
        assert_eq!(usage.input_tokens, 4);
        assert_eq!(usage.output_tokens, 2);

        let (_, _, err) =
            parse_response_envelope(r#"{"status":"error","response":"","error":"not logged in"}"#);
        assert_eq!(err.as_deref(), Some("not logged in"));
    }
}
