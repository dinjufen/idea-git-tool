//! 提交（对应 IDEA Commit 工具窗口）。
//!
//! 与 IDEA 一致，提交以“勾选的文件”为准，而不是暂存区：只提交勾选文件在工作区的内容，
//! 其他已暂存的改动保持原样留在暂存区。实现上使用 `git commit --only -- <paths>`。

use std::collections::HashSet;

use crate::error::CoreError;
use crate::git::status::RepositoryState;
use crate::repo::Repository;

#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct CommitOptions {
    pub message: String,
    /// 勾选的文件（相对仓库根目录）。重命名只需给出新路径，原路径会自动带上。
    pub paths: Vec<String>,
    pub amend: bool,
    /// 追加 `Signed-off-by`。
    pub sign_off: bool,
    /// 跳过 pre-commit / commit-msg 钩子（IDEA 的 “Run Git hooks” 取消勾选）。
    pub skip_hooks: bool,
    /// 覆盖作者，格式为 `Name <email>`。
    pub author: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CommitResult {
    pub hash: String,
    pub subject: String,
    /// 本次提交包含的勾选文件数，用于 “N files committed” 通知。
    pub file_count: u32,
}

#[uniffi::export]
impl Repository {
    pub fn commit(&self, options: CommitOptions) -> std::result::Result<CommitResult, CoreError> {
        if options.message.trim().is_empty() {
            return Err(CoreError::EmptyCommitMessage);
        }
        if options.paths.is_empty() && !options.amend {
            return Err(CoreError::NothingToCommit);
        }

        let status = self.status()?;
        let selected: HashSet<&str> = options.paths.iter().map(String::as_str).collect();
        let mut pathspecs = Vec::new();
        let mut untracked = Vec::new();
        for change in status
            .changes
            .iter()
            .filter(|c| selected.contains(c.path.as_str()))
        {
            if change.conflict.is_none() && change.unstaged == crate::ChangeKind::Untracked {
                untracked.push(change.path.clone());
            }
            pathspecs.push(change.path.clone());
            if let Some(orig) = &change.orig_path {
                pathspecs.push(orig.clone());
            }
        }
        if pathspecs.is_empty() && !options.amend {
            return Err(CoreError::NothingToCommit);
        }

        // 未跟踪文件需要先加入索引，`--only` 才能识别它们。
        if !untracked.is_empty() {
            self.git.run(
                &self.root,
                ["add", "--"].into_iter().map(String::from).chain(untracked),
            )?;
        }

        let mut args: Vec<String> = vec!["commit".into(), "-F".into(), "-".into()];
        if options.amend {
            args.push("--amend".into());
        }
        if options.sign_off {
            args.push("--signoff".into());
        }
        if options.skip_hooks {
            args.push("--no-verify".into());
        }
        if let Some(author) = &options.author {
            args.push(format!("--author={author}"));
        }

        if status.state == RepositoryState::Merging {
            // git 不允许在合并过程中做部分提交：先暂存勾选文件，再提交整个索引（IDEA 同样如此）。
            if !pathspecs.is_empty() {
                self.git.run(
                    &self.root,
                    ["add", "-A", "--"]
                        .into_iter()
                        .map(String::from)
                        .chain(pathspecs.iter().cloned()),
                )?;
            }
        } else {
            // 不带路径的 `--only --amend` 只修改提交信息。
            args.push("--only".into());
            if !pathspecs.is_empty() {
                args.push("--".into());
                args.extend(pathspecs.iter().cloned());
            }
        }
        self.git
            .run_with_input(&self.root, &args, options.message.as_bytes())?;

        let out = self
            .git
            .run(&self.root, ["log", "-1", "--format=%H%x1f%s"])?;
        let text = String::from_utf8_lossy(&out.stdout);
        let (hash, subject) =
            text.trim_end()
                .split_once('\x1f')
                .ok_or_else(|| CoreError::Parse {
                    detail: format!("unexpected log output: {text:?}"),
                })?;
        Ok(CommitResult {
            hash: hash.to_owned(),
            subject: subject.to_owned(),
            file_count: options.paths.len() as u32,
        })
    }

    /// 最近一次提交的完整提交信息；勾选 Amend 时用于填充提交信息框。空仓库返回 `None`。
    pub fn last_commit_message(&self) -> std::result::Result<Option<String>, CoreError> {
        if !self.has_head() {
            return Ok(None);
        }
        let out = self.git.run(&self.root, ["log", "-1", "--format=%B"])?;
        Ok(Some(
            String::from_utf8_lossy(&out.stdout).trim_end().to_owned(),
        ))
    }
}
