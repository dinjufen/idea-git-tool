//! 分支操作：签出、新建、重命名、删除、合并、变基（对应 IDEA Branches 弹窗中的操作）。

use crate::error::{CoreError, Result};
use crate::git::status::RepositoryState;
use crate::repo::Repository;

/// 签出时本地改动与目标版本冲突的处理方式（IDEA 的 Smart Checkout / Force Checkout）。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, uniffi::Enum)]
pub enum CheckoutMode {
    /// 有冲突的本地改动时报错（[`CoreError::LocalChangesWouldBeOverwritten`]），由 UI 询问用户。
    #[default]
    Normal,
    /// 先暂存（stash）本地改动，签出后再恢复。
    Smart,
    /// 丢弃冲突的本地改动。
    Force,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, uniffi::Record)]
pub struct CheckoutOutcome {
    /// Smart 签出后恢复本地改动时发生冲突；改动仍保留在 stash 中。
    pub stash_conflicts: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum MergeOutcome {
    UpToDate,
    FastForward,
    /// 已完成合并（或变基）。
    Merged,
    /// 出现冲突，仓库处于合并 / 变基进行中状态，需要解决冲突后继续。
    Conflicts,
}

#[uniffi::export]
impl Repository {
    /// 分支名是否合法（`git check-ref-format --branch`）。
    pub fn is_valid_branch_name(&self, name: String) -> bool {
        !name.is_empty()
            && !name.starts_with('-')
            && self
                .git
                .run(&self.root, ["check-ref-format", "--branch", name.as_str()])
                .is_ok()
    }

    /// 签出本地分支。
    pub fn checkout_branch(
        &self,
        name: String,
        mode: CheckoutMode,
    ) -> std::result::Result<CheckoutOutcome, CoreError> {
        self.switch(&["--no-guess"], &[name.as_str()], mode)
    }

    /// 签出远程分支：已有同名本地分支时签出本地分支，否则创建跟踪该远程分支的本地分支。
    pub fn checkout_remote_branch(
        &self,
        remote_branch: String,
        mode: CheckoutMode,
    ) -> std::result::Result<CheckoutOutcome, CoreError> {
        let (_, local) =
            remote_branch
                .split_once('/')
                .ok_or_else(|| CoreError::InvalidBranchName {
                    name: remote_branch.clone(),
                })?;
        if self.local_branch_exists(local) {
            return self.checkout_branch(local.to_owned(), mode);
        }
        self.switch(&["--track", "-c", local], &[remote_branch.as_str()], mode)
    }

    /// 签出任意修订（分离 HEAD），对应 IDEA 的 “Checkout Tag or Revision”。
    pub fn checkout_revision(
        &self,
        revision: String,
        mode: CheckoutMode,
    ) -> std::result::Result<CheckoutOutcome, CoreError> {
        self.switch(&["--detach"], &[revision.as_str()], mode)
    }

    /// 从 `start_point`（默认当前 HEAD）新建分支，可选立即签出。
    pub fn create_branch(
        &self,
        name: String,
        start_point: Option<String>,
        checkout: bool,
    ) -> std::result::Result<(), CoreError> {
        self.ensure_valid_branch_name(&name)?;
        let start = start_point.as_deref();
        if checkout {
            let mut args = vec!["switch", "-c", name.as_str(), "--end-of-options"];
            args.extend(start);
            self.git.run(&self.root, args).map_err(map_overwrite)?;
        } else {
            let mut args = vec!["branch", "--end-of-options", name.as_str()];
            args.extend(start);
            self.git.run(&self.root, args)?;
        }
        Ok(())
    }

    pub fn rename_branch(
        &self,
        old_name: String,
        new_name: String,
    ) -> std::result::Result<(), CoreError> {
        self.ensure_valid_branch_name(&new_name)?;
        self.git.run(
            &self.root,
            [
                "branch",
                "-m",
                "--end-of-options",
                old_name.as_str(),
                new_name.as_str(),
            ],
        )?;
        Ok(())
    }

    /// 删除本地分支。未完全合并且 `force` 为 false 时返回 [`CoreError::BranchNotFullyMerged`]。
    pub fn delete_branch(&self, name: String, force: bool) -> std::result::Result<(), CoreError> {
        let flag = if force { "-D" } else { "-d" };
        self.git
            .run(
                &self.root,
                ["branch", flag, "--end-of-options", name.as_str()],
            )
            .map_err(|err| match err {
                CoreError::CommandFailed { ref stderr, .. }
                    if stderr.contains("not fully merged") =>
                {
                    CoreError::BranchNotFullyMerged { name: name.clone() }
                }
                other => other,
            })?;
        Ok(())
    }

    /// 把 `branch` 合并到当前分支。
    pub fn merge_branch(&self, branch: String) -> std::result::Result<MergeOutcome, CoreError> {
        match self.git.run(
            &self.root,
            ["merge", "--no-edit", "--end-of-options", branch.as_str()],
        ) {
            Ok(out) => {
                let text = String::from_utf8_lossy(&out.stdout);
                Ok(if text.contains("Already up to date") {
                    MergeOutcome::UpToDate
                } else if text.contains("Fast-forward") {
                    MergeOutcome::FastForward
                } else {
                    MergeOutcome::Merged
                })
            }
            Err(_) if self.state() == RepositoryState::Merging => Ok(MergeOutcome::Conflicts),
            Err(err) => Err(map_overwrite(err)),
        }
    }

