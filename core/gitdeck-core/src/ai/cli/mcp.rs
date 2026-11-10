//! 本进程内的 MCP HTTP 服务，向 Claude Code 等 CLI 暴露 GitDeck 的评审工具。
//! 只监听 127.0.0.1，并用一次性令牌校验请求。

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{Value, json};

use super::super::filter::SensitiveFilter;
use super::super::provider::ToolSpec;
use super::super::review::{ReviewEvent, ReviewFinding, ReviewListener, parse_submission_input};
use super::super::tools::{self, SUBMIT_REVIEW, ToolContext};
use crate::error::{CoreError, Result};
use crate::repo::Repository;

type SubmissionLock = Mutex<Option<(String, Vec<ReviewFinding>)>>;
type SharedSubmission = Arc<SubmissionLock>;

/// 在当前线程的引用上启动 MCP 服务（由 `thread::scope` 的调用方保证生命周期）。
#[allow(clippy::too_many_arguments)]
pub fn spawn(
    listener_addr: &TcpListener,
    token: String,
    shutdown: Arc<AtomicBool>,
    repo: &Repository,
    filter: &SensitiveFilter,
    revision: Option<String>,
    write_permission: bool,
    tools: Vec<ToolSpec>,
    review_listener: &dyn ReviewListener,
    submission: SharedSubmission,
) {
    listener_addr.set_nonblocking(true).ok();
    let tools = Arc::new(tools);
    while !shutdown.load(Ordering::SeqCst) {
        match listener_addr.accept() {
            Ok((stream, _)) => {
                if let Err(e) = handle_connection(
                    stream,
                    &token,
                    repo,
                    filter,
                    revision.as_deref(),
                    write_permission,
                    &tools,
                    review_listener,
                    &submission,
                ) {
                    let _ = e;
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(15));
            }
            Err(_) => {
                if shutdown.load(Ordering::SeqCst) {
                    break;
                }
                std::thread::sleep(Duration::from_millis(15));
            }
        }
    }
}

pub fn bind() -> Result<(TcpListener, u16, String)> {
    let listener = TcpListener::bind("127.0.0.1:0").map_err(|e| CoreError::AiCliFailed {
        message: format!("failed to bind MCP port: {e}"),
    })?;
    let port = listener
        .local_addr()
        .map_err(|e| CoreError::AiCliFailed {
            message: format!("failed to read MCP port: {e}"),
        })?
        .port();
    let token = format!("{:032x}", random_token());
    Ok((listener, port, token))
}

pub fn mcp_config(port: u16, token: &str) -> Value {
    json!({
        "mcpServers": {
            "gitdeck": {
                "type": "http",
                "url": format!("http://127.0.0.1:{port}/mcp"),
                "headers": {
                    "Authorization": format!("Bearer {token}")
                }
            }
        }
    })
}

fn random_token() -> u128 {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    std::time::SystemTime::now().hash(&mut hasher);
    std::process::id().hash(&mut hasher);
    std::thread::current().id().hash(&mut hasher);
    ((hasher.finish() as u128) << 64) | hasher.finish() as u128
}

#[allow(clippy::too_many_arguments)]
fn handle_connection(
    mut stream: TcpStream,
    token: &str,
    repo: &Repository,
    filter: &SensitiveFilter,
    revision: Option<&str>,
    write_permission: bool,
    tools: &[ToolSpec],
    review_listener: &dyn ReviewListener,
    submission: &SubmissionLock,
) -> std::io::Result<()> {
    stream.set_read_timeout(Some(Duration::from_secs(30)))?;
    stream.set_write_timeout(Some(Duration::from_secs(30)))?;
    let mut header_buf = Vec::new();
    let mut byte = [0u8; 1];
    loop {
        if stream.read(&mut byte)? == 0 {
            return Ok(());
        }
        header_buf.push(byte[0]);
        if header_buf.windows(4).any(|w| w == b"\r\n\r\n") {
            break;
        }
        if header_buf.len() > 64 * 1024 {
            return write_http(&mut stream, 431, "text/plain", b"headers too large");
        }
    }
    let headers = String::from_utf8_lossy(&header_buf);
    let Some(first) = headers.lines().next() else {
        return Ok(());
    };
    let mut parts = first.split_whitespace();
    let method = parts.next().unwrap_or("");
    let path = parts.next().unwrap_or("/");
    if method.eq_ignore_ascii_case("OPTIONS") {
        return write_http(&mut stream, 204, "text/plain", b"");
    }
    if !method.eq_ignore_ascii_case("POST") {
        return write_http(&mut stream, 405, "text/plain", b"method not allowed");
    }
    if path != "/mcp" && path != "/" && path != "/mcp/" {
        return write_http(&mut stream, 404, "text/plain", b"not found");
    }
    if !authorized(&headers, token) {
        return write_http(
            &mut stream,
            401,
            "application/json",
            b"{\"error\":\"unauthorized\"}",
        );
    }
    let length = headers
        .lines()
        .find_map(|l| {
            let (k, v) = l.split_once(':')?;
            k.eq_ignore_ascii_case("content-length")
                .then(|| v.trim().parse::<usize>().ok())?
        })
        .unwrap_or(0);
    if length > 8 * 1024 * 1024 {
        return write_http(&mut stream, 413, "text/plain", b"too large");
    }
    let mut body = vec![0; length];
    stream.read_exact(&mut body)?;
    let Ok(value) = serde_json::from_slice::<Value>(&body) else {
        return write_http(
            &mut stream,
            400,
            "application/json",
            b"{\"error\":\"invalid json\"}",
        );
    };
    if value.is_array() {
        let mut results = Vec::new();
        if let Some(items) = value.as_array() {
            for item in items {
                if let Some(resp) = dispatch(
                    item,
                    repo,
                    filter,
                    revision,
                    write_permission,
                    tools,
                    review_listener,
                    submission,
                ) {
                    results.push(resp);
                }
            }
        }
        let out = Value::Array(results).to_string();
        return write_http(&mut stream, 200, "application/json", out.as_bytes());
    }
    match dispatch(
        &value,
        repo,
        filter,
        revision,
        write_permission,
        tools,
        review_listener,
        submission,
    ) {
        Some(resp) => {
            let out = resp.to_string();
            write_http(&mut stream, 200, "application/json", out.as_bytes())
        }
        None => write_http(&mut stream, 202, "text/plain", b""),
    }
}

