//! 远程操作：Fetch、Update Project（拉取并合并 / 变基）、Push（对应 IDEA 的同名操作）。

use crate::branch_ops::MergeOutcome;
use crate::error::{CoreError, Result};
use crate::git::status::ChangeKind;
use crate::repo::Repository;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Remote {
    pub name: String,
    pub url: String,
}

/// Update Project 的更新方式（IDEA 的 Merge / Rebase）。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, uniffi::Enum)]
pub enum UpdateMethod {
    #[default]
    Merge,
    Rebase,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct UpdateResult {
    pub outcome: MergeOutcome,
    /// 从上游收到的提交数。
    pub received: u32,
    /// 更新前暂存的本地改动在恢复时发生冲突（改动仍在 stash 中）。
    pub stash_conflicts: bool,
    /// 合并 / 变基出现冲突，本地改动保留在 stash 中，解决冲突后需手动恢复。
    pub stash_kept: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct OutgoingCommit {
    pub hash: String,
    pub subject: String,
    pub author_name: String,
    pub author_time: i64,
}

/// Push 对话框需要的信息：当前分支推送到哪里、有哪些待推送的提交。
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PushTarget {
    pub local_branch: String,
    /// 目标远程；仓库没有任何远程时为 `None`。
    pub remote: Option<String>,
    pub remote_branch: String,
    /// 当前分支已设置上游。
    pub has_upstream: bool,
    pub commits: Vec<OutgoingCommit>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PushOptions {
    pub local_branch: String,
    pub remote: String,
    pub remote_branch: String,
    /// 强制推送（使用 `--force-with-lease`，远程被他人更新过时仍会拒绝）。
    pub force: bool,
    /// 同时推送可达的附注标签（`--follow-tags`）。
    pub push_tags: bool,
    /// 推送后把远程分支设为上游（`-u`）。
    pub set_upstream: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct PushResult {
    pub pushed_commits: u32,
    pub up_to_date: bool,
}

/// 待推送提交列表的上限，避免首次推送大仓库时列表过长。
const MAX_OUTGOING: usize = 1000;

#[uniffi::export]
impl Repository {
    pub fn remotes(&self) -> std::result::Result<Vec<Remote>, CoreError> {
        // 没有任何远程时 `git config --get-regexp` 以退出码 1 结束，视为空列表。
        let Ok(out) = self
            .git
            .run(&self.root, ["config", "--get-regexp", r"^remote\..*\.url$"])
        else {
            return Ok(Vec::new());
        };
        Ok(String::from_utf8_lossy(&out.stdout)
            .lines()
            .filter_map(|line| {
                let (key, url) = line.split_once(' ')?;
                let name = key.strip_prefix("remote.")?.strip_suffix(".url")?;
                Some(Remote {
                    name: name.to_owned(),
                    url: url.to_owned(),
                })
            })
            .collect())
    }

    /// 获取所有远程的更新，返回更新的引用数。
    pub fn fetch(&self, prune: bool) -> std::result::Result<u32, CoreError> {
        let mut args = vec!["fetch", "--all", "--no-recurse-submodules"];
        if prune {
            args.push("--prune");
        }
        let out = self
            .git
            .run(&self.root, args)
            .map_err(CoreError::classify_remote)?;
        Ok(out.stderr.lines().filter(|l| l.contains(" -> ")).count() as u32)
    }

    /// 更新当前分支：拉取上游后合并或变基。工作区有改动时先暂存，完成后恢复（IDEA 的 Smart Update）。
    pub fn update_project(
        &self,
        method: UpdateMethod,
    ) -> std::result::Result<UpdateResult, CoreError> {
        let branch = self.current_branch().ok_or(CoreError::DetachedHead)?;
        let remote = self.config(&format!("branch.{branch}.remote"));
        let has_upstream = self
            .git
            .run(
                &self.root,
                ["rev-parse", "--verify", "--quiet", "@{upstream}"],
            )
            .is_ok();
        let Some(remote) = remote.filter(|_| has_upstream) else {
            return Err(CoreError::NoUpstream { branch });
        };
        self.git
            .run(
                &self.root,
                [
                    "fetch",
                    "--no-recurse-submodules",
                    "--end-of-options",
                    remote.as_str(),
                ],
            )
            .map_err(CoreError::classify_remote)?;

        let received = self.count_commits("HEAD..@{upstream}")?;
        if received == 0 {
            return Ok(UpdateResult {
                outcome: MergeOutcome::UpToDate,
                received,
                stash_conflicts: false,
                stash_kept: false,
            });
        }

        let dirty = self.has_tracked_changes()?;
        if dirty {
            self.git.run_with_pathspec_magic(
                &self.root,
                ["stash", "push", "-m", "GitDeck: update project"],
            )?;
        }
        let result = match method {
            UpdateMethod::Merge => self.merge_branch("@{upstream}".into()),
            UpdateMethod::Rebase => self.rebase_onto("@{upstream}".into()),
        };
        let outcome = match result {
            Ok(outcome) => outcome,
            Err(err) => {
                if dirty {
                    let _ = self
                        .git
                        .run_with_pathspec_magic(&self.root, ["stash", "pop"]);
                }
                return Err(err);
            }
        };
        if outcome == MergeOutcome::Conflicts {
            return Ok(UpdateResult {
                outcome,
                received,
                stash_conflicts: false,
                stash_kept: dirty,
            });
        }
        let stash_conflicts = dirty
            && self
                .git
                .run_with_pathspec_magic(&self.root, ["stash", "pop"])
                .is_err();
        Ok(UpdateResult {
            outcome,
            received,
            stash_conflicts,
            stash_kept: false,
        })
    }

    /// 当前分支的推送目标与待推送提交。
    pub fn push_target(&self) -> std::result::Result<PushTarget, CoreError> {
        let branch = self.current_branch().ok_or(CoreError::DetachedHead)?;
        self.push_target_for(branch)
    }

    /// 某个本地分支的推送目标与待推送提交（IDEA 分支菜单中可以推送非当前分支）。
    pub fn push_target_for(&self, branch: String) -> std::result::Result<PushTarget, CoreError> {
        if branch.starts_with('-') {
            return Err(CoreError::Parse {
                detail: format!("invalid branch: {branch:?}"),
            });
        }
        let upstream_spec = format!("{branch}@{{upstream}}");
        let upstream_remote = self.config(&format!("branch.{branch}.remote"));
        let upstream_merge = self.config(&format!("branch.{branch}.merge"));
        let has_upstream = upstream_remote.is_some()
            && self
                .git
                .run(
                    &self.root,
                    ["rev-parse", "--verify", "--quiet", upstream_spec.as_str()],
                )
                .is_ok();

        let (remote, remote_branch) = if has_upstream {
            let merge = upstream_merge.unwrap_or_default();
            let name = merge
                .strip_prefix("refs/heads/")
                .unwrap_or(&merge)
                .to_owned();
            (upstream_remote, name)
        } else {
            // 没有上游：与 IDEA 一致，默认推送到 origin（没有则第一个远程）的同名分支。
            let remotes = self.remotes()?;
            let remote = remotes
                .iter()
                .find(|r| r.name == "origin")
                .or(remotes.first())
                .map(|r| r.name.clone());
            (remote, branch.clone())
        };

        let commits = match &remote {
            Some(remote) => self.outgoing_commits(&branch, remote, &remote_branch)?,
            None => Vec::new(),
        };
        Ok(PushTarget {
            local_branch: branch,
            remote,
            remote_branch,
            has_upstream,
            commits,
        })
    }

    pub fn push(&self, options: PushOptions) -> std::result::Result<PushResult, CoreError> {
        if options.remote.starts_with('-') {
            return Err(CoreError::Parse {
                detail: format!("invalid remote: {:?}", options.remote),
            });
        }
        let pushed = self.outgoing_commits(
            &options.local_branch,
            &options.remote,
            &options.remote_branch,
        )?;
        let refspec = format!(
            "refs/heads/{}:refs/heads/{}",
            options.local_branch, options.remote_branch
        );
        let mut args = vec!["push"];
        if options.force {
            args.push("--force-with-lease");
        }
        if options.push_tags {
            args.push("--follow-tags");
        }
        if options.set_upstream {
            args.push("--set-upstream");
        }
        args.extend([
            "--end-of-options",
            options.remote.as_str(),
            refspec.as_str(),
        ]);

        match self.git.run(&self.root, args) {
            Ok(out) => Ok(PushResult {
                pushed_commits: pushed.len() as u32,
                up_to_date: out.stderr.contains("Everything up-to-date"),
            }),
            Err(CoreError::CommandFailed { stderr, .. })
                if stderr.contains("[rejected]") || stderr.contains("[remote rejected]") =>
            {
                Err(CoreError::PushRejected {
                    reason: rejection_reason(&stderr),
                })
            }
            Err(err) => Err(err.classify_remote()),
        }
    }
}

impl Repository {
    pub(crate) fn current_branch(&self) -> Option<String> {
        let out = self
            .git
            .run(&self.root, ["symbolic-ref", "--quiet", "--short", "HEAD"])
            .ok()?;
        Some(String::from_utf8_lossy(&out.stdout).trim().to_owned())
    }

    pub(crate) fn config(&self, key: &str) -> Option<String> {
        let out = self.git.run(&self.root, ["config", "--get", key]).ok()?;
        let value = String::from_utf8_lossy(&out.stdout).trim().to_owned();
        (!value.is_empty()).then_some(value)
    }

    fn count_commits(&self, range: &str) -> Result<u32> {
        let out = self.git.run(&self.root, ["rev-list", "--count", range])?;
        String::from_utf8_lossy(&out.stdout)
            .trim()
            .parse()
            .map_err(|_| CoreError::Parse {
                detail: format!("unexpected rev-list count for {range}"),
            })
    }

    fn has_tracked_changes(&self) -> Result<bool> {
        Ok(self
            .status()?
            .changes
            .iter()
            .any(|c| c.unstaged != ChangeKind::Untracked && c.unstaged != ChangeKind::Ignored))
    }

    /// `local_branch` 上尚未推送到 `remote/remote_branch` 的提交。
    /// 远程分支不存在时，取不在该远程任何分支上的提交。
    fn outgoing_commits(
        &self,
        local_branch: &str,
        remote: &str,
        remote_branch: &str,
    ) -> Result<Vec<OutgoingCommit>> {
        let local = format!("refs/heads/{local_branch}");
        let tracking = format!("refs/remotes/{remote}/{remote_branch}");
        let tracking_exists = self
            .git
            .run(
                &self.root,
                ["show-ref", "--verify", "--quiet", tracking.as_str()],
            )
            .is_ok();
        let max = format!("--max-count={MAX_OUTGOING}");
        let exclude = format!("--remotes={remote}");
        let mut args = vec!["log", max.as_str(), "--format=%H%x1f%s%x1f%an%x1f%at%x1e"];
        if tracking_exists {
            args.extend([local.as_str(), "--not", tracking.as_str()]);
        } else {
            args.extend([local.as_str(), "--not", exclude.as_str()]);
        }
        let out = self.git.run(&self.root, args)?;
        Ok(String::from_utf8_lossy(&out.stdout)
            .split('\x1e')
            .map(|r| r.trim_start_matches('\n'))
            .filter(|r| !r.is_empty())
            .filter_map(|r| {
                let f: Vec<&str> = r.splitn(4, '\x1f').collect();
                let [hash, subject, author, time] = f[..] else {
                    return None;
                };
                Some(OutgoingCommit {
                    hash: hash.to_owned(),
                    subject: subject.to_owned(),
                    author_name: author.to_owned(),
                    author_time: time.parse().unwrap_or(0),
                })
            })
            .collect())
    }
}

/// 从 `git push` 的输出中提取拒绝原因，例如 `fetch first`、`non-fast-forward`、`stale info`。
fn rejection_reason(stderr: &str) -> String {
    stderr
        .lines()
        .find(|l| l.contains("[rejected]") || l.contains("[remote rejected]"))
        .and_then(|l| {
            let start = l.rfind('(')?;
            let end = l.rfind(')')?;
            (start < end).then(|| l[start + 1..end].to_owned())
        })
        .unwrap_or_else(|| stderr.trim().to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_rejection_reason() {
        let stderr = "To ../origin\n ! [rejected]        main -> main (fetch first)\nerror: failed to push some refs to '../origin'\n";
        assert_eq!(rejection_reason(stderr), "fetch first");
        let stderr = " ! [rejected]        main -> main (stale info)\n";
        assert_eq!(rejection_reason(stderr), "stale info");
    }
}
