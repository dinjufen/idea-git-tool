//! 改写历史的提交级操作（对应 IDEA Log 右键菜单）：Cherry-pick、Revert、Reset、Undo Commit、
//! Edit Commit Message、Drop Commits 与 Interactively Rebase from Here。

use std::path::{Path, PathBuf};

use crate::branch_ops::{MergeOutcome, map_overwrite};
use crate::error::{CoreError, Result};
use crate::git::runner::GitOutput;
use crate::git::status::RepositoryState;
use crate::repo::Repository;

/// IDEA “Reset Current Branch to Here” 的四种模式。
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ResetMode {
    /// 只移动分支指针，改动保留在暂存区。
    Soft,
    /// 移动分支并重置暂存区，改动保留在工作区。
    Mixed,
    /// 丢弃所有改动。
    Hard,
    /// 保留与目标之间无冲突的本地改动，有冲突时拒绝。
    Keep,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum RebaseAction {
    Pick,
    /// 改写提交信息（需提供 `message`）。
    Reword,
    /// 停在该提交，等待修改后继续。
    Edit,
    /// 并入上一个提交；`message` 为合并后的提交信息，未提供时沿用 git 拼接的信息。
    Squash,
    /// 并入上一个提交并丢弃本提交的信息。
    Fixup,
    Drop,
}

/// 交互式变基计划中的一步，按从旧到新的顺序排列。
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RebaseStep {
    pub hash: String,
    pub action: RebaseAction,
    pub message: Option<String>,
}

/// 交互式变基对话框中列出的提交。
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RebaseCommit {
    pub hash: String,
    pub subject: String,
    /// 完整提交信息。
    pub message: String,
    pub author_name: String,
    pub author_time: i64,
}

#[uniffi::export]
impl Repository {
    /// 拣选提交到当前分支；`hashes` 按应用顺序（从旧到新）排列。
    pub fn cherry_pick(&self, hashes: Vec<String>) -> std::result::Result<MergeOutcome, CoreError> {
        validate_hashes(&hashes)?;
        let mut args = vec!["cherry-pick".to_owned()];
        args.extend(hashes);
        let result = self.git.run(&self.root, &args);
        self.sequencer_result(result, RepositoryState::CherryPicking)
    }

    pub fn continue_cherry_pick(&self) -> std::result::Result<MergeOutcome, CoreError> {
        let result = self.git.run(
            &self.root,
            ["-c", "core.editor=true", "cherry-pick", "--continue"],
        );
        self.sequencer_result(result, RepositoryState::CherryPicking)
    }

    pub fn abort_cherry_pick(&self) -> std::result::Result<(), CoreError> {
        self.git.run(&self.root, ["cherry-pick", "--abort"])?;
        Ok(())
    }

    /// 还原提交（生成反向提交）；`hashes` 按还原顺序（通常从新到旧）排列。
    pub fn revert_commits(
        &self,
        hashes: Vec<String>,
    ) -> std::result::Result<MergeOutcome, CoreError> {
        validate_hashes(&hashes)?;
        let mut args = vec!["revert".to_owned(), "--no-edit".to_owned()];
        args.extend(hashes);
        let result = self.git.run(&self.root, &args);
        self.sequencer_result(result, RepositoryState::Reverting)
    }

    pub fn continue_revert(&self) -> std::result::Result<MergeOutcome, CoreError> {
        let result = self.git.run(
            &self.root,
            ["-c", "core.editor=true", "revert", "--continue"],
        );
        self.sequencer_result(result, RepositoryState::Reverting)
    }

    pub fn abort_revert(&self) -> std::result::Result<(), CoreError> {
        self.git.run(&self.root, ["revert", "--abort"])?;
        Ok(())
    }

    /// 把当前分支重置到 `revision`。
    pub fn reset_to(
        &self,
        revision: String,
        mode: ResetMode,
    ) -> std::result::Result<(), CoreError> {
        validate_hashes(std::slice::from_ref(&revision))?;
        let flag = match mode {
            ResetMode::Soft => "--soft",
            ResetMode::Mixed => "--mixed",
            ResetMode::Hard => "--hard",
            ResetMode::Keep => "--keep",
        };
        self.git
            .run(&self.root, ["reset", flag, revision.as_str()])
            .map_err(map_overwrite)?;
        Ok(())
    }

    /// 撤销最近一次提交，改动回到暂存区（IDEA 的 Undo Commit，仅适用于 HEAD）。
    pub fn undo_last_commit(&self) -> std::result::Result<(), CoreError> {
        if self.has_parent("HEAD") {
            self.git.run(&self.root, ["reset", "--soft", "HEAD~1"])?;
        } else {
            // 根提交没有父提交：删除分支引用，保留索引与工作区。
            self.git.run(&self.root, ["update-ref", "-d", "HEAD"])?;
        }
        Ok(())
    }

    /// 修改提交信息：HEAD 直接 amend（不影响暂存区），更早的提交通过交互式变基改写。
    pub fn edit_commit_message(
        &self,
        hash: String,
        message: String,
    ) -> std::result::Result<MergeOutcome, CoreError> {
        if message.trim().is_empty() {
            return Err(CoreError::EmptyCommitMessage);
        }
        validate_hashes(std::slice::from_ref(&hash))?;
        if self.resolve(&hash)? == self.resolve("HEAD")? {
            self.git.run_with_input(
                &self.root,
                ["commit", "--amend", "--only", "--allow-empty", "-F", "-"],
                message.as_bytes(),
            )?;
            return Ok(MergeOutcome::Merged);
        }
        let target = self.resolve(&hash)?;
        let steps = self
            .rebase_commits(target.clone())?
            .into_iter()
            .map(|c| {
                let reword = c.hash == target;
                RebaseStep {
                    action: if reword {
                        RebaseAction::Reword
                    } else {
                        RebaseAction::Pick
                    },
                    message: reword.then(|| message.clone()),
                    hash: c.hash,
                }
            })
            .collect();
        self.interactive_rebase(target, steps)
    }

    /// 删除若干提交（IDEA 的 Drop Commits），通过交互式变基实现。
    pub fn drop_commits(
        &self,
        hashes: Vec<String>,
    ) -> std::result::Result<MergeOutcome, CoreError> {
        validate_hashes(&hashes)?;
        let dropped: Vec<String> = hashes
            .iter()
            .map(|h| self.resolve(h))
            .collect::<Result<_>>()?;
        // 从最早被删除的提交开始变基。
        let commits = self.rebase_commits(self.oldest_of(&dropped)?)?;
        let from = commits.first().map(|c| c.hash.clone()).unwrap_or_default();
        let steps = commits
            .into_iter()
            .map(|c| RebaseStep {
                action: if dropped.contains(&c.hash) {
                    RebaseAction::Drop
                } else {
                    RebaseAction::Pick
                },
                message: None,
                hash: c.hash,
            })
            .collect();
        self.interactive_rebase(from, steps)
    }

    /// 交互式变基的候选提交：从 `from`（含）到 HEAD，按从旧到新排列。
    pub fn rebase_commits(
        &self,
        from: String,
    ) -> std::result::Result<Vec<RebaseCommit>, CoreError> {
        validate_hashes(std::slice::from_ref(&from))?;
        let range = self.rebase_range(&from)?;
        let merges = self.git.run(
            &self.root,
            ["rev-list", "--merges", "--count", range.as_str()],
        )?;
        if String::from_utf8_lossy(&merges.stdout).trim() != "0" {
            return Err(CoreError::RebaseWithMerges);
        }
        let out = self.git.run(
            &self.root,
            [
                "log",
                "--reverse",
                "--format=%H%x1f%s%x1f%an%x1f%at%x1f%B%x1e",
                range.as_str(),
            ],
        )?;
        Ok(String::from_utf8_lossy(&out.stdout)
            .split('\x1e')
            .map(|r| r.trim_start_matches('\n'))
            .filter(|r| !r.is_empty())
            .filter_map(|r| {
                let f: Vec<&str> = r.splitn(5, '\x1f').collect();
                let [hash, subject, author, time, body] = f[..] else {
                    return None;
                };
                Some(RebaseCommit {
                    hash: hash.to_owned(),
                    subject: subject.to_owned(),
                    message: body.trim_end().to_owned(),
                    author_name: author.to_owned(),
                    author_time: time.parse().unwrap_or(0),
                })
            })
            .collect())
    }

    /// 按 `steps` 执行交互式变基，`from` 为计划中最早的提交。工作区有改动时自动储藏并在完成后恢复。
    pub fn interactive_rebase(
        &self,
        from: String,
        steps: Vec<RebaseStep>,
    ) -> std::result::Result<MergeOutcome, CoreError> {
        validate_hashes(std::slice::from_ref(&from))?;
        validate_hashes(&steps.iter().map(|s| s.hash.clone()).collect::<Vec<_>>())?;
        let work = self.rebase_work_dir()?;
        let todo = self.build_todo(&steps, &work)?;
        let todo_path = work.join("git-rebase-todo");
        std::fs::write(&todo_path, todo)?;

        let mut args = vec!["rebase", "-i", "--autostash"];
        let base = format!("{from}^");
        if self.has_parent(&from) {
            args.push(base.as_str());
        } else {
            args.push("--root");
        }
        // git 会以 `$GIT_SEQUENCE_EDITOR <todo 文件>` 调用编辑器：用我们准备好的计划覆盖它。
        let sequence_editor = format!("cp {}", shell_quote(&todo_path));
        let env = [
            ("GIT_SEQUENCE_EDITOR", sequence_editor),
            ("GIT_EDITOR", "true".to_owned()),
        ];
        let result = self.git.run_with_env(&self.root, args, &env);
        self.rebase_outcome(result)
    }

    /// `ancestor` 是否为 `descendant` 的祖先（或同一提交）；用于判断提交是否在当前分支上。
    pub fn is_ancestor(&self, ancestor: String, descendant: String) -> bool {
        validate_hashes(&[ancestor.clone(), descendant.clone()]).is_ok()
            && self
                .git
                .run(
                    &self.root,
                    [
                        "merge-base",
                        "--is-ancestor",
                        ancestor.as_str(),
                        descendant.as_str(),
                    ],
                )
                .is_ok()
    }

    /// 提交是否已存在于任一远程分支（改写前需要提醒用户）。
    pub fn is_pushed(&self, hash: String) -> std::result::Result<bool, CoreError> {
        validate_hashes(std::slice::from_ref(&hash))?;
        let contains = format!("--contains={hash}");
        let out = self.git.run(
            &self.root,
            [
                "for-each-ref",
                contains.as_str(),
                "--count=1",
                "--format=%(refname)",
                "refs/remotes",
            ],
        )?;
        Ok(!out.stdout.is_empty())
    }
}

impl Repository {
    fn resolve(&self, revision: &str) -> Result<String> {
        let spec = format!("{revision}^{{commit}}");
        let out = self.git.run(
            &self.root,
            ["rev-parse", "--verify", "--quiet", spec.as_str()],
        )?;
        Ok(String::from_utf8_lossy(&out.stdout).trim().to_owned())
    }

    fn has_parent(&self, revision: &str) -> bool {
        let parent = format!("{revision}^");
        self.git
            .run(
                &self.root,
                ["rev-parse", "--verify", "--quiet", parent.as_str()],
            )
            .is_ok()
    }

    /// `from` 及其之后到 HEAD 的提交范围。
    fn rebase_range(&self, from: &str) -> Result<String> {
        if self.has_parent(from) {
            Ok(format!("{from}^..HEAD"))
        } else {
            Ok("HEAD".to_owned())
        }
    }

    /// 若干提交中在历史上最早的一个（按 HEAD 方向的拓扑顺序）。
    fn oldest_of(&self, hashes: &[String]) -> Result<String> {
        let out = self.git.run(
            &self.root,
            ["rev-list", "--reverse", "--topo-order", "HEAD"],
        )?;
        String::from_utf8_lossy(&out.stdout)
            .lines()
            .find(|h| hashes.iter().any(|x| x == h))
            .map(str::to_owned)
            .ok_or_else(|| CoreError::InvalidRebasePlan {
                detail: "commits are not on the current branch".to_owned(),
            })
    }

    /// 变基计划所用的临时文件目录（位于 git 目录内，变基暂停期间 exec 步骤仍可读取）。
    fn rebase_work_dir(&self) -> Result<PathBuf> {
        let dir = self.git_dir.join("gitdeck-rebase");
        if dir.exists() && self.state() != RepositoryState::Rebasing {
            let _ = std::fs::remove_dir_all(&dir);
        }
        std::fs::create_dir_all(&dir)?;
        Ok(dir)
    }

    /// 生成 git-rebase-todo。改写信息不用编辑器，而是在对应步骤后插入 `exec git commit --amend -F <文件>`。
    fn build_todo(&self, steps: &[RebaseStep], work: &Path) -> Result<String> {
        let git = shell_quote(self.git.path());
        let mut todo = String::new();
        for (index, step) in steps.iter().enumerate() {
            let keyword = match step.action {
                RebaseAction::Pick | RebaseAction::Reword => "pick",
                RebaseAction::Edit => "edit",
                RebaseAction::Drop => "drop",
                RebaseAction::Fixup => "fixup",
                // 有新信息时用 fixup + amend 设置合并后的信息，否则交给 git 拼接。
                RebaseAction::Squash if step.message.is_some() => "fixup",
                RebaseAction::Squash => "squash",
            };
            if index == 0 && matches!(step.action, RebaseAction::Squash | RebaseAction::Fixup) {
                return Err(CoreError::InvalidRebasePlan {
                    detail: "the first commit cannot be squashed or fixed up".to_owned(),
                });
            }
            todo.push_str(&format!("{keyword} {}\n", step.hash));
            let rewrites = matches!(step.action, RebaseAction::Reword | RebaseAction::Squash);
            if let (true, Some(message)) = (rewrites, &step.message) {
                if message.trim().is_empty() {
                    return Err(CoreError::EmptyCommitMessage);
                }
                let file = work.join(format!("message-{index}.txt"));
                std::fs::write(&file, message)?;
                todo.push_str(&format!(
                    "exec {git} commit --amend --only --allow-empty -F {}\n",
                    shell_quote(&file)
                ));
            }
        }
        Ok(todo)
    }

    fn rebase_outcome(&self, result: Result<GitOutput>) -> Result<MergeOutcome> {
        if self.state() == RepositoryState::Rebasing {
            let conflicts = self.status()?.changes.iter().any(|c| c.conflict.is_some());
            return Ok(if conflicts {
                MergeOutcome::Conflicts
            } else {
                MergeOutcome::Paused
            });
        }
        result.map(|_| MergeOutcome::Merged).map_err(map_overwrite)
    }

    /// cherry-pick / revert 的结果：进行中状态表示遇到冲突。
    fn sequencer_result(
        &self,
        result: Result<GitOutput>,
        in_progress: RepositoryState,
    ) -> Result<MergeOutcome> {
        match result {
            Ok(_) => Ok(MergeOutcome::Merged),
            Err(_) if self.state() == in_progress => Ok(MergeOutcome::Conflicts),
            Err(err) => Err(map_overwrite(err)),
        }
    }
}

/// 只接受提交哈希或 `HEAD` 一类不以 `-` 开头的修订，避免被当作命令行选项。
fn validate_hashes(hashes: &[String]) -> Result<()> {
    match hashes
        .iter()
        .find(|h| h.is_empty() || h.starts_with('-') || h.contains(char::is_whitespace))
    {
        Some(bad) => Err(CoreError::Parse {
            detail: format!("invalid revision: {bad:?}"),
        }),
        None => Ok(()),
    }
}

/// 为 POSIX shell（git 用 sh 执行编辑器与 exec 步骤，Windows 上为 Git for Windows 自带的 sh）加单引号。
fn shell_quote(path: &Path) -> String {
    let text = path.to_string_lossy().replace('\\', "/");
    format!("'{}'", text.replace('\'', r"'\''"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quotes_paths_for_shell() {
        assert_eq!(shell_quote(Path::new("/tmp/a b/c")), "'/tmp/a b/c'");
        assert_eq!(shell_quote(Path::new("/tmp/it's")), r"'/tmp/it'\''s'");
    }

    #[test]
    fn rejects_option_like_revisions() {
        assert!(validate_hashes(&["--hard".into()]).is_err());
        assert!(validate_hashes(&["a b".into()]).is_err());
        assert!(validate_hashes(&["abc123".into(), "HEAD~1".into()]).is_ok());
    }
}
