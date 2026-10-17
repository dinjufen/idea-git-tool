//! 解析 `git status --porcelain=v2 -z --branch`。
//!
//! 格式说明见 git-status(1) “Porcelain Format Version 2”。

use crate::error::{CoreError, Result};

/// 单侧（暂存区或工作区）的变更类型。
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ChangeKind {
    Unmodified,
    Modified,
    TypeChanged,
    Added,
    Deleted,
    Renamed,
    Copied,
    Untracked,
    Ignored,
}

/// 冲突类型，对应 IDEA Conflicts 对话框中的 “Both Modified” 等状态。
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ConflictKind {
    BothDeleted,
    AddedByUs,
    DeletedByThem,
    AddedByThem,
    DeletedByUs,
    BothAdded,
    BothModified,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FileChange {
    /// 相对仓库根目录的路径，使用 `/` 分隔。
    pub path: String,
    /// 重命名或复制前的路径。
    pub orig_path: Option<String>,
    /// HEAD 与暂存区之间的变更。
    pub staged: ChangeKind,
    /// 暂存区与工作区之间的变更。
    pub unstaged: ChangeKind,
    pub conflict: Option<ConflictKind>,
    pub is_submodule: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct BranchStatus {
    /// 当前分支短名；分离 HEAD 时为 `None`。
    pub head: Option<String>,
    /// 当前提交；尚无提交时为 `None`。
    pub oid: Option<String>,
    pub upstream: Option<String>,
    pub ahead: u32,
    pub behind: u32,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct RepoStatus {
    pub branch: BranchStatus,
    pub changes: Vec<FileChange>,
}

pub const STATUS_ARGS: &[&str] = &[
    "--no-optional-locks",
    "status",
    "--porcelain=v2",
    "-z",
    "--branch",
    "--untracked-files=all",
];

pub fn parse_status_v2(output: &[u8]) -> Result<RepoStatus> {
    let mut status = RepoStatus::default();
    let mut records = output.split(|b| *b == 0);

    while let Some(record) = records.next() {
        if record.is_empty() {
            continue;
        }
        let line = String::from_utf8_lossy(record);
        match record[0] {
            b'#' => parse_header(&line, &mut status.branch)?,
            b'1' => {
                let f = fields(&line, 9)?;
                status.changes.push(FileChange {
                    path: f[8].to_owned(),
                    orig_path: None,
                    staged: change_kind(f[1], 0)?,
                    unstaged: change_kind(f[1], 1)?,
                    conflict: None,
                    is_submodule: f[2].starts_with('S'),
                });
            }
            b'2' => {
                let f = fields(&line, 10)?;
                let orig = records
                    .next()
                    .ok_or_else(|| parse_error("missing rename source"))?;
                status.changes.push(FileChange {
                    path: f[9].to_owned(),
                    orig_path: Some(String::from_utf8_lossy(orig).into_owned()),
                    staged: change_kind(f[1], 0)?,
                    unstaged: change_kind(f[1], 1)?,
                    conflict: None,
                    is_submodule: f[2].starts_with('S'),
                });
            }
            b'u' => {
                let f = fields(&line, 11)?;
                status.changes.push(FileChange {
                    path: f[10].to_owned(),
                    orig_path: None,
                    staged: ChangeKind::Unmodified,
                    unstaged: ChangeKind::Unmodified,
                    conflict: Some(conflict_kind(f[1])?),
                    is_submodule: f[2].starts_with('S'),
                });
            }
            b'?' | b'!' => {
                let path = line.get(2..).ok_or_else(|| parse_error(&line))?;
                let kind = if record[0] == b'?' {
                    ChangeKind::Untracked
                } else {
                    ChangeKind::Ignored
                };
                status.changes.push(FileChange {
                    path: path.to_owned(),
                    orig_path: None,
                    staged: ChangeKind::Unmodified,
                    unstaged: kind,
                    conflict: None,
                    is_submodule: false,
                });
            }
            _ => return Err(parse_error(&line)),
        }
    }
    Ok(status)
}

fn parse_header(line: &str, branch: &mut BranchStatus) -> Result<()> {
    let Some((key, value)) = line.trim_start_matches("# ").split_once(' ') else {
        return Ok(());
    };
    match key {
        "branch.oid" => branch.oid = (value != "(initial)").then(|| value.to_owned()),
        "branch.head" => branch.head = (value != "(detached)").then(|| value.to_owned()),
        "branch.upstream" => branch.upstream = Some(value.to_owned()),
        "branch.ab" => {
            let (ahead, behind) = value.split_once(' ').ok_or_else(|| parse_error(line))?;
            branch.ahead = parse_count(ahead.trim_start_matches('+'), line)?;
            branch.behind = parse_count(behind.trim_start_matches('-'), line)?;
        }
        // 未来的 git 版本可能新增其他 header，忽略即可。
        _ => {}
    }
    Ok(())
}

/// 按空格切分为 `n` 段，最后一段是路径（可能含空格）。
fn fields(line: &str, n: usize) -> Result<Vec<&str>> {
    let parts: Vec<&str> = line.splitn(n, ' ').collect();
    if parts.len() != n {
        return Err(parse_error(line));
    }
    Ok(parts)
}

fn change_kind(xy: &str, side: usize) -> Result<ChangeKind> {
    let c = xy.as_bytes().get(side).ok_or_else(|| parse_error(xy))?;
    Ok(match c {
        b'.' => ChangeKind::Unmodified,
        b'M' => ChangeKind::Modified,
        b'T' => ChangeKind::TypeChanged,
        b'A' => ChangeKind::Added,
        b'D' => ChangeKind::Deleted,
        b'R' => ChangeKind::Renamed,
        b'C' => ChangeKind::Copied,
        _ => return Err(parse_error(xy)),
    })
}

fn conflict_kind(xy: &str) -> Result<ConflictKind> {
    Ok(match xy {
        "DD" => ConflictKind::BothDeleted,
        "AU" => ConflictKind::AddedByUs,
        "UD" => ConflictKind::DeletedByThem,
        "UA" => ConflictKind::AddedByThem,
        "DU" => ConflictKind::DeletedByUs,
        "AA" => ConflictKind::BothAdded,
        "UU" => ConflictKind::BothModified,
        _ => return Err(parse_error(xy)),
    })
}

fn parse_count(s: &str, line: &str) -> Result<u32> {
    s.parse().map_err(|_| parse_error(line))
}

fn parse_error(context: &str) -> CoreError {
    CoreError::Parse {
        detail: format!("unexpected status record: {context:?}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(s: &str) -> RepoStatus {
        parse_status_v2(s.as_bytes()).expect("parse")
    }

    #[test]
    fn branch_headers() {
        let st = parse(
            "# branch.oid 1234abcd\0# branch.head feature/x\0# branch.upstream origin/feature/x\0# branch.ab +3 -1\0",
        );
        assert_eq!(
            st.branch,
            BranchStatus {
                head: Some("feature/x".into()),
                oid: Some("1234abcd".into()),
                upstream: Some("origin/feature/x".into()),
                ahead: 3,
                behind: 1,
            }
        );
        assert!(st.changes.is_empty());
    }

    #[test]
    fn initial_and_detached() {
        let st = parse("# branch.oid (initial)\0# branch.head (detached)\0");
        assert_eq!(st.branch.oid, None);
        assert_eq!(st.branch.head, None);
    }

    #[test]
    fn ordinary_change_with_spaces_and_unicode() {
        let st = parse("1 MM N... 100644 100644 100644 aaa bbb 目录/带 空格.txt\0");
        assert_eq!(st.changes.len(), 1);
        let c = &st.changes[0];
        assert_eq!(c.path, "目录/带 空格.txt");
        assert_eq!(c.staged, ChangeKind::Modified);
        assert_eq!(c.unstaged, ChangeKind::Modified);
        assert!(!c.is_submodule);
    }

    #[test]
    fn rename_reads_source_from_next_record() {
        let st =
            parse("2 R. N... 100644 100644 100644 aaa aaa R100 new name.rs\0old name.rs\0? x\0");
        assert_eq!(st.changes.len(), 2);
        assert_eq!(st.changes[0].path, "new name.rs");
        assert_eq!(st.changes[0].orig_path.as_deref(), Some("old name.rs"));
        assert_eq!(st.changes[0].staged, ChangeKind::Renamed);
        assert_eq!(st.changes[1].unstaged, ChangeKind::Untracked);
    }

    #[test]
    fn unmerged_entries() {
        let st = parse(
            "u UU N... 100644 100644 100644 100644 a b c both.txt\0u UD N... 100644 100644 000000 100644 a b c gone.txt\0",
        );
        assert_eq!(st.changes[0].conflict, Some(ConflictKind::BothModified));
        assert_eq!(st.changes[1].conflict, Some(ConflictKind::DeletedByThem));
    }

    #[test]
    fn submodule_flag() {
        let st = parse("1 .M SC.. 160000 160000 160000 aaa aaa libs/sub\0");
        assert!(st.changes[0].is_submodule);
    }

    #[test]
    fn malformed_record_is_an_error() {
        assert!(parse_status_v2(b"1 MM too few\0").is_err());
        assert!(parse_status_v2(b"Z what\0").is_err());
    }
}
