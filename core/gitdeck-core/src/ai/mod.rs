//! AI 代码评审：模型调用、只读评审 Agent 与提交信息生成。
//!
//! API Key 由客户端从系统钥匙串读取后逐次传入，核心不保存。
//! 发给模型的 diff 与 Agent 工具都经过敏感文件过滤（见 [`filter`]）。

mod filter;
mod http;
mod provider;
mod review;
mod sse;
mod tools;

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

pub use filter::{default_sensitive_patterns, is_sensitive_path};
pub use review::{
    ReviewEvent, ReviewFinding, ReviewListener, ReviewOptions, ReviewResult, ReviewScope,
    ReviewSeverity, ReviewSuggestion, apply_review_suggestion, test_ai_connection,
};

use crate::error::{CoreError, Result};

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum AiProviderKind {
    /// Anthropic Messages API（Claude）。
    Anthropic,
    /// OpenAI 兼容的 Chat Completions 接口（OpenAI、DeepSeek、通义千问、Kimi、智谱、Ollama、LM Studio 等）。
    OpenAiCompatible,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AiProviderConfig {
    pub kind: AiProviderKind,
    /// 服务地址，例如 `https://api.anthropic.com`、`https://api.openai.com/v1`、`http://localhost:11434/v1`。
    pub base_url: String,
    pub model: String,
    /// 单次回复的输出上限（Claude 的思考内容也计入）。
    pub max_tokens: u32,
    /// 模型支持工具调用；不支持时评审退化为单次调用（diff 加变更文件全文）。
    pub supports_tools: bool,
    /// Claude 的 `output_config.effort`（`low` / `medium` / `high` / `xhigh` / `max`），为空时用服务端默认。
    pub effort: Option<String>,
}

/// 各协议的默认服务地址。
#[uniffi::export]
pub fn default_ai_base_url(kind: AiProviderKind) -> String {
    match kind {
        AiProviderKind::Anthropic => "https://api.anthropic.com".into(),
        AiProviderKind::OpenAiCompatible => "https://api.openai.com/v1".into(),
    }
}

/// 一次 AI 任务的取消句柄。评审由核心在后台线程执行并返回该句柄；
/// 生成提交信息等阻塞调用则由调用方创建后传入。
#[derive(Debug, Default, uniffi::Object)]
pub struct AiTask {
    cancelled: AtomicBool,
    lock: Mutex<()>,
    wake: Condvar,
}

#[uniffi::export]
impl AiTask {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    /// 请求取消；正在进行的请求在收到下一段数据时停止。
    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::SeqCst);
        let _guard = self.lock.lock();
        self.wake.notify_all();
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::SeqCst)
    }
}

impl AiTask {
    pub(crate) fn check(&self) -> Result<()> {
        if self.is_cancelled() {
            Err(CoreError::AiCancelled)
        } else {
            Ok(())
        }
    }

    /// 可被取消打断的等待（重试退避时使用）。
    pub(crate) fn sleep(&self, duration: Duration) -> Result<()> {
        let guard = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        let _ = self
            .wake
            .wait_timeout_while(guard, duration, |_| !self.is_cancelled());
        self.check()
    }
}
