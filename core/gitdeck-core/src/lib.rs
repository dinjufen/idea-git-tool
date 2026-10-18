//! GitDeck 共享核心。
//!
//! 经 UniFFI 为 macOS（Swift）与 Windows（C#）生成绑定，
//! 两端 UI 只负责展示与交互，git 调用、解析与业务逻辑都在这里。

uniffi::setup_scaffolding!();

mod ai;
mod blame;
mod branch_ops;
mod changelists;
mod changes;
mod commit;
mod conflicts;
mod console;
mod diff;
mod error;
pub mod git;
mod graph;
mod highlight;
mod history;
mod patch;
mod remote;
mod repo;
mod rewrite;
mod shelf;
mod stash;
mod tags;
mod workspace;

pub use ai::{
    AiProviderConfig, AiProviderKind, AiTask, ReviewEvent, ReviewFinding, ReviewListener,
    ReviewOptions, ReviewResult, ReviewScope, ReviewSeverity, ReviewSuggestion,
    apply_review_suggestion, default_ai_base_url, default_sensitive_patterns, is_sensitive_path,
    test_ai_connection,
};
pub use blame::{BlameCommit, BlameResult, FileRevision};
pub use branch_ops::{CheckoutMode, CheckoutOutcome, MergeOutcome};
pub use changelists::{Changelist, Changelists, DEFAULT_CHANGELIST, default_changelist_name};
pub use commit::{CommitOptions, CommitResult, PartialFile};
pub use conflicts::{
    ConflictLabels, ConflictSide, ConflictVersions, MergeChunk, MergeChunkKind, merge_chunks,
};
pub use console::{ConsoleEntry, clear_console, console_entries};
pub use diff::{
    DiffBlock, LineChange, LineChangeKind, TextRange, WhitespaceMode, diff_texts, line_changes,
    partial_text,
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
pub use patch::{PatchFile, PatchOutcome};
pub use remote::{
    OutgoingCommit, PushOptions, PushResult, PushTarget, Remote, UpdateMethod, UpdateResult,
};
pub use repo::{GitInfo, Repository, clone_directory_name, clone_repository, git_info};
pub use rewrite::{RebaseAction, RebaseCommit, RebaseStep, ResetMode};
pub use shelf::{ShelfEntry, ShelfFileVersions};
pub use stash::{StashEntry, StashOptions, StashRevisions, UnstashOutcome, stash_revisions};
pub use tags::TagInfo;
pub use workspace::{Submodule, SubmoduleState, Worktree};

/// 核心库版本，用于 About 对话框与诊断信息。
#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_owned()
}
