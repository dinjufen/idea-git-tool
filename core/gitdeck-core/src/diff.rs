//! 行级差异：用于编辑器 gutter 的变更标记（IDEA 的 line status），以及后续的 Diff 视图。

use std::time::{Duration, Instant};

use similar::{Algorithm, DiffOp};

use crate::error::CoreError;
use crate::repo::Repository;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum LineChangeKind {
    Added,
    Modified,
    Deleted,
}

/// 一段连续的行变更。行号从 0 开始。
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct LineChange {
    pub kind: LineChangeKind,
    /// 在新文本中的起始行；删除时为删除位置之后的那一行。
    pub start: u32,
    /// 新文本中的行数；删除时为 0。
    pub count: u32,
    /// 在基准文本中的起始行。
    pub base_start: u32,
    /// 基准文本中的行数；新增时为 0。
    pub base_count: u32,
}

/// 单次计算的时间上限；超时后 similar 会返回不那么精确但正确的结果。
const DIFF_DEADLINE: Duration = Duration::from_millis(500);

/// 计算从 `base` 到 `text` 的行级变更。换行符差异（CRLF / LF）被忽略，与 IDEA 一致。
#[uniffi::export]
pub fn line_changes(base: String, text: String) -> Vec<LineChange> {
    let old = split_lines(&base);
    let new = split_lines(&text);
    let ops = similar::capture_diff_slices_deadline(
        Algorithm::Myers,
        &old,
        &new,
        Some(Instant::now() + DIFF_DEADLINE),
    );

    let mut changes: Vec<LineChange> = Vec::new();
    for op in ops {
        let (base_start, base_count, start, count) = match op {
            DiffOp::Equal { .. } => continue,
            DiffOp::Delete {
                old_index,
                old_len,
                new_index,
            } => (old_index, old_len, new_index, 0),
            DiffOp::Insert {
                old_index,
                new_index,
                new_len,
            } => (old_index, 0, new_index, new_len),
            DiffOp::Replace {
                old_index,
                old_len,
                new_index,
                new_len,
            } => (old_index, old_len, new_index, new_len),
        };
        // 相邻的删除与插入合并为一段“修改”。
        if let Some(last) = changes.last_mut()
            && last.base_start + last.base_count == base_start as u32
            && last.start + last.count == start as u32
        {
            last.base_count += base_count as u32;
            last.count += count as u32;
            last.kind = kind_of(last.base_count, last.count);
            continue;
        }
        changes.push(LineChange {
            kind: kind_of(base_count as u32, count as u32),
            start: start as u32,
            count: count as u32,
            base_start: base_start as u32,
            base_count: base_count as u32,
        });
    }
    changes
}

fn kind_of(base_count: u32, count: u32) -> LineChangeKind {
    match (base_count, count) {
        (0, _) => LineChangeKind::Added,
        (_, 0) => LineChangeKind::Deleted,
        _ => LineChangeKind::Modified,
    }
}

fn split_lines(text: &str) -> Vec<&str> {
    text.lines()
        .map(|l| l.strip_suffix('\r').unwrap_or(l))
        .collect()
}

#[uniffi::export]
impl Repository {
    /// 读取文件在某个修订中的内容；该修订中不存在此文件时返回 `None`。
    ///
    /// `revision` 可以是 `HEAD`、提交哈希或分支名；`path` 相对仓库根目录。
    /// 非 UTF-8 内容按有损方式解码。
    pub fn file_at_revision(
        &self,
        revision: String,
        path: String,
    ) -> std::result::Result<Option<String>, CoreError> {
        if revision.starts_with('-') || revision.contains(':') {
            return Err(CoreError::Parse {
                detail: format!("invalid revision: {revision:?}"),
            });
        }
        let object = format!("{revision}:{path}");
        // `-e` 只检查对象是否存在：不存在时退出码为 1，不当作错误。
        if self
            .git
            .run(&self.root, ["cat-file", "-e", object.as_str()])
            .is_err()
        {
            return Ok(None);
        }
        let out = self
            .git
            .run(&self.root, ["cat-file", "blob", object.as_str()])?;
        Ok(Some(String::from_utf8_lossy(&out.stdout).into_owned()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn change(
        kind: LineChangeKind,
        start: u32,
        count: u32,
        base_start: u32,
        base_count: u32,
    ) -> LineChange {
        LineChange {
            kind,
            start,
            count,
            base_start,
            base_count,
        }
    }

    #[test]
    fn identical_text_has_no_changes() {
        assert!(line_changes("a\nb\n".into(), "a\nb\n".into()).is_empty());
    }

    #[test]
    fn detects_added_modified_and_deleted_lines() {
        let base = "one\ntwo\nthree\nfour\nfive\n";
        let text = "zero\none\nTWO\nthree\nfive\n";
        assert_eq!(
            line_changes(base.into(), text.into()),
            [
                change(LineChangeKind::Added, 0, 1, 0, 0),
                change(LineChangeKind::Modified, 2, 1, 1, 1),
                change(LineChangeKind::Deleted, 4, 0, 3, 1),
            ]
        );
    }

    #[test]
    fn ignores_line_ending_differences() {
        assert!(line_changes("a\nb\n".into(), "a\r\nb\r\n".into()).is_empty());
    }

    #[test]
    fn new_file_is_all_added() {
        assert_eq!(
            line_changes(String::new(), "x\ny\n".into()),
            [change(LineChangeKind::Added, 0, 2, 0, 0)]
        );
    }
}
