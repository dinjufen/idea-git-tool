//! 远程、工作树与子模块管理（对应 IDEA 的 Manage Remotes、Worktrees 标签与子模块支持）。

use crate::error::{CoreError, Result};
use crate::repo::Repository;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Worktree {
    pub path: String,
    /// HEAD 指向的提交；新建但尚无提交的仓库为 `None`。
    pub head: Option<String>,
    /// 检出的分支短名；分离 HEAD 时为 `None`。
    pub branch: Option<String>,
    /// 主工作树（仓库本身）。
    pub is_main: bool,
    /// 当前打开的就是这个工作树。
    pub is_current: bool,
    pub locked: bool,
    /// 目录已不存在，可以清理。
    pub prunable: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SubmoduleState {
    /// 已初始化且检出的提交与记录一致。
    UpToDate,
    /// 检出的提交与父仓库记录的不同。
    Modified,
    Uninitialized,
    /// 子模块存在合并冲突。
    Conflict,
}

/// 项目目录中发现的其他 git 仓库（IDEA 的 “Unregistered VCS roots”）。
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct NestedRepository {
    /// 工作区根目录的绝对路径。
    pub path: String,
    /// 相对本仓库根目录的路径。
    pub relative_path: String,
    /// 是本仓库的子模块（否则为独立的嵌套仓库）。
    pub is_submodule: bool,
}

/// 查找嵌套仓库时跳过的目录（依赖、构建产物等，通常很大且不含需要管理的仓库）。
const SKIPPED_DIRECTORIES: &[&str] = &[
    "node_modules",
    "target",
    "build",
    "dist",
    "out",
    "Pods",
    "DerivedData",
    ".build",
    "vendor",
    "venv",
    ".venv",
];

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Submodule {
    pub name: String,
    pub path: String,
    pub url: Option<String>,
    /// 当前检出（未初始化时为父仓库记录）的提交。
    pub head: String,
    pub state: SubmoduleState,
}

#[uniffi::export]
impl Repository {
    // MARK: 远程

    pub fn add_remote(&self, name: String, url: String) -> std::result::Result<(), CoreError> {
        ensure_plain(&name, "remote name")?;
        ensure_plain(&url, "remote url")?;
        self.git
            .run(&self.root, ["remote", "add", name.as_str(), url.as_str()])?;
        Ok(())
    }

    pub fn remove_remote(&self, name: String) -> std::result::Result<(), CoreError> {
        ensure_plain(&name, "remote name")?;
        self.git
            .run(&self.root, ["remote", "remove", name.as_str()])?;
        Ok(())
    }

    pub fn rename_remote(
        &self,
        old_name: String,
        new_name: String,
    ) -> std::result::Result<(), CoreError> {
        ensure_plain(&old_name, "remote name")?;
        ensure_plain(&new_name, "remote name")?;
        self.git.run(
            &self.root,
            ["remote", "rename", old_name.as_str(), new_name.as_str()],
        )?;
        Ok(())
    }

    pub fn set_remote_url(&self, name: String, url: String) -> std::result::Result<(), CoreError> {
        ensure_plain(&name, "remote name")?;
        ensure_plain(&url, "remote url")?;
        self.git.run(
            &self.root,
            ["remote", "set-url", name.as_str(), url.as_str()],
        )?;
        Ok(())
    }

    // MARK: 工作树

    pub fn worktrees(&self) -> std::result::Result<Vec<Worktree>, CoreError> {
        let out = self
            .git
            .run(&self.root, ["worktree", "list", "--porcelain"])?;
        let current = std::fs::canonicalize(&self.root).unwrap_or_else(|_| self.root.clone());
        let mut worktrees = parse_worktrees(&String::from_utf8_lossy(&out.stdout));
        for worktree in &mut worktrees {
            let path = std::fs::canonicalize(&worktree.path)
                .unwrap_or_else(|_| worktree.path.clone().into());
            worktree.is_current = path == current;
        }
        Ok(worktrees)
    }

    /// 在 `path` 新建工作树：`new_branch` 非空时从 `start_point`（默认 HEAD）创建新分支，
    /// 否则检出已有的 `branch`（两者都为空时以分离 HEAD 检出 `start_point`）。
    pub fn add_worktree(
        &self,
        path: String,
        branch: Option<String>,
        new_branch: Option<String>,
        start_point: Option<String>,
    ) -> std::result::Result<(), CoreError> {
        ensure_plain(&path, "worktree path")?;
        let mut args: Vec<String> = vec!["worktree".into(), "add".into()];
        if let Some(new_branch) = new_branch.filter(|b| !b.is_empty()) {
            if !self.is_valid_branch_name(new_branch.clone()) {
                return Err(CoreError::InvalidBranchName { name: new_branch });
            }
            args.extend(["-b".into(), new_branch, path]);
            args.extend(start_point);
        } else if let Some(branch) = branch.filter(|b| !b.is_empty()) {
            ensure_plain(&branch, "branch")?;
            args.extend([path, branch]);
        } else {
            args.push("--detach".into());
            args.push(path);
            args.extend(start_point);
        }
        self.git.run(&self.root, &args)?;
        Ok(())
    }

    pub fn remove_worktree(&self, path: String, force: bool) -> std::result::Result<(), CoreError> {
        ensure_plain(&path, "worktree path")?;
        let mut args = vec!["worktree", "remove"];
        if force {
            args.push("--force");
        }
        args.push(path.as_str());
        self.git.run(&self.root, args)?;
        Ok(())
    }

    pub fn prune_worktrees(&self) -> std::result::Result<(), CoreError> {
        self.git.run(&self.root, ["worktree", "prune"])?;
        Ok(())
    }

    // MARK: 子模块

    pub fn submodules(&self) -> std::result::Result<Vec<Submodule>, CoreError> {
        if !self.root.join(".gitmodules").exists() {
            return Ok(Vec::new());
        }
        // `.gitmodules` 中的名称 → 路径与 URL。
        let config = self
            .git
            .run(
                &self.root,
                [
                    "config",
                    "-f",
                    ".gitmodules",
                    "--get-regexp",
                    r"^submodule\..*\.(path|url)$",
                ],
            )
            .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
            .unwrap_or_default();
        let mut declared: Vec<(String, Option<String>, Option<String>)> = Vec::new();
        for line in config.lines() {
            let Some((key, value)) = line.split_once(' ') else {
                continue;
            };
            let Some(rest) = key.strip_prefix("submodule.") else {
                continue;
            };
            let (name, field) = match rest.rsplit_once('.') {
                Some(pair) => pair,
                None => continue,
            };
            let index = match declared.iter().position(|(n, _, _)| n == name) {
                Some(i) => i,
                None => {
                    declared.push((name.to_owned(), None, None));
                    declared.len() - 1
                }
            };
            match field {
                "path" => declared[index].1 = Some(value.to_owned()),
                "url" => declared[index].2 = Some(value.to_owned()),
                _ => {}
            }
        }

        let status = self.git.run(&self.root, ["submodule", "status"])?;
        let text = String::from_utf8_lossy(&status.stdout);
        let mut submodules = Vec::new();
        for line in text.lines().filter(|l| l.len() > 41) {
            let state = match line.as_bytes()[0] {
                b'-' => SubmoduleState::Uninitialized,
                b'+' => SubmoduleState::Modified,
                b'U' => SubmoduleState::Conflict,
                _ => SubmoduleState::UpToDate,
            };
            let rest = &line[1..];
            let (head, rest) = rest.split_once(' ').unwrap_or((rest, ""));
            // 行尾可能带 ` (describe)`。
            let path = rest
                .rsplit_once(" (")
                .map(|(p, _)| p)
                .unwrap_or(rest)
                .to_owned();
            let entry = declared
                .iter()
                .find(|(_, p, _)| p.as_deref() == Some(path.as_str()));
            submodules.push(Submodule {
                name: entry
                    .map(|(n, _, _)| n.clone())
                    .unwrap_or_else(|| path.clone()),
                url: entry.and_then(|(_, _, u)| u.clone()),
                path,
                head: head.to_owned(),
                state,
            });
        }
        Ok(submodules)
    }

    /// 查找项目目录中的其他 git 仓库：已初始化的子模块与独立的嵌套仓库（最多 `max_depth` 层，
    /// 不进入找到的仓库内部，跳过隐藏目录与依赖 / 构建目录）。
    pub fn nested_repositories(
        &self,
        max_depth: u32,
    ) -> std::result::Result<Vec<NestedRepository>, CoreError> {
        let submodules: Vec<String> = self
            .submodules()
            .unwrap_or_default()
            .into_iter()
            .map(|s| s.path)
            .collect();
        let mut found = Vec::new();
        let mut queue: Vec<(std::path::PathBuf, u32)> = vec![(self.root.clone(), 0)];
        while let Some((dir, depth)) = queue.pop() {
            if depth >= max_depth {
                continue;
            }
            let Ok(entries) = std::fs::read_dir(&dir) else {
                continue;
            };
            let mut children: Vec<std::path::PathBuf> = entries
                .filter_map(|e| e.ok())
                .filter(|e| e.file_type().map(|t| t.is_dir()).unwrap_or(false))
                .map(|e| e.path())
                .filter(|p| {
                    let name = p
                        .file_name()
                        .map(|n| n.to_string_lossy().into_owned())
                        .unwrap_or_default();
                    !name.starts_with('.') && !SKIPPED_DIRECTORIES.contains(&name.as_str())
                })
                .collect();
            children.sort();
            for child in children {
                if child.join(".git").exists() {
                    let relative = child
                        .strip_prefix(&self.root)
                        .map(|p| p.to_string_lossy().replace('\\', "/"))
                        .unwrap_or_default();
                    found.push(NestedRepository {
                        path: child.to_string_lossy().into_owned(),
                        is_submodule: submodules.contains(&relative),
                        relative_path: relative,
                    });
                } else {
                    queue.push((child, depth + 1));
                }
            }
        }
        found.sort_by(|a, b| a.relative_path.cmp(&b.relative_path));
        Ok(found)
    }

    /// 初始化并更新子模块（`git submodule update --init`），`recursive` 时包括嵌套子模块。
    pub fn update_submodules(
        &self,
        paths: Vec<String>,
        recursive: bool,
    ) -> std::result::Result<(), CoreError> {
        let mut args: Vec<String> = vec!["submodule".into(), "update".into(), "--init".into()];
        if recursive {
            args.push("--recursive".into());
        }
        if !paths.is_empty() {
            args.push("--".into());
            args.extend(paths);
        }
        self.git
            .run(&self.root, &args)
            .map_err(CoreError::classify_remote)?;
        Ok(())
    }
}

/// 拒绝以 `-` 开头或为空的参数，避免被 git 当作选项。
fn ensure_plain(value: &str, what: &str) -> Result<()> {
    if value.is_empty() || value.starts_with('-') {
        Err(CoreError::Parse {
            detail: format!("invalid {what}: {value:?}"),
        })
    } else {
        Ok(())
    }
}

fn parse_worktrees(text: &str) -> Vec<Worktree> {
    let mut worktrees = Vec::new();
    for (index, block) in text
        .split("\n\n")
        .filter(|b| !b.trim().is_empty())
        .enumerate()
    {
        let mut worktree = Worktree {
            path: String::new(),
            head: None,
            branch: None,
            is_main: index == 0,
            is_current: false,
            locked: false,
            prunable: false,
        };
        for line in block.lines() {
            let (key, value) = line.split_once(' ').unwrap_or((line, ""));
            match key {
                "worktree" => worktree.path = value.to_owned(),
                "HEAD" => {
                    worktree.head = Some(value.to_owned()).filter(|h| h.bytes().any(|b| b != b'0'))
                }
                "branch" => {
                    worktree.branch = Some(value.trim_start_matches("refs/heads/").to_owned())
                }
                "locked" => worktree.locked = true,
                "prunable" => worktree.prunable = true,
                _ => {}
            }
        }
        if !worktree.path.is_empty() {
            worktrees.push(worktree);
        }
    }
    worktrees
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_worktree_porcelain() {
        let text = "worktree /repo\nHEAD aaaa\nbranch refs/heads/main\n\n\
                    worktree /repo-feature\nHEAD bbbb\nbranch refs/heads/feature/x\nlocked\n\n\
                    worktree /gone\nHEAD cccc\ndetached\nprunable gitdir file points to non-existent location\n";
        let list = parse_worktrees(text);
        assert_eq!(list.len(), 3);
        assert!(list[0].is_main);
        assert_eq!(list[1].branch.as_deref(), Some("feature/x"));
        assert!(list[1].locked);
        assert_eq!(list[2].branch, None);
        assert!(list[2].prunable);
    }
}
