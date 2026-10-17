use std::path::{Path, PathBuf};
use std::sync::Arc;

use crate::error::{CoreError, Result};
use crate::git::branches::{self, BranchRef};
use crate::git::runner::GitExecutable;
use crate::git::status::{self, RepoStatus};

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
    git: GitExecutable,
    root: PathBuf,
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
        status::parse_status_v2(&out.stdout)
    }

    pub fn branches(&self) -> std::result::Result<Vec<BranchRef>, CoreError> {
        let out = self.git.run(&self.root, branches::BRANCH_ARGS)?;
        branches::parse_branches(&out.stdout)
    }
}

impl Repository {
    pub fn open_with(git: GitExecutable, path: &Path) -> Result<Self> {
        if !path.is_dir() {
            return Err(CoreError::NotARepository {
                path: path.to_string_lossy().into_owned(),
            });
        }
        let out = git
            .run(path, ["rev-parse", "--show-toplevel"])
            .map_err(|err| match err {
                CoreError::CommandFailed { .. } => CoreError::NotARepository {
                    path: path.to_string_lossy().into_owned(),
                },
                other => other,
            })?;
        let root = String::from_utf8_lossy(&out.stdout).trim_end().to_owned();
        Ok(Repository {
            git,
            root: PathBuf::from(root),
        })
    }

    pub fn root_path(&self) -> &Path {
        &self.root
    }
}
