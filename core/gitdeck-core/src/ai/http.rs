//! 模型服务的 HTTP 调用：系统原生 TLS、可重试错误的退避重试、错误响应解析。

use std::io::{BufReader, Read};
use std::sync::OnceLock;
use std::time::Duration;

use serde_json::Value;
use ureq::Agent;
use ureq::tls::{RootCerts, TlsConfig, TlsProvider};

use super::AiTask;
use crate::error::{CoreError, Result};

/// 重试次数（不含首次请求），只针对限流、过载与网关错误。
const MAX_RETRIES: u32 = 3;

fn agent() -> &'static Agent {
    static AGENT: OnceLock<Agent> = OnceLock::new();
    AGENT.get_or_init(|| {
        Agent::config_builder()
            // 自行读取错误响应体，给出服务端的错误信息。
            .http_status_as_error(false)
            .timeout_connect(Some(Duration::from_secs(30)))
            // 只限制等待响应头的时间；流式响应体可能持续数分钟。
            .timeout_recv_response(Some(Duration::from_secs(300)))
            .user_agent(format!("GitDeck/{}", env!("CARGO_PKG_VERSION")))
            .tls_config(
                TlsConfig::builder()
                    .provider(TlsProvider::NativeTls)
                    .root_certs(RootCerts::PlatformVerifier)
                    .build(),
            )
            .build()
            .new_agent()
    })
}

/// 发送 JSON 请求并返回响应体读取器（成功状态码）。
pub(crate) fn post(
    url: &str,
    headers: &[(&str, String)],
    body: &Value,
    task: &AiTask,
) -> Result<BufReader<impl Read + use<>>> {
    let payload = serde_json::to_string(body).map_err(|e| CoreError::Parse {
        detail: e.to_string(),
    })?;
    let mut attempt = 0;
    loop {
        task.check()?;
        let mut request = agent()
            .post(url)
            .header("content-type", "application/json")
            .header("accept", "text/event-stream");
        for (name, value) in headers {
            request = request.header(*name, value.as_str());
        }
        let response = request
            .send(payload.as_str())
            .map_err(|e| CoreError::AiNetwork {
                detail: e.to_string(),
            })?;
        let status = response.status().as_u16();
        if (200..300).contains(&status) {
            return Ok(BufReader::new(response.into_body().into_reader()));
        }
        let retry_after = response
            .headers()
            .get("retry-after")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.trim().parse::<u64>().ok());
        let text = response
            .into_body()
            .with_config()
            .limit(64 * 1024)
            .read_to_string()
            .unwrap_or_default();
        let error = status_error(status, &text);
        if attempt < MAX_RETRIES && is_retryable(status) {
            attempt += 1;
            let wait = retry_after.unwrap_or(1 << attempt).min(30);
            task.sleep(Duration::from_secs(wait))?;
            continue;
        }
        return Err(error);
    }
}

fn is_retryable(status: u16) -> bool {
    matches!(status, 408 | 429 | 500 | 502 | 503 | 504 | 529)
}

/// 把错误状态码与响应体转换为错误；两种协议的错误体都形如 `{"error": {"message": ...}}`。
pub(crate) fn status_error(status: u16, body: &str) -> CoreError {
    let message = serde_json::from_str::<Value>(body)
        .ok()
        .and_then(|v| {
            v.pointer("/error/message")
                .and_then(Value::as_str)
                .map(str::to_owned)
        })
        .unwrap_or_else(|| body.chars().take(500).collect::<String>().trim().to_owned());
    match status {
        401 | 403 => CoreError::AiAuthenticationFailed { message },
        _ => CoreError::AiRequestFailed { status, message },
    }
}

/// 流中途收到的错误事件（Anthropic 的 `event: error`、OpenAI 兼容接口的 `{"error": ...}`）。
pub(crate) fn stream_error(value: &Value) -> CoreError {
    let error = value.get("error").unwrap_or(value);
    let message = error
        .get("message")
        .and_then(Value::as_str)
        .unwrap_or("stream error")
        .to_owned();
    let status = match error.get("type").and_then(Value::as_str) {
        Some("overloaded_error") => 529,
        Some("rate_limit_error") => 429,
        Some("authentication_error") => 401,
        Some("permission_error") => 403,
        Some("invalid_request_error") => 400,
        _ => error
            .get("code")
            .and_then(Value::as_u64)
            .and_then(|c| u16::try_from(c).ok())
            .unwrap_or(500),
    };
    status_error(
        status,
        &serde_json::json!({ "error": { "message": message } }).to_string(),
    )
}

pub(crate) fn io_error(e: std::io::Error) -> CoreError {
    CoreError::AiNetwork {
        detail: e.to_string(),
    }
}