    /// 把当前分支变基到 `upstream` 上。
    pub fn rebase_onto(&self, upstream: String) -> std::result::Result<MergeOutcome, CoreError> {
        let result = self.git.run(
            &self.root,
            ["rebase", "--end-of-options", upstream.as_str()],
        );
        self.rebase_result(result)
    }

    /// 解决冲突后继续变基（不打开编辑器，沿用原提交信息）。
    pub fn continue_rebase(&self) -> std::result::Result<MergeOutcome, CoreError> {
        let result = self.git.run(
            &self.root,
            ["-c", "core.editor=true", "rebase", "--continue"],
        );
        self.rebase_result(result)
    }

    pub fn abort_rebase(&self) -> std::result::Result<(), CoreError> {
        self.git.run(&self.root, ["rebase", "--abort"])?;
        Ok(())
    }

    pub fn abort_merge(&self) -> std::result::Result<(), CoreError> {
        self.git.run(&self.root, ["merge", "--abort"])?;
        Ok(())
    }
}

impl Repository {
    fn ensure_valid_branch_name(&self, name: &str) -> Result<()> {
        if self.is_valid_branch_name(name.to_owned()) {
            Ok(())
        } else {
            Err(CoreError::InvalidBranchName {
                name: name.to_owned(),
            })
        }
    }

    pub(crate) fn local_branch_exists(&self, name: &str) -> bool {
        let reference = format!("refs/heads/{name}");
        self.git
            .run(
                &self.root,
                ["show-ref", "--verify", "--quiet", reference.as_str()],
            )
            .is_ok()
    }

    /// 执行 `git switch`，按 `mode` 处理会被覆盖的本地改动。
    fn switch(
        &self,
        options: &[&str],
        targets: &[&str],
        mode: CheckoutMode,
    ) -> Result<CheckoutOutcome> {
        let run = |force: bool| {
            let mut args = vec!["switch"];
            if force {
                args.push("--discard-changes");
            }
            args.extend(options);
            args.push("--end-of-options");
            args.extend(targets);
            self.git.run(&self.root, args).map_err(map_overwrite)
        };
        match run(mode == CheckoutMode::Force) {
            Ok(_) => Ok(CheckoutOutcome::default()),
            Err(CoreError::LocalChangesWouldBeOverwritten { .. })
                if mode == CheckoutMode::Smart =>
            {
                let stash_conflicts =
                    self.with_stash("smart checkout", || run(false).map(|_| ()))?;
                Ok(CheckoutOutcome { stash_conflicts })
            }
            Err(err) => Err(err),
        }
    }

    /// 暂存本地改动（含未跟踪文件）后执行 `operation`，完成后恢复。
    /// 返回恢复时是否发生冲突（冲突时改动仍保留在 stash 中）；`operation` 失败时立即恢复并返回错误。
    pub(crate) fn with_stash(
        &self,
        purpose: &str,
        operation: impl FnOnce() -> Result<()>,
    ) -> Result<bool> {
        let message = format!("GitDeck: {purpose}");
        // `stash -u` 依赖路径魔法清理未跟踪文件，不能启用 --literal-pathspecs。
        self.git.run_with_pathspec_magic(
            &self.root,
            [
                "stash",
                "push",
                "--include-untracked",
                "-m",
                message.as_str(),
            ],
        )?;
        if let Err(err) = operation() {
            let _ = self
                .git
                .run_with_pathspec_magic(&self.root, ["stash", "pop"]);
            return Err(err);
        }
        Ok(self
            .git
            .run_with_pathspec_magic(&self.root, ["stash", "pop"])
            .is_err())
    }

    fn rebase_result(&self, result: Result<crate::git::runner::GitOutput>) -> Result<MergeOutcome> {
        match result {
            Ok(out) => {
                let text = format!("{}{}", String::from_utf8_lossy(&out.stdout), out.stderr);
                Ok(if text.contains("is up to date") {
                    MergeOutcome::UpToDate
                } else if text.contains("Fast-forwarded") {
                    MergeOutcome::FastForward
                } else {
                    MergeOutcome::Merged
                })
            }
            Err(_) if self.state() == RepositoryState::Rebasing => Ok(MergeOutcome::Conflicts),
            Err(err) => Err(map_overwrite(err)),
        }
    }
}

/// 把 “本地改动会被覆盖” 的失败识别为专门的错误，并提取文件列表。
pub(crate) fn map_overwrite(err: CoreError) -> CoreError {
    match err {
        CoreError::CommandFailed { ref stderr, .. }
            if stderr.contains("would be overwritten by") =>
        {
            let files = stderr
                .lines()
                .filter(|l| l.starts_with('\t'))
                .map(|l| l.trim().to_owned())
                .collect();
            CoreError::LocalChangesWouldBeOverwritten { files }
        }
        other => other,
    }
}
