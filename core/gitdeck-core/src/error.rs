/// 核心对外暴露的错误。
///
/// 每个变体即一个错误码，UI 层按变体映射到本地化文案，
/// 这里的 `#[error]` 文本只用于日志与调试，不直接展示给用户。
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum CoreError {
    #[error("git executable not found")]
    GitNotFound,

    #[error("git {found} is too old; {required} or newer is required")]
    GitTooOld { found: String, required: String },

    #[error("not a git repository: {path}")]
    NotARepository { path: String },

    #[error("`git {command}` failed with exit code {exit_code}: {stderr}")]
    CommandFailed {
        command: String,
        exit_code: i32,
        stderr: String,
    },

    #[error("failed to parse git output: {detail}")]
    Parse { detail: String },

    #[error("I/O error: {detail}")]
    Io { detail: String },

    #[error("commit message is empty")]
    EmptyCommitMessage,

    #[error("no files selected to commit")]
    NothingToCommit,

    #[error("invalid branch name: {name}")]
    InvalidBranchName { name: String },

    #[error("invalid tag name: {name}")]
    InvalidTagName { name: String },

    /// 签出、合并等操作会覆盖未提交的改动；UI 据此提供 Smart / Force 选项。
    #[error("local changes would be overwritten: {files:?}")]
    LocalChangesWouldBeOverwritten { files: Vec<String> },

    #[error("branch {name} is not fully merged")]
    BranchNotFullyMerged { name: String },

    #[error("branch {branch} has no upstream branch")]
    NoUpstream { branch: String },

    #[error("HEAD is detached")]
    DetachedHead,

    #[error("push rejected: {reason}")]
    PushRejected { reason: String },

    #[error("authentication failed: {detail}")]
    AuthenticationFailed { detail: String },

    /// 交互式变基的范围内包含合并提交（会被线性化），暂不支持。
    #[error("the commits to rebase contain merge commits")]
    RebaseWithMerges,

    /// 交互式变基的步骤无效，例如第一个提交被设为压缩 / 修整。
    #[error("invalid rebase plan: {detail}")]
    InvalidRebasePlan { detail: String },

    /// 无法连接模型服务（DNS、TLS、超时等）。
    #[error("AI network error: {detail}")]
    AiNetwork { detail: String },

    /// API Key 无效或无权访问（HTTP 401 / 403）。
    #[error("AI authentication failed: {message}")]
    AiAuthenticationFailed { message: String },

    /// 模型服务返回错误；`status` 为 HTTP 状态码（429 限流、529 过载等），流中途的错误按对应状态码给出。
    #[error("AI request failed ({status}): {message}")]
    AiRequestFailed { status: u16, message: String },

    /// 模型拒绝处理请求（`stop_reason: refusal`）。
    #[error("AI model declined the request ({category:?})")]
    AiRefused { category: Option<String> },

    /// 模型的输出不符合预期格式。
    #[error("unexpected AI response: {detail}")]
    AiInvalidResponse { detail: String },

    #[error("AI task cancelled")]
    AiCancelled,
}

impl CoreError {
    /// 把常见的网络认证失败从通用的命令失败中识别出来。
    pub(crate) fn classify_remote(self) -> Self {
        match self {
            CoreError::CommandFailed { stderr, .. }
                if [
                    "Authentication failed",
                    "could not read Username",
                    "could not read Password",
                    "terminal prompts disabled",
                    "Permission denied (publickey",
                    "HTTP Basic: Access denied",
                ]
                .iter()
                .any(|needle| stderr.contains(needle)) =>
            {
                CoreError::AuthenticationFailed { detail: stderr }
            }
            other => other,
        }
    }
}

impl From<std::io::Error> for CoreError {
    fn from(err: std::io::Error) -> Self {
        CoreError::Io {
            detail: err.to_string(),
        }
    }
}

pub type Result<T> = std::result::Result<T, CoreError>;
