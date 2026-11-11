//! Phase B：CLI 探测、写权限门控，以及协议 CLI 评审路径的只读工具调用。

mod common;

use std::fs;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use common::*;
use gitdeck_core::{
    AiCliConfig, CoreError, ReviewEvent, ReviewListener, ReviewOptions, ReviewResult, ReviewScope,
    default_ai_cli_write_permission, default_sensitive_patterns, detect_ai_clis, resolve_ai_cli,
};

const MOCK_CLI: &str = r#"#!/usr/bin/env python3
import json, sys

def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    req = json.loads(line)
    if req.get("type") != "request":
        continue
    messages = req.get("messages") or []
    tools = {t.get("name") for t in (req.get("tools") or [])}
    has_tool_result = any(m.get("role") == "tool" for m in messages)
    if not has_tool_result:
        emit({"type": "text", "text": "Looking at the change."})
        emit({"type": "tool_call", "id": "1", "name": "read_file", "input": {"path": "src/app.rs"}})
        emit({"type": "tool_call", "id": "2", "name": "read_file", "input": {"path": ".env"}})
        emit({"type": "tool_call", "id": "3", "name": "search_code", "input": {"pattern": "TODO"}})
        emit({"type": "tool_call", "id": "4", "name": "write_file", "input": {"path": "src/app.rs", "content": "fn main() { /* fixed */ }\n"}})
        emit({"type": "stop", "reason": "tool_use", "usage": {"input_tokens": 11, "output_tokens": 4}})
    else:
        emit({
            "type": "tool_call",
            "id": "9",
            "name": "submit_review",
            "input": {
                "summary": "Reviewed with tools.",
                "findings": [{
                    "file": "src/app.rs",
                    "line": 1,
                    "severity": "warning",
                    "title": "unfinished work",
                    "explanation": "There is a TODO in the change."
                }]
            }
        })
        emit({"type": "stop", "reason": "tool_use", "usage": {"input_tokens": 15, "output_tokens": 6}})
"#;

const VERSION_CLI: &str = r#"#!/bin/sh
if [ "$1" = "-v" ] || [ "$1" = "--version" ]; then
  echo "claude 2.1.0 (test fixture)"
  exit 0
fi
echo "unexpected invocation: $*" >&2
exit 1
"#;

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

fn options() -> ReviewOptions {
    ReviewOptions {
        language: "English".into(),
        sensitive_patterns: default_sensitive_patterns(),
        max_turns: 8,
        token_budget: 0,
    }
}

fn write_executable(dir: &std::path::Path, name: &str, contents: &str) -> std::path::PathBuf {
    let path = dir.join(name);
    fs::write(&path, contents).unwrap();
    #[cfg(unix)]
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
    path
}

fn setup_review_repo(dir: &std::path::Path) {
    new_repo(dir);
    fs::create_dir_all(dir.join("src")).unwrap();
    fs::write(dir.join("src/app.rs"), "fn main() { /* TODO */ }\n").unwrap();
    fs::write(dir.join(".env"), "SECRET=1\n").unwrap();
    git(dir, &["add", "src/app.rs"]);
    // .env is untracked on purpose; the dummy change under review is src/app.rs.
}

fn run_cli_review(dir: &std::path::Path, cli: AiCliConfig) -> Vec<ReviewEvent> {
    let repo = Arc::new(open(dir));
    let (listener, done) = collector();
    let _task = repo.start_ai_cli_review(
        cli,
        ReviewScope::LocalChanges {
            paths: vec!["src/app.rs".into()],
        },
        options(),
        listener.clone(),
    );
    done.recv_timeout(Duration::from_secs(30))
        .expect("cli review finished");
    listener.events.lock().unwrap().clone()
}

fn finished(events: &[ReviewEvent]) -> ReviewResult {
    for event in events {
        if let ReviewEvent::Finished { result } = event {
            return result.clone();
        }
        if let ReviewEvent::Failed { error } = event {
            panic!("review failed: {error}");
        }
    }
    panic!("no finished event: {events:?}")
}

fn tool_calls(events: &[ReviewEvent]) -> Vec<(String, String)> {
    events
        .iter()
        .filter_map(|e| match e {
            ReviewEvent::ToolCall { name, detail } => Some((name.clone(), detail.clone())),
            _ => None,
        })
        .collect()
}

#[test]
fn write_permission_defaults_off() {
    assert!(!default_ai_cli_write_permission());
}

#[test]
fn detect_ai_clis_does_not_panic() {
    let _ = detect_ai_clis();
}

