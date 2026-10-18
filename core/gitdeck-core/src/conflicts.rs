//! 冲突解决：三方合并分块、读取冲突文件的各方版本、接受一方或写入合并结果。
//!
//! 对应 IDEA 的 Conflicts 对话框与三栏合并工具（Merge Revisions）。

use crate::diff::{Lines, WhitespaceMode, line_blocks};
use crate::error::{CoreError, Result};
use crate::git::status::RepositoryState;
use crate::repo::Repository;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum MergeChunkKind {
    /// 只有 “我们” 一方修改。
    Ours,
    /// 只有 “他们” 一方修改。
    Theirs,
    /// 双方做了完全相同的修改。
    Both,
    /// 双方在重叠位置做了不同的修改。
    Conflict,
}

/// 三方合并中的一个变更块；各方行号从 0 开始，范围为 `[start, start + count)`。
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct MergeChunk {
    pub kind: MergeChunkKind,
    pub base_start: u32,
    pub base_count: u32,
    pub ours_start: u32,
    pub ours_count: u32,
    pub theirs_start: u32,
    pub theirs_count: u32,
}

/// 计算三方合并的变更块（按基准版本的行号排序）。
///
/// 与 IDEA 一致，只有修改区域真正重叠（或在同一位置插入）才算冲突；相邻但不重叠的修改各自独立。
#[uniffi::export]
pub fn merge_chunks(base: String, ours: String, theirs: String) -> Vec<MergeChunk> {
    let base_lines = Lines::new(&base);
    let ours_lines = Lines::new(&ours);
    let theirs_lines = Lines::new(&theirs);
    let a = line_blocks(&base_lines, &ours_lines, WhitespaceMode::Compare);
    let b = line_blocks(&base_lines, &theirs_lines, WhitespaceMode::Compare);

    // 双指针按基准起点合并两侧的变更，把重叠的归为一组。
    let (mut i, mut j) = (0, 0);
    // 已处理变更带来的行数偏移（新文本行号 = 基准行号 + 偏移）。
    let (mut delta_a, mut delta_b) = (0i64, 0i64);
    let mut chunks = Vec::new();
    while i < a.len() || j < b.len() {
        let mut group = Group::default();
        if j >= b.len() || (i < a.len() && a[i].base_start <= b[j].base_start) {
            group.add(&a[i], true);
            i += 1;
        } else {
            group.add(&b[j], false);
            j += 1;
        }
        loop {
            if i < a.len() && group.overlaps(&a[i]) {
                group.add(&a[i], true);
                i += 1;
            } else if j < b.len() && group.overlaps(&b[j]) {
                group.add(&b[j], false);
                j += 1;
            } else {
                break;
            }
        }

        let span = (group.end - group.start) as i64;
        let ours_start = (group.start as i64 + delta_a) as u32;
        let ours_count = (span + group.delta_a) as u32;
        let theirs_start = (group.start as i64 + delta_b) as u32;
        let theirs_count = (span + group.delta_b) as u32;
        let kind = match (group.has_a, group.has_b) {
            (true, false) => MergeChunkKind::Ours,
            (false, true) => MergeChunkKind::Theirs,
            _ => {
                let o = &ours_lines.lines[ours_start as usize..(ours_start + ours_count) as usize];
                let t = &theirs_lines.lines
                    [theirs_start as usize..(theirs_start + theirs_count) as usize];
                if o == t {
                    MergeChunkKind::Both
                } else {
                    MergeChunkKind::Conflict
                }
            }
        };
        chunks.push(MergeChunk {
            kind,
            base_start: group.start,
            base_count: group.end - group.start,
            ours_start,
            ours_count,
            theirs_start,
            theirs_count,
        });
        delta_a += group.delta_a;
        delta_b += group.delta_b;
    }
    chunks
}

/// 正在归并的一组相互重叠的变更（基准行号区间 `[start, end)`）。
#[derive(Default)]
struct Group {
    start: u32,
    end: u32,
    has_a: bool,
    has_b: bool,
    /// 组内变更对 “我们” / “他们” 行数的影响。
    delta_a: i64,
    delta_b: i64,
}

impl Group {
    fn add(&mut self, change: &crate::diff::LineChange, ours: bool) {
        let (s, e) = (change.base_start, change.base_start + change.base_count);
        if !self.has_a && !self.has_b {
            (self.start, self.end) = (s, e);
        } else {
            self.start = self.start.min(s);
            self.end = self.end.max(e);
        }
        let delta = change.count as i64 - change.base_count as i64;
        if ours {
            self.has_a = true;
            self.delta_a += delta;
        } else {
            self.has_b = true;
            self.delta_b += delta;
        }
    }

