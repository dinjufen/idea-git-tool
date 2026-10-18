//! 本地改动的回滚（IDEA 的 Rollback）与和指定修订的比较（Show Diff with Working Tree）。

use crate::error::CoreError;
use crate::git::log::{self, ChangedFile};
use crate::git::status::ChangeKind;
use crate::repo::Repository;

#[uniffi::export]
impl Repository {
    /// 把选中文件恢复到 HEAD 的状态（工作区与暂存区）。
    ///
    /// 新增的文件（HEAD 中没有）会从暂存区移除；`delete_added` 为 true 时同时删除工作区中的文件，
    /// 否则保留为未跟踪文件。重命名的文件同时恢复原路径。未跟踪的文件不受影响。
    pub fn rollback(
        &self,
        paths: Vec<String>,
        delete_added: bool,
    ) -> std::result::Result<(), CoreError> {
        let status = self.status()?;
        let selected: Vec<_> = status
            .changes
            .iter()
            .filter(|c| {
                paths.contains(&c.path)
                    && c.unstaged != ChangeKind::Untracked
                    && c.unstaged != ChangeKind::Ignored
            })
            .collect();
        if selected.is_empty() {
            return Ok(());
        }
        let has_head = self.has_head();
        let mut restore: Vec<String> = Vec::new();
        let mut added: Vec<String> = Vec::new();
        for change in &selected {
            let is_new = !has_head
                || matches!(
                    change.staged,
                    ChangeKind::Added | ChangeKind::Renamed | ChangeKind::Copied
                );
            if is_new {
                added.push(change.path.clone());
            } else {
                restore.push(change.path.clone());
            }
            // 重命名 / 复制的原文件在 HEAD 中存在：恢复它。
            if let Some(orig) = &change.orig_path
                && change.staged == ChangeKind::Renamed
                && !restore.contains(orig)
            {
                restore.push(orig.clone());
            }
        }
        if !restore.is_empty() {
            let mut args: Vec<String> = vec![
                "restore".into(),
                "--source=HEAD".into(),
                "--staged".into(),
                "--worktree".into(),
                "--".into(),
            ];
            args.extend(restore);
            self.git.run(&self.root, &args)?;
        }
        if !added.is_empty() {
            // 空仓库没有 HEAD，`restore --staged` 不可用。
            let mut args: Vec<String> = if has_head {
                vec!["restore".into(), "--staged".into(), "--".into()]
            } else {
                vec![
                    "rm".into(),
                    "--cached".into(),
                    "-r".into(),
                    "-q".into(),
                    "--".into(),
                ]
            };
            args.extend(added.iter().cloned());
            self.git.run(&self.root, &args)?;
            if delete_added {
                for path in &added {
                    let full = self.root.join(path);
                    if full.is_file() || full.is_symlink() {
                        std::fs::remove_file(full)?;
                    }
                }
            }
        }
        Ok(())
    }

    /// 已跟踪文件中与 `revision` 不同的文件（工作区相对该修订的改动）。
    pub fn diff_with_working_tree(
        &self,
        revision: String,
    ) -> std::result::Result<Vec<ChangedFile>, CoreError> {
        if revision.is_empty() || revision.starts_with('-') {
            return Err(CoreError::Parse {
                detail: format!("invalid revision: {revision:?}"),
            });
        }
        let out = self.git.run(
            &self.root,
            ["diff", "--name-status", "-z", "-M", revision.as_str(), "--"],
        )?;
        log::parse_name_status(&out.stdout)
    }
}
