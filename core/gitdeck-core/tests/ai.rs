//! AI 评审：用本地模拟服务返回预置的流式响应，验证两种协议、Agent 循环、敏感文件过滤与重试。

mod common;

use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use common::*;
use gitdeck_core::{
    AiProviderConfig, AiProviderKind, AiTask, CoreError, ReviewEvent, ReviewListener,
    ReviewOptions, ReviewResult, ReviewScope, ReviewSeverity, default_sensitive_patterns,
    test_ai_connection,
};
use serde_json::{Value, json};

struct Request {
    headers: String,
    body: Value,
}

/// 依次用 `responses` 应答请求（每个连接一个），返回服务地址与收到的请求。
fn mock_server(responses: Vec<String>) -> (String, Arc<Mutex<Vec<Request>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let requests = Arc::new(Mutex::new(Vec::new()));
    let recorded = Arc::clone(&requests);
    std::thread::spawn(move || {
        for response in responses {
            let Ok((stream, _)) = listener.accept() else {
                return;
            };
            let mut reader = BufReader::new(stream);
            let mut headers = String::new();
            loop {
                let mut line = String::new();
                if reader.read_line(&mut line).unwrap() == 0 || line == "\r\n" {
                    break;
                }
                headers.push_str(&line);
            }
            let length = headers
                .lines()
                .find_map(|l| {
                    let (k, v) = l.split_once(':')?;
                    k.eq_ignore_ascii_case("content-length")
                        .then(|| v.trim().parse::<usize>().ok())?
                })
                .unwrap_or(0);
            let mut body = vec![0; length];
            reader.read_exact(&mut body).unwrap();
            recorded.lock().unwrap().push(Request {
                headers: headers.to_ascii_lowercase(),
                body: serde_json::from_slice(&body).unwrap_or(Value::Null),
            });
            let mut stream = reader.into_inner();
            stream.write_all(response.as_bytes()).unwrap();
            stream.flush().unwrap();
        }
    });
    (url, requests)
}

fn sse(events: &[Value]) -> String {
    let mut body = String::new();
    for event in events {
        let name = event["type"].as_str().unwrap_or("message");
        body.push_str(&format!("event: {name}\ndata: {event}\n\n"));
    }
    http_ok(&body)
}

fn http_ok(body: &str) -> String {
    format!(
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    )
}

fn http_error(status: u16, body: &str, extra: &str) -> String {
    format!(
        "HTTP/1.1 {status} Error\r\nContent-Type: application/json\r\nContent-Length: {}\r\n{extra}Connection: close\r\n\r\n{body}",
        body.len()
    )
}

/// Anthropic 流式响应：先一个带签名的 thinking 块，再一个 tool_use 块。
fn anthropic_tool_turn(id: &str, name: &str, input: &Value) -> String {
    let json = input.to_string();
    let (first, second) = json.split_at(json.len() / 2);
    sse(&[
        json!({"type": "message_start", "message": {"usage": {"input_tokens": 100, "output_tokens": 1}}}),
        json!({"type": "content_block_start", "index": 0, "content_block": {"type": "thinking", "thinking": ""}}),
        json!({"type": "content_block_delta", "index": 0, "delta": {"type": "signature_delta", "signature": format!("sig-{id}")}}),
        json!({"type": "content_block_stop", "index": 0}),
        json!({"type": "content_block_start", "index": 1, "content_block": {"type": "tool_use", "id": id, "name": name, "input": {}}}),
        json!({"type": "content_block_delta", "index": 1, "delta": {"type": "input_json_delta", "partial_json": first}}),
        json!({"type": "content_block_delta", "index": 1, "delta": {"type": "input_json_delta", "partial_json": second}}),
        json!({"type": "content_block_stop", "index": 1}),
        json!({"type": "message_delta", "delta": {"stop_reason": "tool_use"}, "usage": {"output_tokens": 50}}),
        json!({"type": "message_stop"}),
    ])
}

fn openai_chunks(chunks: &[Value]) -> String {
    let mut body = String::new();
    for chunk in chunks {
        body.push_str(&format!("data: {chunk}\n\n"));
    }
    body.push_str("data: [DONE]\n\n");
    http_ok(&body)
}

