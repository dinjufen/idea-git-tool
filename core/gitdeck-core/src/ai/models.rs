//! 查询可用模型列表（Anthropic / OpenAI 兼容），供设置页「查询」使用。

use serde_json::Value;

use super::http;
use super::{AiProviderKind, AiTask};
use crate::error::{CoreError, Result};

/// 一次模型查询结果中的一条。
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AiModelInfo {
    /// 传给 API 的模型 id（也用于设置里保存）。
    pub id: String,
    /// 展示名；没有时与 id 相同。
    pub display_name: String,
    /// 服务端声明的最大输出 token；没有时由客户端用内置默认。
    pub max_output_tokens: Option<u32>,
}

/// 各协议内置的默认最大输出 token（设置页空值/仍为默认时自动填充用）。
#[uniffi::export]
pub fn default_ai_max_tokens(kind: AiProviderKind) -> u32 {
    match kind {
        AiProviderKind::Anthropic => 32_000,
        AiProviderKind::OpenAiCompatible => 8_192,
    }
}

/// 当当前 max tokens 为空或仍是内置默认时，应改用 `suggested`；用户已改过则保留。
#[uniffi::export]
pub fn should_autofill_ai_max_tokens(
    kind: AiProviderKind,
    current: Option<u32>,
    suggested: u32,
) -> u32 {
    let default = default_ai_max_tokens(kind);
    match current {
        None | Some(0) => suggested,
        Some(value) if value == default => suggested,
        Some(value) => value,
    }
}

/// 通过官方 / 兼容的 list-models 接口拉取模型列表。
#[uniffi::export]
pub fn list_ai_models(
    kind: AiProviderKind,
    base_url: String,
    api_key: String,
) -> std::result::Result<Vec<AiModelInfo>, CoreError> {
    if api_key.trim().is_empty() {
        return Err(CoreError::AiAuthenticationFailed {
            message: "API key is empty".into(),
        });
    }
    let task = AiTask::default();
    match kind {
        AiProviderKind::Anthropic => list_anthropic(&base_url, &api_key, &task),
        AiProviderKind::OpenAiCompatible => list_openai_compatible(&base_url, &api_key, &task),
    }
}

fn list_anthropic(base_url: &str, api_key: &str, task: &AiTask) -> Result<Vec<AiModelInfo>> {
    let url = endpoint(base_url, "/v1/models");
    let headers = [
        ("x-api-key", api_key.to_owned()),
        ("anthropic-version", "2023-06-01".into()),
    ];
    let body = http::get(&url, &headers, task)?;
    parse_list_payload(&body, /*openai_style*/ false)
}

fn list_openai_compatible(
    base_url: &str,
    api_key: &str,
    task: &AiTask,
) -> Result<Vec<AiModelInfo>> {
    let url = endpoint(base_url, "/models");
    let headers = [("authorization", format!("Bearer {api_key}"))];
    let body = http::get(&url, &headers, task)?;
    parse_list_payload(&body, /*openai_style*/ true)
}

fn endpoint(base_url: &str, path: &str) -> String {
    let base = base_url.trim().trim_end_matches('/');
    // OpenAI 兼容常见 base 带 /v1；Anthropic 官方 base 不带。
    match path.strip_prefix("/v1") {
        Some(rest) if base.ends_with("/v1") => format!("{base}{rest}"),
        _ if path == "/models" && !base.ends_with("/v1") && !base.contains("/v1/") => {
            // 若用户填了不含 /v1 的兼容地址，仍尝试 /v1/models。
            format!("{base}/v1{path}")
        }
        _ => format!("{base}{path}"),
    }
}

fn parse_list_payload(body: &str, openai_style: bool) -> Result<Vec<AiModelInfo>> {
    let value: Value = serde_json::from_str(body).map_err(|e| CoreError::AiInvalidResponse {
        detail: format!("{e}: {}", body.chars().take(200).collect::<String>()),
    })?;
    let items = value
        .get("data")
        .and_then(Value::as_array)
        .or_else(|| value.as_array())
        .ok_or_else(|| CoreError::AiInvalidResponse {
            detail: "models response missing data array".into(),
        })?;

    let mut models = Vec::with_capacity(items.len());
    for item in items {
        let id = item
            .get("id")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .trim()
            .to_owned();
        if id.is_empty() {
            continue;
        }
        let display_name = item
            .get("display_name")
            .or_else(|| item.get("name"))
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .unwrap_or(id.as_str())
            .to_owned();
        let max_output_tokens = item
            .get("max_output_tokens")
            .or_else(|| item.get("max_tokens"))
            .or_else(|| item.pointer("/limits/max_output_tokens"))
            .and_then(Value::as_u64)
            .and_then(|n| u32::try_from(n).ok())
            .filter(|&n| n > 0);
        // OpenAI 列表常混有非 chat 模型；先全收，由 UI 展示；后续可按需过滤。
        let _ = openai_style;
        models.push(AiModelInfo {
            id,
            display_name,
            max_output_tokens,
        });
    }
    models.sort_by(|a, b| a.id.cmp(&b.id));
    models.dedup_by(|a, b| a.id == b.id);
    Ok(models)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn autofill_only_when_empty_or_default() {
        let kind = AiProviderKind::OpenAiCompatible;
        assert_eq!(should_autofill_ai_max_tokens(kind, None, 64_000), 64_000);
        assert_eq!(should_autofill_ai_max_tokens(kind, Some(0), 64_000), 64_000);
        assert_eq!(
            should_autofill_ai_max_tokens(kind, Some(8_192), 64_000),
            64_000
        );
        assert_eq!(
            should_autofill_ai_max_tokens(kind, Some(12_000), 64_000),
            12_000
        );
    }

    #[test]
    fn parse_openai_style_list() {
        let body =
            r#"{"data":[{"id":"deepseek-chat","object":"model"},{"id":"deepseek-reasoner"}]}"#;
        let models = parse_list_payload(body, true).unwrap();
        assert_eq!(models.len(), 2);
        assert_eq!(models[0].id, "deepseek-chat");
        assert!(models[0].max_output_tokens.is_none());
    }

    #[test]
    fn parse_anthropic_style_with_limit() {
        let body = r#"{"data":[{"id":"claude-sonnet-4-5","display_name":"Claude Sonnet","max_tokens":64000}]}"#;
        let models = parse_list_payload(body, false).unwrap();
        assert_eq!(models[0].display_name, "Claude Sonnet");
        assert_eq!(models[0].max_output_tokens, Some(64_000));
    }
}