#[cfg(unix)]
#[test]
fn resolve_detects_explicit_executable_and_version() {
    let dir = tempfile::tempdir().unwrap();
    let path = write_executable(dir.path(), "claude", VERSION_CLI);
    let cli = resolve_ai_cli("claude".into(), path.to_string_lossy().into_owned()).unwrap();
    assert_eq!(cli.id, "claude");
    assert_eq!(cli.display_name, "Claude Code");
    assert_eq!(cli.path, path.to_string_lossy());
    assert!(
        cli.version.as_deref().unwrap_or_default().contains("2.1.0"),
        "version was {:?}",
        cli.version
    );
}

#[test]
fn missing_cli_returns_not_found_not_a_crash() {
    let err = resolve_ai_cli("not-a-real-cli".into(), String::new()).unwrap_err();
    assert!(matches!(err, CoreError::AiCliNotFound { .. }));
    let err = resolve_ai_cli("claude".into(), "/no/such/gitdeck-cli".into()).unwrap_err();
    assert!(matches!(err, CoreError::AiCliNotFound { .. }));
}

#[cfg(unix)]
#[test]
fn protocol_cli_review_uses_readonly_tools_and_blocks_writes_by_default() {
    let repo_dir = tempfile::tempdir().unwrap();
    setup_review_repo(repo_dir.path());
    let original = fs::read_to_string(repo_dir.path().join("src/app.rs")).unwrap();

    let bin = tempfile::tempdir().unwrap();
    let cli_path = write_executable(bin.path(), "gitdeck-protocol-cli", MOCK_CLI);
    let events = run_cli_review(
        repo_dir.path(),
        AiCliConfig {
            id: "gitdeck-protocol".into(),
            executable: cli_path.to_string_lossy().into_owned(),
            write_permission: default_ai_cli_write_permission(),
        },
    );
    let result = finished(&events);
    assert!(!result.incomplete);
    assert_eq!(result.summary, "Reviewed with tools.");
    assert_eq!(result.findings.len(), 1);
    assert_eq!(result.findings[0].file, "src/app.rs");

    let calls = tool_calls(&events);
    let names: Vec<_> = calls.iter().map(|(n, _)| n.as_str()).collect();
    assert!(names.contains(&"read_file"), "calls: {calls:?}");
    assert!(names.contains(&"search_code"), "calls: {calls:?}");
    assert!(
        calls
            .iter()
            .any(|(n, d)| n == "read_file" && d.contains("app.rs")),
        "calls: {calls:?}"
    );
    assert!(
        calls
            .iter()
            .any(|(n, d)| n == "read_file" && d.contains(".env")),
        "sensitive path should still be attempted and rejected, calls: {calls:?}"
    );
    // 默认关闭写入：工作区文件不得被改写。
    assert_eq!(
        fs::read_to_string(repo_dir.path().join("src/app.rs")).unwrap(),
        original
    );
}

#[cfg(unix)]
#[test]
fn protocol_cli_review_writes_only_when_permission_enabled_and_still_blocks_secrets() {
    let repo_dir = tempfile::tempdir().unwrap();
    setup_review_repo(repo_dir.path());

    let bin = tempfile::tempdir().unwrap();
    // 这个脚本在获得工具结果后尝试写入 .env，再提交评审。
    let script = MOCK_CLI.replace(
        r#"emit({"type": "tool_call", "id": "4", "name": "write_file", "input": {"path": "src/app.rs", "content": "fn main() { /* fixed */ }\n"}})"#,
        r#"emit({"type": "tool_call", "id": "4", "name": "write_file", "input": {"path": "src/app.rs", "content": "fn main() { /* fixed */ }\n"}})
        emit({"type": "tool_call", "id": "5", "name": "write_file", "input": {"path": ".env", "content": "SECRET=hacked\n"}})"#,
    );
    let cli_path = write_executable(bin.path(), "gitdeck-protocol-cli", &script);
    let events = run_cli_review(
        repo_dir.path(),
        AiCliConfig {
            id: "gitdeck-protocol".into(),
            executable: cli_path.to_string_lossy().into_owned(),
            write_permission: true,
        },
    );
    let result = finished(&events);
    assert!(!result.incomplete);
    assert_eq!(
        fs::read_to_string(repo_dir.path().join("src/app.rs")).unwrap(),
        "fn main() { /* fixed */ }\n"
    );
    assert_eq!(
        fs::read_to_string(repo_dir.path().join(".env")).unwrap(),
        "SECRET=1\n"
    );
    assert_eq!(result.summary, "Reviewed with tools.");
}
