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