fn authorized(headers: &str, token: &str) -> bool {
    headers.lines().any(|l| {
        let Some((k, v)) = l.split_once(':') else {
            return false;
        };
        k.eq_ignore_ascii_case("authorization") && v.trim() == format!("Bearer {token}")
    })
}

#[allow(clippy::too_many_arguments)]
fn dispatch(
    value: &Value,
    repo: &Repository,
    filter: &SensitiveFilter,
    revision: Option<&str>,
    write_permission: bool,
    tools: &[ToolSpec],
    review_listener: &dyn ReviewListener,
    submission: &SubmissionLock,
) -> Option<Value> {
    let method = value["method"].as_str().unwrap_or_default();
    let id = value.get("id").cloned()?;
    let result = match method {
        "initialize" => json!({
            "protocolVersion": value["params"]["protocolVersion"].as_str().unwrap_or("2025-03-26"),
            "capabilities": { "tools": { "listChanged": false } },
            "serverInfo": { "name": "gitdeck", "version": env!("CARGO_PKG_VERSION") },
        }),
        "ping" => json!({}),
        "tools/list" => json!({
            "tools": tools.iter().map(|t| json!({
                "name": t.name,
                "description": t.description,
                "inputSchema": t.schema,
            })).collect::<Vec<_>>()
        }),
        "tools/call" => {
            let name = value["params"]["name"].as_str().unwrap_or_default();
            let args = value["params"]
                .get("arguments")
                .cloned()
                .unwrap_or_else(|| json!({}));
            call_tool(
                name,
                &args,
                repo,
                filter,
                revision,
                write_permission,
                review_listener,
                submission,
            )
        }
        other => {
            return Some(json!({
                "jsonrpc": "2.0",
                "id": id,
                "error": { "code": -32601, "message": format!("method not found: {other}") }
            }));
        }
    };
    Some(json!({ "jsonrpc": "2.0", "id": id, "result": result }))
}

#[allow(clippy::too_many_arguments)]
fn call_tool(
    name: &str,
    args: &Value,
    repo: &Repository,
    filter: &SensitiveFilter,
    revision: Option<&str>,
    write_permission: bool,
    review_listener: &dyn ReviewListener,
    submission: &SubmissionLock,
) -> Value {
    let context = ToolContext {
        repo,
        filter,
        revision: revision.map(ToOwned::to_owned),
        write_permission,
    };
    if name == SUBMIT_REVIEW || name.ends_with(&format!("__{SUBMIT_REVIEW}")) {
        return match parse_submission_input(filter, args) {
            Ok(result) => {
                *submission.lock().unwrap_or_else(|e| e.into_inner()) = Some(result);
                tool_result("Review received.", false)
            }
            Err(message) => tool_result(&message, true),
        };
    }
    let short = name.rsplit("__").next().unwrap_or(name);
    review_listener.on_event(ReviewEvent::ToolCall {
        name: short.to_owned(),
        detail: tools::describe(short, args),
    });
    match context.run(short, args) {
        Ok(content) => tool_result(&content, false),
        Err(message) => tool_result(&message, true),
    }
}

fn tool_result(text: &str, is_error: bool) -> Value {
    json!({
        "content": [{ "type": "text", "text": text }],
        "isError": is_error,
    })
}

fn write_http(
    stream: &mut TcpStream,
    status: u16,
    content_type: &str,
    body: &[u8],
) -> std::io::Result<()> {
    let reason = match status {
        200 => "OK",
        202 => "Accepted",
        204 => "No Content",
        400 => "Bad Request",
        401 => "Unauthorized",
        404 => "Not Found",
        405 => "Method Not Allowed",
        413 => "Payload Too Large",
        431 => "Request Header Fields Too Large",
        _ => "Error",
    };
    let header = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: *\r\nConnection: close\r\n\r\n",
        body.len()
    );
    stream.write_all(header.as_bytes())?;
    if !body.is_empty() {
        stream.write_all(body)?;
    }
    stream.flush()
}
