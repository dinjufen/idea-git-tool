//! Stash（对应 IDEA 的 Stash Changes / Unstash Changes 与提交工具窗口中的 Stash 标签）。

use crate::branch_ops::map_overwrite;
use crate::error::CoreError;
use crate::git::log::{ChangedFile, parse_name_status};
use crate::git::status::ChangeKind;
use crate::repo::Repository;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct StashEntry {
    /// `stash@{index}` 中的下标；删除或新建后会变化，操作后应重新读取列表。
    pub index: u32,
    pub hash: String,
    /// 储藏时填写的消息；未填写时为 git 生成的 “WIP on …” 中的提交标题。
    pub message: String,
    /// 储藏时所在的分支；分离 HEAD 时为 `None`。
    pub branch: Option<String>,
    pub time: i64,
    /// 储藏中包含未跟踪文件。
    pub has_untracked: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct StashOptions {
    pub message: Option<String>,
    /// 只储藏这些路径；为空时储藏全部改动。
    pub paths: Vec<String>,
    pub include_untracked: bool,
    /// 储藏后保留暂存区中的改动（`--keep-index`）。
    pub keep_index: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct UnstashOutcome {
    /// 应用时出现冲突；`pop` 时储藏不会被删除。
    pub conflicts: bool,
}

#[uniffi::export]
impl Repository {
    pub fn stashes(&self) -> std::result::Result<Vec<StashEntry>, CoreError> {
        let out = self.git.run(
            &self.root,
            [
                "stash",
                "list",
                "--format=%gd%x1f%H%x1f%P%x1f%gs%x1f%ct%x1e",
            ],
        )?;
        let text = String::from_utf8_lossy(&out.stdout);
        let mut entries = Vec::new();
        for record in text
            .split('\x1e')
            .map(|r| r.trim_start_matches('\n'))
            .filter(|r| !r.is_empty())
        {
            let f: Vec<&str> = record.splitn(5, '\x1f').collect();
            let [reference, hash, parents, subject, time] = f[..] else {
                return Err(parse_error(record));
            };
            let index = reference
                .strip_prefix("stash@{")
                .and_then(|r| r.strip_suffix('}'))
                .and_then(|n| n.parse().ok())
                .ok_or_else(|| parse_error(reference))?;
            let (branch, message) = parse_subject(subject);
            entries.push(StashEntry {
                index,
                hash: hash.to_owned(),
                message,
                branch,
                time: time.trim().parse().unwrap_or(0),
                // 含未跟踪文件的储藏提交有第三个父提交。
                has_untracked: parents.split_whitespace().count() >= 3,
            });
        }
        Ok(entries)
    }

    /// 储藏改动；没有可储藏的改动时返回 false。
    pub fn stash_changes(&self, options: StashOptions) -> std::result::Result<bool, CoreError> {
        let mut args: Vec<String> = vec!["stash".into(), "push".into()];
        if let Some(message) = options.message.filter(|m| !m.trim().is_empty()) {
            args.push("-m".into());
            args.push(message);
        }
        if options.include_untracked {
            args.push("--include-untracked".into());
        }
        if options.keep_index {
            args.push("--keep-index".into());
        }
        if !options.paths.is_empty() {
            args.push("--".into());
            args.extend(options.paths.iter().map(|p| format!(":(literal){p}")));
        }
        // `stash -u` 内部用 `:/` 清理未跟踪文件，启用 --literal-pathspecs 时会失效，因此不使用它。
        let out = self.git.run_with_pathspec_magic(&self.root, &args)?;
        Ok(!String::from_utf8_lossy(&out.stdout).contains("No local changes to save"))
    }

    /// 储藏中改动的文件：已跟踪文件相对储藏时的 HEAD，未跟踪文件记为新增。
    pub fn stash_files(&self, index: u32) -> std::result::Result<Vec<ChangedFile>, CoreError> {
        let stash = stash_ref(index);
        let base = format!("{stash}^1");
        let out = self.git.run(
            &self.root,
            [
                "diff-tree",
                "-r",
                "-z",
                "-M",
                "--name-status",
                "--no-commit-id",
                base.as_str(),
                stash.as_str(),
            ],
        )?;
        let mut files = parse_name_status(&out.stdout)?;
        let untracked = format!("{stash}^3");
        if self
            .git
            .run(
                &self.root,
                ["rev-parse", "--verify", "--quiet", untracked.as_str()],
            )
            .is_ok()
        {
            let out = self.git.run(
                &self.root,
                ["ls-tree", "-r", "-z", "--name-only", untracked.as_str()],
            )?;
            files.extend(
                String::from_utf8_lossy(&out.stdout)
                    .split('\0')
                    .filter(|p| !p.is_empty())
                    .map(|p| ChangedFile {
                        path: p.to_owned(),
                        orig_path: None,
                        kind: ChangeKind::Untracked,
                    }),
            );
        }
        Ok(files)
    }

    /// 应用储藏；`pop` 成功后删除该储藏，`reinstate_index` 同时恢复暂存区状态（`--index`）。
    pub fn apply_stash(
        &self,
        index: u32,
        pop: bool,
        reinstate_index: bool,
    ) -> std::result::Result<UnstashOutcome, CoreError> {
        let stash = stash_ref(index);
        let mut args = vec!["stash", if pop { "pop" } else { "apply" }];
        if reinstate_index {
            args.push("--index");
        }
        args.push(stash.as_str());
        match self.git.run_with_pathspec_magic(&self.root, args) {
            Ok(_) => Ok(UnstashOutcome { conflicts: false }),
            Err(err) => {
                let conflicts = self.status()?.changes.iter().any(|c| c.conflict.is_some());
                if conflicts {
                    Ok(UnstashOutcome { conflicts: true })
                } else {
                    Err(map_overwrite(err))
                }
            }
        }
    }

    pub fn drop_stash(&self, index: u32) -> std::result::Result<(), CoreError> {
        let stash = stash_ref(index);
        self.git
            .run(&self.root, ["stash", "drop", stash.as_str()])?;
        Ok(())
    }

    pub fn clear_stashes(&self) -> std::result::Result<(), CoreError> {
        self.git.run(&self.root, ["stash", "clear"])?;
        Ok(())
    }

    /// 从储藏时的提交新建分支并在其上应用储藏，成功后删除储藏（IDEA 的 “Unstash as new branch”）。
    pub fn stash_to_branch(
        &self,
        index: u32,
        branch: String,
    ) -> std::result::Result<(), CoreError> {
        if !self.is_valid_branch_name(branch.clone()) {
            return Err(CoreError::InvalidBranchName { name: branch });
        }
        let stash = stash_ref(index);
        self.git
            .run_with_pathspec_magic(
                &self.root,
                ["stash", "branch", branch.as_str(), stash.as_str()],
            )
            .map_err(map_overwrite)?;
        Ok(())
    }
}

fn stash_ref(index: u32) -> String {
    format!("stash@{{{index}}}")
}

/// 解析 reflog 标题：`WIP on main: abc123 subject` 或 `On main: message`。
fn parse_subject(subject: &str) -> (Option<String>, String) {
    let rest = subject
        .strip_prefix("WIP on ")
        .or_else(|| subject.strip_prefix("On "));
    let Some(rest) = rest else {
        return (None, subject.to_owned());
    };
    let Some((branch, message)) = rest.split_once(": ") else {
        return (None, subject.to_owned());
    };
    let branch = (branch != "(no branch)").then(|| branch.to_owned());
    let message = if subject.starts_with("WIP on ") {
        // 去掉开头的短哈希，只保留提交标题。
        message.split_once(' ').map(|(_, s)| s).unwrap_or(message)
    } else {
        message
    };
    (branch, message.to_owned())
}

fn parse_error(context: &str) -> CoreError {
    CoreError::Parse {
        detail: format!("unexpected stash output: {context:?}"),
    }
}

/// 读取储藏中某个文件的两侧内容所用的修订：已跟踪文件为 `stash^1` 与 `stash`，未跟踪文件只有 `stash^3`。
#[uniffi::export]
pub fn stash_revisions(index: u32, untracked: bool) -> StashRevisions {
    let stash = stash_ref(index);
    if untracked {
        StashRevisions {
            base: None,
            changed: format!("{stash}^3"),
        }
    } else {
        StashRevisions {
            base: Some(format!("{stash}^1")),
            changed: stash,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct StashRevisions {
    pub base: Option<String>,
    pub changed: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_stash_subjects() {
        assert_eq!(
            parse_subject("WIP on main: 1a2b3c4 Fix login"),
            (Some("main".into()), "Fix login".into())
        );
        assert_eq!(
            parse_subject("On feature/x: half done"),
            (Some("feature/x".into()), "half done".into())
        );
        assert_eq!(
            parse_subject("On (no branch): detached work"),
            (None, "detached work".into())
        );
        assert_eq!(
            parse_subject("something else"),
            (None, "something else".into())
        );
    }

    #[test]
    fn revisions_for_tracked_and_untracked_files() {
        assert_eq!(
            stash_revisions(2, false),
            StashRevisions {
                base: Some("stash@{2}^1".into()),
                changed: "stash@{2}".into()
            }
        );
        assert_eq!(stash_revisions(0, true).base, None);
        assert_eq!(stash_revisions(0, true).changed, "stash@{0}^3");
    }
}
