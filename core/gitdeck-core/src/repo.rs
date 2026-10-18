use std::path::{Path, PathBuf};
use std::sync::Arc;

use crate::error::{CoreError, Result};
use crate::git::branches::{self, BranchRef};
use crate::git::runner::GitExecutable;
use crate::git::status::{self, RepoStatus, RepositoryState};

/// 本机 git 的信息，用于设置页展示与启动时的环境检查。
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GitInfo {
    pub path: String,
    pub version: String,
}

#[uniffi::export]
pub fn git_info() -> std::result::Result<GitInfo, CoreError> {
    let git = GitExecutable::locate(None)?;
    Ok(GitInfo {
        path: git.path().to_string_lossy().into_owned(),
        version: git.version().to_string(),
    })
}

/// 一个已打开的工作区仓库。方法均为阻塞调用，UI 侧应在后台线程调用。
#[derive(Debug, uniffi::Object)]
pub struct Repository {
    pub(crate) git: GitExecutable,
    pub(crate) root: PathBuf,
    /// 当前工作树的 git 目录（链接工作树时为 `.git/worktrees/<name>`）。
    pub(crate) git_dir: PathBuf,
}

#[uniffi::export]
impl Repository {
    /// 打开 `path` 所在的仓库；`path` 可以是仓库内任意子目录。
    #[uniffi::constructor]
    pub fn open(path: String) -> std::result::Result<Arc<Self>, CoreError> {
        let git = GitExecutable::locate(None)?;
        Self::open_with(git, Path::new(&path)).map(Arc::new)
    }

    /// 在 `path` 初始化新仓库并打开。
    #[uniffi::constructor]
    pub fn init(path: String) -> std::result::Result<Arc<Self>, CoreError> {
        let git = GitExecutable::locate(None)?;
        let dir = Path::new(&path);
        std::fs::create_dir_all(dir)?;
        git.run(dir, ["init"])?;
        Self::open_with(git, dir).map(Arc::new)
    }

    /// 仓库工作区根目录的绝对路径。
    pub fn root(&self) -> String {
        self.root.to_string_lossy().into_owned()
    }

    pub fn status(&self) -> std::result::Result<RepoStatus, CoreError> {
        let out = self.git.run(&self.root, status::STATUS_ARGS)?;
        let mut status = status::parse_status_v2(&out.stdout)?;
        status.state = self.state();
        Ok(status)
    }

    pub fn branches(&self) -> std::result::Result<Vec<BranchRef>, CoreError> {
        let out = self.git.run(&self.root, branches::BRANCH_ARGS)?;
        branches::parse_branches(&out.stdout)
    }
}

/// 克隆 `url` 到 `directory`（不能已存在且非空），完成后打开。认证经 askpass 弹窗。
#[uniffi::export]
pub fn clone_repository(
    url: String,
    directory: String,
) -> std::result::Result<Arc<Repository>, CoreError> {
    let url = url.trim();
    if url.is_empty() || url.starts_with('-') {
        return Err(CoreError::Parse {
            detail: format!("invalid repository url: {url:?}"),
        });
    }
    let git = GitExecutable::locate(None)?;
    let dir = Path::new(&directory);
    let parent = dir
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .ok_or_else(|| CoreError::Io {
            detail: format!("invalid directory: {directory}"),
        })?;
    std::fs::create_dir_all(parent)?;
    git.run(parent, ["clone", "--", url, directory.as_str()])
        .map_err(CoreError::classify_remote)?;
    Repository::open_with(git, dir).map(Arc::new)
}

/// 从仓库地址推断默认的目录名（`https://host/team/app.git` → `app`）。
#[uniffi::export]
pub fn clone_directory_name(url: String) -> String {
    let trimmed = url.trim().trim_end_matches('/');
    let last = trimmed.rsplit(['/', ':', '\\']).next().unwrap_or(trimmed);
    let name = last.strip_suffix(".git").unwrap_or(last);
    if name.is_empty() {
        "repository".into()
    } else {
        name.to_owned()
    }
}

impl Repository {
    pub fn open_with(git: GitExecutable, path: &Path) -> Result<Self> {
        let not_a_repo = || CoreError::NotARepository {
            path: path.to_string_lossy().into_owned(),
        };
        if !path.is_dir() {
            return Err(not_a_repo());
        }
        let out = git
            .run(path, ["rev-parse", "--show-toplevel", "--absolute-git-dir"])
            .map_err(|err| match err {
                CoreError::CommandFailed { .. } => not_a_repo(),
                other => other,
            })?;
        let text = String::from_utf8_lossy(&out.stdout);
        let mut lines = text.lines();
        let (Some(root), Some(git_dir)) = (lines.next(), lines.next()) else {
            return Err(not_a_repo());
        };
        Ok(Repository {
            git,
            root: PathBuf::from(root),
            git_dir: PathBuf::from(git_dir),
        })
    }

    pub fn root_path(&self) -> &Path {
        &self.root
    }

    /// 根据 git 目录中的标记文件判断正在进行的操作（与 git 自身的提示逻辑一致）。
    pub fn state(&self) -> RepositoryState {
        let exists = |name: &str| self.git_dir.join(name).exists();
        if exists("rebase-merge") || exists("rebase-apply") {
            RepositoryState::Rebasing
        } else if exists("MERGE_HEAD") {
            RepositoryState::Merging
        } else if exists("CHERRY_PICK_HEAD") {
            RepositoryState::CherryPicking
        } else if exists("REVERT_HEAD") {
            RepositoryState::Reverting
        } else {
            RepositoryState::Normal
        }
    }

    /// HEAD 是否指向一个已存在的提交（空仓库返回 false）。
    pub(crate) fn has_head(&self) -> bool {
        self.git
            .run(
                &self.root,
                ["rev-parse", "--verify", "--quiet", "HEAD^{commit}"],
            )
            .is_ok()
    }
}
