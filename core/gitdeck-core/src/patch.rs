//! 补丁（对应 IDEA 的 Create Patch / Apply Patch）。

use crate::error::CoreError;
use crate::git::status::{ChangeKind, FileChange};
use crate::repo::Repository;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PatchFile {
    pub path: String,
    pub added: u32,
    pub deleted: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct PatchOutcome {
    /// 使用三方合并应用，留下了冲突需要解决。
    pub conflicts: bool,
}

#[uniffi::export]
impl Repository {
    /// 本地改动相对 HEAD 的补丁；`paths` 为空时包含全部改动。未跟踪的文件以新增文件的形式包含。
    pub fn create_patch(&self, paths: Vec<String>) -> std::result::Result<String, CoreError> {
        self.local_diff(&paths, true)
    }

    /// 若干提交的补丁（邮件格式，可用 `git am` 或 Apply Patch 应用）；`hashes` 按从旧到新排列。
    pub fn create_patch_from_commits(
        &self,
        hashes: Vec<String>,
    ) -> std::result::Result<String, CoreError> {
        let mut patch = String::new();
        for hash in &hashes {
            if hash.is_empty() || hash.starts_with('-') {
                return Err(CoreError::Parse {
                    detail: format!("invalid revision: {hash:?}"),
                });
            }
            let out = self.git.run(
                &self.root,
                ["format-patch", "-1", "--stdout", "--binary", hash.as_str()],
            )?;
            patch.push_str(&String::from_utf8_lossy(&out.stdout));
        }
        Ok(patch)
    }

    /// 补丁涉及的文件与增删行数。
    pub fn patch_files(&self, patch: String) -> std::result::Result<Vec<PatchFile>, CoreError> {
        let out =
            self.git
                .run_with_input(&self.root, ["apply", "--numstat", "-"], patch.as_bytes())?;
        Ok(String::from_utf8_lossy(&out.stdout)
            .lines()
            .filter_map(|line| {
                let mut cols = line.splitn(3, '\t');
                let added = cols.next()?.parse().unwrap_or(0);
                let deleted = cols.next()?.parse().unwrap_or(0);
                Some(PatchFile {
                    path: cols.next()?.to_owned(),
                    added,
                    deleted,
                })
            })
            .collect())
    }

    /// 补丁能否直接应用到当前工作区。
    pub fn can_apply_patch(&self, patch: String) -> bool {
        self.git
            .run_with_input(&self.root, ["apply", "--check", "-"], patch.as_bytes())
            .is_ok()
    }

    /// 应用补丁；不能直接应用且 `three_way` 为 true 时改用三方合并，冲突留给用户解决。
    pub fn apply_patch(
        &self,
        patch: String,
        three_way: bool,
    ) -> std::result::Result<PatchOutcome, CoreError> {
        match self
            .git
            .run_with_input(&self.root, ["apply", "-"], patch.as_bytes())
        {
            Ok(_) => Ok(PatchOutcome { conflicts: false }),
            Err(err) if !three_way => Err(err),
            Err(_) => match self.git.run_with_input(
                &self.root,
                ["apply", "--3way", "-"],
                patch.as_bytes(),
            ) {
                Ok(_) => Ok(PatchOutcome { conflicts: false }),
                Err(err) => {
                    let conflicts = self.status()?.changes.iter().any(|c| c.conflict.is_some());
                    if conflicts {
                        Ok(PatchOutcome { conflicts: true })
                    } else {
                        Err(err)
                    }
                }
            },
        }
    }
}

impl Repository {
    /// 本地改动相对 HEAD 的 diff；`binary` 为 false 时二进制文件只显示 “Binary files differ”。
    pub(crate) fn local_diff(
        &self,
        paths: &[String],
        binary: bool,
    ) -> crate::error::Result<String> {
        let status = self.status()?;
        let selected: Vec<_> = status
            .changes
            .iter()
            .filter(|c| c.unstaged != ChangeKind::Ignored && c.conflict.is_none())
            .filter(|c| paths.is_empty() || paths.contains(&c.path))
            .collect();
        let has_head = self.has_head();
        // 空仓库没有 HEAD：所有文件都按新增文件生成补丁。
        let (untracked, tracked): (Vec<&FileChange>, Vec<&FileChange>) = selected
            .into_iter()
            .partition(|c| c.unstaged == ChangeKind::Untracked || !has_head);

        let mut patch = String::new();
        if !tracked.is_empty() {
            let mut args: Vec<String> = vec!["diff".into()];
            if binary {
                args.push("--binary".into());
            }
            args.extend(["HEAD".into(), "--".into()]);
            for change in &tracked {
                args.push(change.path.clone());
                if let Some(orig) = &change.orig_path {
                    args.push(orig.clone());
                }
            }
            let out = self.git.run(&self.root, &args)?;
            patch.push_str(&String::from_utf8_lossy(&out.stdout));
        }
        for change in untracked {
            // `diff --no-index` 有差异时退出码为 1。
            let mut args = vec!["diff", "--no-index"];
            if binary {
                args.push("--binary");
            }
            args.extend(["--", "/dev/null", change.path.as_str()]);
            let out = self.git.run_with_exit_codes(&self.root, args, &[1])?;
            patch.push_str(&String::from_utf8_lossy(&out.stdout));
        }
        Ok(patch)
    }
}

/// 拆分为前言与按文件的 diff 段（每段以 `diff --git` / `diff --cc` 开头）。
pub(crate) fn split_sections(text: &str) -> (&str, Vec<&str>) {
    let mut starts: Vec<usize> = Vec::new();
    let mut offset = 0;
    for line in text.split_inclusive('\n') {
        if line.starts_with("diff --git ") || line.starts_with("diff --cc ") {
            starts.push(offset);
        }
        offset += line.len();
    }
    let Some(&first) = starts.first() else {
        return (text, Vec::new());
    };
    let mut sections = Vec::with_capacity(starts.len());
    for (i, &start) in starts.iter().enumerate() {
        let end = starts.get(i + 1).copied().unwrap_or(text.len());
        sections.push(&text[start..end]);
    }
    (&text[..first], sections)
}

/// diff 段对应的文件路径（新版本路径；删除的文件为旧路径）。
pub(crate) fn section_path(section: &str) -> String {
    let unquote = |p: &str| p.trim().trim_matches('"').to_owned();
    let mut old = None;
    for line in section.lines().take(16) {
        if line.starts_with("@@") {
            break;
        }
        if let Some(p) = line.strip_prefix("+++ ") {
            let p = unquote(p);
            if p != "/dev/null" {
                return p.strip_prefix("b/").unwrap_or(&p).to_owned();
            }
        } else if let Some(p) = line.strip_prefix("--- ") {
            let p = unquote(p);
            if p != "/dev/null" {
                old = Some(p.strip_prefix("a/").unwrap_or(&p).to_owned());
            }
        } else if let Some(p) = line.strip_prefix("rename to ") {
            return unquote(p);
        }
    }
    if let Some(old) = old {
        return old;
    }
    // 没有内容差异的段（模式变更、二进制文件）：从 `diff --git a/X b/X` 中取路径。
    let header = section.lines().next().unwrap_or_default();
    let rest = header
        .strip_prefix("diff --git ")
        .or_else(|| header.strip_prefix("diff --cc "))
        .unwrap_or_default()
        .trim_matches('"');
    if rest.len() > 5 && rest.starts_with("a/") && (rest.len() - 5).is_multiple_of(2) {
        let n = (rest.len() - 5) / 2;
        if rest.is_char_boundary(2 + n) {
            return rest[2..2 + n].to_owned();
        }
    }
    rest.strip_prefix("b/").unwrap_or(rest).to_owned()
}