fn openai_tool_turn(id: &str, name: &str, input: &Value) -> String {
    let args = input.to_string();
    let (first, second) = args.split_at(args.len() / 2);
    openai_chunks(&[
        json!({"choices": [{"index": 0, "delta": {"role": "assistant", "tool_calls": [{"index": 0, "id": id, "type": "function", "function": {"name": name, "arguments": first}}]}}]}),
        json!({"choices": [{"index": 0, "delta": {"tool_calls": [{"index": 0, "function": {"arguments": second}}]}}]}),
        json!({"choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]}),
        json!({"choices": [], "usage": {"prompt_tokens": 80, "completion_tokens": 20}}),
    ])
}

fn config(kind: AiProviderKind, url: &str, supports_tools: bool) -> AiProviderConfig {
    AiProviderConfig {
        kind,
        base_url: url.to_owned(),
        model: "test-model".into(),
        max_tokens: 16_000,
        supports_tools,
        effort: Some("high".into()),
    }
}

fn options() -> ReviewOptions {
    ReviewOptions {
        language: "English".into(),
        sensitive_patterns: default_sensitive_patterns(),
        max_turns: 0,
        token_budget: 0,
    }
}

struct Collector {
    events: Mutex<Vec<ReviewEvent>>,
    done: Mutex<Sender<()>>,
}

impl ReviewListener for Collector {
    fn on_event(&self, event: ReviewEvent) {
        let finished = matches!(
            event,
            ReviewEvent::Finished { .. } | ReviewEvent::Failed { .. }
        );
        self.events.lock().unwrap().push(event);
        if finished {
            let _ = self.done.lock().unwrap().send(());
        }
    }
}

fn collector() -> (Arc<Collector>, Receiver<()>) {
    let (tx, rx) = channel();
    (
        Arc::new(Collector {
            events: Mutex::new(Vec::new()),
            done: Mutex::new(tx),
        }),
        rx,
    )
}

/// 运行评审直到结束，返回全部事件。
fn review(dir: &std::path::Path, config: AiProviderConfig, scope: ReviewScope) -> Vec<ReviewEvent> {
    let repo = Arc::new(open(dir));
    let (listener, done) = collector();
    let _task = repo.start_ai_review(
        config,
        "test-key".into(),
        scope,
        options(),
        listener.clone(),
    );
    done.recv_timeout(Duration::from_secs(30))
        .expect("review finished");
    listener.events.lock().unwrap().clone()
}

fn finished(events: &[ReviewEvent]) -> ReviewResult {
    match events.last() {
        Some(ReviewEvent::Finished { result }) => result.clone(),
        other => panic!("review did not finish: {other:?}"),
    }
}

/// 带一个本地改动（src/lib.rs）和一个敏感文件改动（.env）的仓库。
fn repo_with_changes(dir: &std::path::Path) {
    new_repo(dir);
    commit_file(
        dir,
        "src/lib.rs",
        "pub fn add(a: i32, b: i32) -> i32 {\n    a + b\n}\n",
        "Add lib",
    );
    commit_file(dir, ".env", "TOKEN=old\n", "Add env");
    fs::write(
        dir.join("src/lib.rs"),
        "pub fn add(a: i32, b: i32) -> i32 {\n    a - b\n}\n",
    )
    .unwrap();
    fs::write(dir.join(".env"), "TOKEN=super-secret-value\n").unwrap();
}

#[test]
fn anthropic_agent_reviews_local_changes() {
    let dir = tempfile::tempdir().unwrap();
    repo_with_changes(dir.path());
    let submission = json!({
        "summary": "The change breaks add.",
        "findings": [{
            "file": "src/lib.rs", "line": 2, "end_line": 2, "severity": "error",
            "title": "Subtraction instead of addition", "explanation": "add() now subtracts.",
            "original": "    a - b\n", "replacement": "    a + b\n"
        }, {
            "file": ".env", "line": 1, "severity": "warning", "title": "Secret", "explanation": "Must be dropped."
        }]
    });
    let (url, requests) = mock_server(vec![
        anthropic_tool_turn("t1", "read_file", &json!({"path": "src/lib.rs"})),
        anthropic_tool_turn("t2", "read_file", &json!({"path": "config/../.env"})),
        anthropic_tool_turn("t3", "read_file", &json!({"path": ".env"})),
        anthropic_tool_turn("t4", "submit_review", &submission),
    ]);
    let events = review(
        dir.path(),
        config(AiProviderKind::Anthropic, &url, true),
        ReviewScope::LocalChanges { paths: vec![] },
    );

    match &events[0] {
        ReviewEvent::Started {
            files, excluded, ..
        } => {
            assert_eq!(files, &["src/lib.rs"]);
            assert_eq!(excluded, &[".env"]);
        }
        other => panic!("unexpected first event {other:?}"),
    }
    assert!(events.iter().any(|e| matches!(e, ReviewEvent::ToolCall { name, detail } if name == "read_file" && detail == "src/lib.rs")));
    let result = finished(&events);
    assert_eq!(
        result.findings.len(),
        1,
        "finding for the excluded file is dropped"
    );
    let finding = &result.findings[0];
    assert_eq!((finding.line, finding.severity), (2, ReviewSeverity::Error));
    assert_eq!(
        finding.suggestion.as_ref().unwrap().replacement,
        "    a + b\n"
    );
    assert_eq!(result.revision, None);
    assert_eq!(result.turns, 4);
    assert_eq!(result.input_tokens, 400);
    assert!(!result.incomplete);

    let requests = requests.lock().unwrap();
    assert_eq!(requests.len(), 4);
    let first = &requests[0];
    assert!(first.headers.contains("x-api-key: test-key"));
    assert!(first.headers.contains("anthropic-version: 2023-06-01"));
    // 非官方地址不发送仅官方 API 支持的字段。
    assert!(!first.headers.contains("anthropic-beta"));
    assert!(first.body.get("fallbacks").is_none());
    assert_eq!(first.body["thinking"]["type"], "adaptive");
    assert_eq!(first.body["output_config"]["effort"], "high");
    assert_eq!(
        first.body["system"][0]["cache_control"]["type"],
        "ephemeral"
    );
    assert!(
        first.body["tools"]
            .as_array()
            .unwrap()
            .iter()
            .any(|t| t["name"] == "submit_review")
    );
    let all = serde_json::to_string(&requests.iter().map(|r| &r.body).collect::<Vec<_>>()).unwrap();
    assert!(
        !all.contains("super-secret-value"),
        "sensitive content never leaves the machine"
    );
    let prompt = first.body["messages"][0]["content"][0]["text"]
        .as_str()
        .unwrap();
    assert!(prompt.contains("    2 +    a - b"));

    // 第二次请求：原样回传 thinking 块（含签名）与 tool_use，并附工具结果。
    let messages = requests[1].body["messages"].as_array().unwrap();
    assert_eq!(messages.len(), 3);
    assert_eq!(messages[1]["content"][0]["signature"], "sig-t1");
    assert_eq!(messages[1]["content"][1]["input"]["path"], "src/lib.rs");
    assert!(messages[1]["content"][1].get("partial_json").is_none());
    let tool_result = &messages[2]["content"][0];
    assert_eq!(tool_result["tool_use_id"], "t1");
    assert!(
        tool_result["content"]
            .as_str()
            .unwrap()
            .contains("    2\t    a - b")
    );
    // 越界路径与敏感文件都被拒绝。
    let rejected = &requests[2].body["messages"][4]["content"][0];
    assert_eq!(rejected["is_error"], true);
    let excluded = &requests[3].body["messages"][6]["content"][0];
    assert_eq!(excluded["is_error"], true);
    assert!(excluded["content"].as_str().unwrap().contains("excluded"));
}

#[test]
fn openai_agent_reviews_commit() {
    let dir = tempfile::tempdir().unwrap();
    new_repo(dir.path());
    let hash = commit_file(
        dir.path(),
        "app.py",
        "def f(x):\n    return x / 0\n",
        "Add f",
    );
    let submission = json!({"summary": "Division by zero.", "findings": [
        {"file": "app.py", "line": 2, "severity": "warning", "title": "Division by zero", "explanation": "Always raises."}
    ]});
    let (url, requests) = mock_server(vec![
        openai_tool_turn("call_1", "search_code", &json!({"pattern": "return x"})),
        openai_tool_turn("call_2", "submit_review", &submission),
    ]);
    let events = review(
        dir.path(),
        config(AiProviderKind::OpenAiCompatible, &url, true),
        ReviewScope::Commits {
            hashes: vec![hash.clone()],
        },
    );
    let result = finished(&events);
    assert_eq!(result.findings.len(), 1);
    assert_eq!(result.revision.as_deref(), Some(hash.as_str()));
    assert_eq!(result.input_tokens, 160);

    let requests = requests.lock().unwrap();
    assert!(
        requests[0]
            .headers
            .contains("authorization: bearer test-key")
    );
    assert_eq!(requests[0].body["max_tokens"], 16_000);
    assert_eq!(requests[0].body["messages"][0]["role"], "system");
    assert!(
        requests[0].body["messages"][1]["content"]
            .as_str()
            .unwrap()
            .contains("Add f")
    );
    let messages = requests[1].body["messages"].as_array().unwrap();
    assert_eq!(
        messages[2]["tool_calls"][0]["function"]["name"],
        "search_code"
    );
    assert_eq!(messages[3]["role"], "tool");
    assert_eq!(messages[3]["tool_call_id"], "call_1");
    assert!(
        messages[3]["content"]
            .as_str()
            .unwrap()
            .contains("app.py:2:    return x / 0")
    );
}

#[test]
fn single_call_review_without_tools() {
    let dir = tempfile::tempdir().unwrap();
    repo_with_changes(dir.path());
    let reply = "```json\n{\"summary\": \"Bug.\", \"findings\": [{\"file\": \"src/lib.rs\", \"line\": 2, \"severity\": \"error\", \"title\": \"Wrong operator\", \"explanation\": \"x\"}]}\n```";
    let (url, requests) = mock_server(vec![openai_chunks(&[
        json!({"choices": [{"index": 0, "delta": {"content": reply}}]}),
        json!({"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}),
    ])]);
    let events = review(
        dir.path(),
        config(AiProviderKind::OpenAiCompatible, &url, false),
        ReviewScope::LocalChanges { paths: vec![] },
    );
    let result = finished(&events);
    assert_eq!(result.findings[0].title, "Wrong operator");
    let requests = requests.lock().unwrap();
    assert!(requests[0].body.get("tools").is_none());
    let prompt = requests[0].body["messages"][1]["content"].as_str().unwrap();
    assert!(prompt.contains("<file path=\"src/lib.rs\">"));
    assert!(!prompt.contains("super-secret-value"));
}

#[test]
fn retries_overload_and_reports_auth_errors() {
    let dir = tempfile::tempdir().unwrap();
    new_repo(dir.path());
    let ok = openai_chunks(&[
        json!({"choices": [{"index": 0, "delta": {"content": "OK"}}]}),
        json!({"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}),
    ]);
    let (url, requests) = mock_server(vec![
        http_error(
            529,
            r#"{"error":{"message":"Overloaded"}}"#,
            "Retry-After: 0\r\n",
        ),
        ok,
        http_error(401, r#"{"error":{"message":"invalid x-api-key"}}"#, ""),
    ]);
    let cfg = config(AiProviderKind::OpenAiCompatible, &url, true);
    assert_eq!(test_ai_connection(cfg.clone(), "k".into()).unwrap(), "OK");
    assert_eq!(requests.lock().unwrap().len(), 2);
    assert_eq!(
        test_ai_connection(cfg, "k".into()),
        Err(CoreError::AiAuthenticationFailed {
            message: "invalid x-api-key".into()
        })
    );
}

#[test]
fn generates_commit_message_from_selected_changes() {
    let dir = tempfile::tempdir().unwrap();
    repo_with_changes(dir.path());
    fs::write(dir.path().join("other.txt"), "unrelated\n").unwrap();
    let (url, requests) = mock_server(vec![openai_chunks(&[
        json!({"choices": [{"index": 0, "delta": {"content": "```\nFix add operator\n```"}}]}),
        json!({"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}),
    ])]);
    let repo = open(dir.path());
    let message = repo
        .generate_commit_message(
            config(AiProviderKind::OpenAiCompatible, &url, true),
            "k".into(),
            vec!["src/lib.rs".into(), ".env".into()],
            "English".into(),
            default_sensitive_patterns(),
            AiTask::new(),
        )
        .unwrap();
    assert_eq!(message, "Fix add operator");
    let requests = requests.lock().unwrap();
    let prompt = requests[0].body["messages"][1]["content"].as_str().unwrap();
    assert!(prompt.contains("Add env"), "recent subjects are included");
    assert!(prompt.contains("a - b"));
    assert!(!prompt.contains("unrelated"), "only selected files");
    assert!(!prompt.contains("super-secret-value"));
    assert!(prompt.contains("not shown for privacy: .env"));
}

#[test]
fn cancelled_task_stops_before_request() {
    let dir = tempfile::tempdir().unwrap();
    repo_with_changes(dir.path());
    let task = AiTask::new();
    task.cancel();
    let repo = open(dir.path());
    let result = repo.generate_commit_message(
        config(AiProviderKind::OpenAiCompatible, "http://127.0.0.1:9", true),
        "k".into(),
        vec![],
        "English".into(),
        default_sensitive_patterns(),
        task,
    );
    assert_eq!(result, Err(CoreError::AiCancelled));
}