    /// 变更是否与本组重叠。纯插入只在落到对方修改范围内部、或与对方在同一位置插入时才算重叠；
    /// 紧挨着的修改（例如一方改第 1 行、另一方改第 2 行）互不冲突，与 IDEA 一致。
    fn overlaps(&self, change: &crate::diff::LineChange) -> bool {
        let (s, c) = (change.base_start, change.base_count);
        match (c == 0, self.start == self.end) {
            (false, false) => s < self.end && self.start < s + c,
            (true, false) => self.start < s && s < self.end,
            (false, true) => s < self.start && self.start < s + c,
            (true, true) => s == self.start,
        }
    }
}

/// 冲突文件在各方的内容；某一方不存在（被删除）时为 `None`。
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ConflictVersions {
    pub base: Option<String>,
    pub ours: Option<String>,
    pub theirs: Option<String>,
}

/// 合并工具两侧的标题：当前进行的操作中 “我们” 与 “他们” 分别指什么。
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ConflictLabels {
    pub ours: String,
    pub theirs: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ConflictSide {
    Ours,
    Theirs,
}

#[uniffi::export]
impl Repository {
    /// 读取冲突文件在索引中的三个阶段：1 = 共同祖先，2 = 我们，3 = 他们。
    pub fn conflict_versions(
        &self,
        path: String,
    ) -> std::result::Result<ConflictVersions, CoreError> {
        Ok(ConflictVersions {
            base: self.stage_content(1, &path)?,
            ours: self.stage_content(2, &path)?,
            theirs: self.stage_content(3, &path)?,
        })
    }

    /// 合并时 “我们” 是当前分支、“他们” 是被合并的分支；变基时相反：
    /// “我们” 是目标分支（onto），“他们” 是正在重放的本地提交。
    pub fn conflict_labels(&self) -> ConflictLabels {
        let head = self.current_branch().unwrap_or_else(|| "HEAD".to_owned());
        match self.state() {
            RepositoryState::Rebasing => {
                let onto = self
                    .read_git_file("rebase-merge/onto")
                    .or_else(|| self.read_git_file("rebase-apply/onto"));
                let branch = self
                    .read_git_file("rebase-merge/head-name")
                    .or_else(|| self.read_git_file("rebase-apply/head-name"))
                    .map(|n| n.trim_start_matches("refs/heads/").to_owned());
                ConflictLabels {
                    ours: onto
                        .map(|o| self.describe(&o))
                        .unwrap_or_else(|| "onto".to_owned()),
                    theirs: branch.unwrap_or(head),
                }
            }
            RepositoryState::Merging => ConflictLabels {
                ours: head,
                theirs: self.describe("MERGE_HEAD"),
            },
            RepositoryState::CherryPicking => ConflictLabels {
                ours: head,
                theirs: self.describe("CHERRY_PICK_HEAD"),
            },
            RepositoryState::Reverting => ConflictLabels {
                ours: head,
                theirs: self.describe("REVERT_HEAD"),
            },
            RepositoryState::Normal => ConflictLabels {
                ours: head,
                theirs: "stash".to_owned(),
            },
        }
    }

    /// 写入合并结果并标记为已解决；`content` 为 `None` 表示接受删除。
    pub fn resolve_conflict(
        &self,
        path: String,
        content: Option<String>,
    ) -> std::result::Result<(), CoreError> {
        match content {
            Some(text) => {
                std::fs::write(self.root.join(&path), text)?;
                self.git.run(&self.root, ["add", "--", path.as_str()])?;
            }
            None => {
                self.git.run(
                    &self.root,
                    ["rm", "-q", "--ignore-unmatch", "--", path.as_str()],
                )?;
            }
        }
        Ok(())
    }

    /// 整个文件接受某一方的版本（IDEA 的 Accept Yours / Accept Theirs）。二进制文件同样适用。
    pub fn accept_conflict_side(
        &self,
        path: String,
        side: ConflictSide,
    ) -> std::result::Result<(), CoreError> {
        let stage = match side {
            ConflictSide::Ours => 2,
            ConflictSide::Theirs => 3,
        };
        if !self.stage_exists(stage, &path) {
            // 该方删除了文件：接受删除。
            return self.resolve_conflict(path, None);
        }
        let flag = match side {
            ConflictSide::Ours => "--ours",
            ConflictSide::Theirs => "--theirs",
        };
        self.git
            .run(&self.root, ["checkout", flag, "--", path.as_str()])?;
        self.git.run(&self.root, ["add", "--", path.as_str()])?;
        Ok(())
    }

    /// 合并、拣选或还原进行中时 git 准备好的提交信息（去掉注释行），用于预填提交信息框。
    pub fn merge_message(&self) -> Option<String> {
        let text = std::fs::read_to_string(self.git_dir.join("MERGE_MSG")).ok()?;
        let message: Vec<&str> = text.lines().filter(|l| !l.starts_with('#')).collect();
        let message = message.join("\n").trim().to_owned();
        (!message.is_empty()).then_some(message)
    }
}

impl Repository {
    fn stage_exists(&self, stage: u8, path: &str) -> bool {
        let object = format!(":{stage}:{path}");
        self.git
            .run(&self.root, ["cat-file", "-e", object.as_str()])
            .is_ok()
    }

    fn stage_content(&self, stage: u8, path: &str) -> Result<Option<String>> {
        if !self.stage_exists(stage, path) {
            return Ok(None);
        }
        let object = format!(":{stage}:{path}");
        let out = self
            .git
            .run(&self.root, ["cat-file", "blob", object.as_str()])?;
        Ok(Some(String::from_utf8_lossy(&out.stdout).into_owned()))
    }

    fn read_git_file(&self, name: &str) -> Option<String> {
        let text = std::fs::read_to_string(self.git_dir.join(name)).ok()?;
        Some(text.trim().to_owned())
    }

    /// 把修订描述为指向它的分支名，没有则用短哈希。
    fn describe(&self, revision: &str) -> String {
        let points_at = format!("--points-at={revision}");
        if let Ok(out) = self.git.run(
            &self.root,
            [
                "for-each-ref",
                points_at.as_str(),
                "--format=%(refname:short)",
                "refs/heads",
                "refs/remotes",
            ],
        ) && let Some(name) = String::from_utf8_lossy(&out.stdout)
            .lines()
            .find(|l| !l.ends_with("/HEAD"))
        {
            return name.to_owned();
        }
        self.git
            .run(&self.root, ["rev-parse", "--short", revision])
            .map(|out| String::from_utf8_lossy(&out.stdout).trim().to_owned())
            .unwrap_or_else(|_| revision.to_owned())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kinds(
        base: &str,
        ours: &str,
        theirs: &str,
    ) -> Vec<(MergeChunkKind, u32, u32, u32, u32, u32, u32)> {
        merge_chunks(base.into(), ours.into(), theirs.into())
            .into_iter()
            .map(|c| {
                (
                    c.kind,
                    c.base_start,
                    c.base_count,
                    c.ours_start,
                    c.ours_count,
                    c.theirs_start,
                    c.theirs_count,
                )
            })
            .collect()
    }

    #[test]
    fn independent_changes_do_not_conflict() {
        let base = "a\nb\nc\nd\ne\n";
        let ours = "A\nb\nc\nd\ne\n";
        let theirs = "a\nb\nc\nd\nE\nf\n";
        assert_eq!(
            kinds(base, ours, theirs),
            [
                (MergeChunkKind::Ours, 0, 1, 0, 1, 0, 1),
                (MergeChunkKind::Theirs, 4, 1, 4, 1, 4, 2),
            ]
        );
    }

    #[test]
    fn adjacent_changes_do_not_conflict() {
        let base = "a\nb\nc\n";
        let ours = "A\nb\nc\n";
        let theirs = "a\nB\nc\n";
        let k = kinds(base, ours, theirs);
        assert_eq!(k.len(), 2);
        assert!(k.iter().all(|c| c.0 != MergeChunkKind::Conflict));
    }

    #[test]
    fn identical_changes_are_both() {
        assert_eq!(
            kinds("a\nb\nc\n", "a\nX\nc\n", "a\nX\nc\n"),
            [(MergeChunkKind::Both, 1, 1, 1, 1, 1, 1)]
        );
    }

    #[test]
    fn overlapping_changes_conflict() {
        assert_eq!(
            kinds("a\nb\nc\n", "a\nours\nc\n", "a\ntheirs\nc\n"),
            [(MergeChunkKind::Conflict, 1, 1, 1, 1, 1, 1)]
        );
        // 一方删除、另一方修改同一行。
        assert_eq!(
            kinds("a\nb\nc\n", "a\nc\n", "a\nB\nc\n"),
            [(MergeChunkKind::Conflict, 1, 1, 1, 0, 1, 1)]
        );
    }

    #[test]
    fn insertions_at_same_point_conflict() {
        assert_eq!(
            kinds("a\nb\n", "a\nours\nb\n", "a\ntheirs\nb\n"),
            [(MergeChunkKind::Conflict, 1, 0, 1, 1, 1, 1)]
        );
    }

    #[test]
    fn offsets_track_earlier_changes() {
        // ours 在开头插入两行，之后 theirs 的修改在 ours 中的位置要相应后移。
        let base = "a\nb\nc\nd\n";
        let ours = "x\ny\na\nb\nc\nd\n";
        let theirs = "a\nb\nc\nD\n";
        assert_eq!(
            kinds(base, ours, theirs),
            [
                (MergeChunkKind::Ours, 0, 0, 0, 2, 0, 0),
                (MergeChunkKind::Theirs, 3, 1, 5, 1, 3, 1),
            ]
        );
    }
}
