//! GitDeck 共享核心。
//!
//! 经 UniFFI 为 macOS（Swift）与 Windows（C#）生成绑定，
//! 两端 UI 只负责展示与交互，git 调用、解析与业务逻辑都在这里。

uniffi::setup_scaffolding!();

mod blame;
mod branch_ops;
mod commit;
mod conflicts;
mod diff;
mod error;
pub mod git;
mod graph;
mod highlight;
mod history;
mod remote;
mod repo;
mod stash;

pub use blame::{BlameCommit, BlameResult, FileRevision};
pub use branch_ops::{CheckoutMode, CheckoutOutcome, MergeOutcome};
pub use commit::{CommitOptions, CommitResult};
pub use conflicts::{
    ConflictLabels, ConflictSide, ConflictVersions, MergeChunk, MergeChunkKind, merge_chunks,
};
pub use diff::{
    DiffBlock, LineChange, LineChangeKind, TextRange, WhitespaceMode, diff_texts, line_changes,
};
pub use error::CoreError;
pub use git::branches::{BranchKind, BranchRef};
pub use git::log::{ChangedFile, RefKind, RefLabel};
pub use git::runner::set_askpass_program;
pub use git::status::{
    BranchStatus, ChangeKind, ConflictKind, FileChange, RepoStatus, RepositoryState,
};
pub use graph::{EdgePart, GraphEdge, GraphRow};
pub use highlight::{HighlightSpan, TokenKind, highlight, language_for_path};
pub use history::{CommitDetails, LogCommit, LogFilter, LogOrder, LogPage};
pub use remote::{
    OutgoingCommit, PushOptions, PushResult, PushTarget, Remote, UpdateMethod, UpdateResult,
};
pub use repo::{GitInfo, Repository, git_info};
pub use stash::{StashEntry, StashOptions, StashRevisions, UnstashOutcome, stash_revisions};

/// 核心库版本，用于 About 对话框与诊断信息。
#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_owned()
}
