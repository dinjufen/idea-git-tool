//! 解析 `git log`、`for-each-ref`（引用标签）与 `diff-tree --name-status` 的输出。

use std::collections::HashMap;

use crate::error::{CoreError, Result};
use crate::git::status::ChangeKind;

const FIELD_SEP: char = '\x1f';
const RECORD_SEP: char = '\x1e';

/// Log 列表每行需要的字段；字段顺序与 [`parse_log`] 对应。
pub const LOG_FORMAT: &str =
    "--format=%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%cn%x1f%ce%x1f%ct%x1f%s%x1e";

/// 提交详情：与 [`LOG_FORMAT`] 相同，但最后一个字段为完整提交信息。
pub const DETAILS_FORMAT: &str =
    "--format=%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%cn%x1f%ce%x1f%ct%x1f%B%x1e";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RawCommit {
    pub hash: String,
    pub parents: Vec<String>,
    pub author_name: String,
    pub author_email: String,
    pub author_time: i64,
    pub committer_name: String,
    pub committer_email: String,
    pub committer_time: i64,
    /// `LOG_FORMAT` 下为标题行，`DETAILS_FORMAT` 下为完整提交信息。
    pub message: String,
}

pub fn parse_log(output: &[u8]) -> Result<Vec<RawCommit>> {
    let text = String::from_utf8_lossy(output);
    text.split(RECORD_SEP)
        .map(|r| r.trim_start_matches('\n'))
        .filter(|r| !r.is_empty())
        .map(parse_commit)
        .collect()
}

fn parse_commit(record: &str) -> Result<RawCommit> {
    let f: Vec<&str> = record.splitn(9, FIELD_SEP).collect();
    if f.len() != 9 {
        return Err(parse_error("log record", record));
    }
    Ok(RawCommit {
        hash: f[0].to_owned(),
        parents: f[1].split_whitespace().map(str::to_owned).collect(),
        author_name: f[2].to_owned(),
        author_email: f[3].to_owned(),
        author_time: f[4]
            .parse()
            .map_err(|_| parse_error("author time", record))?,
        committer_name: f[5].to_owned(),
        committer_email: f[6].to_owned(),
        committer_time: f[7]
            .parse()
            .map_err(|_| parse_error("committer time", record))?,
        message: f[8].trim_end().to_owned(),
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, uniffi::Enum)]
pub enum RefKind {
    /// 分离 HEAD 时显示的 `HEAD` 标签。
    Head,
    LocalBranch,
    RemoteBranch,
    Tag,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RefLabel {
    pub name: String,
    pub kind: RefKind,
    /// 当前检出的分支。
    pub is_current: bool,
}

pub const REFS_ARGS: &[&str] = &[
    "for-each-ref",
    "--format=%(objectname)%1f%(*objectname)%1f%(refname)%1e",
    "refs/heads",
    "refs/remotes",
    "refs/tags",
];

/// 解析引用列表为 `提交哈希 → 标签`。附注标签使用其指向的提交（`%(*objectname)`）。
pub fn parse_refs(output: &[u8], current_branch: Option<&str>) -> HashMap<String, Vec<RefLabel>> {
    let text = String::from_utf8_lossy(output);
    let mut map: HashMap<String, Vec<RefLabel>> = HashMap::new();
    for record in text.split(RECORD_SEP).map(|r| r.trim_start_matches('\n')) {
        let f: Vec<&str> = record.splitn(3, FIELD_SEP).collect();
        let [object, peeled, refname] = f[..] else {
            continue;
        };
        let (kind, name) = if let Some(n) = refname.strip_prefix("refs/heads/") {
            (RefKind::LocalBranch, n)
        } else if let Some(n) = refname.strip_prefix("refs/remotes/") {
            if n.ends_with("/HEAD") {
                continue;
            }
            (RefKind::RemoteBranch, n)
        } else if let Some(n) = refname.strip_prefix("refs/tags/") {
            (RefKind::Tag, n)
        } else {
            continue;
        };
        let target = if peeled.is_empty() { object } else { peeled };
        map.entry(target.to_owned()).or_default().push(RefLabel {
            name: name.to_owned(),
            kind,
            is_current: kind == RefKind::LocalBranch && Some(name) == current_branch,
        });
    }
    // 与 IDEA 一致：当前分支在前，其次本地分支、远程分支、标签。
    for labels in map.values_mut() {
        labels.sort_by(|a, b| {
            b.is_current
                .cmp(&a.is_current)
                .then(a.kind.cmp(&b.kind))
                .then_with(|| a.name.cmp(&b.name))
        });
    }
    map
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ChangedFile {
    pub path: String,
    /// 重命名或复制前的路径。
    pub orig_path: Option<String>,
    pub kind: ChangeKind,
}

/// 解析 `git diff-tree -r -z -M --name-status` 的输出。
pub fn parse_name_status(output: &[u8]) -> Result<Vec<ChangedFile>> {
    let text = String::from_utf8_lossy(output);
    let mut fields = text.split('\0').filter(|s| !s.is_empty());
    let mut files = Vec::new();
    while let Some(status) = fields.next() {
        let mut next_path = || {
            fields
                .next()
                .map(str::to_owned)
                .ok_or_else(|| parse_error("name-status path", status))
        };
        let file = match status.as_bytes().first() {
            Some(b'R') | Some(b'C') => {
                let orig = next_path()?;
                let path = next_path()?;
                let kind = if status.starts_with('R') {
                    ChangeKind::Renamed
                } else {
                    ChangeKind::Copied
                };
                ChangedFile {
                    path,
                    orig_path: Some(orig),
                    kind,
                }
            }
            Some(c) => {
                let kind = match c {
                    b'A' => ChangeKind::Added,
                    b'D' => ChangeKind::Deleted,
                    b'T' => ChangeKind::TypeChanged,
                    _ => ChangeKind::Modified,
                };
                ChangedFile {
                    path: next_path()?,
                    orig_path: None,
                    kind,
                }
            }
            None => continue,
        };
        files.push(file);
    }
    Ok(files)
}

fn parse_error(what: &str, context: &str) -> CoreError {
    CoreError::Parse {
        detail: format!("unexpected {what}: {context:?}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_log_records() {
        let out = "aaa\x1fbbb ccc\x1fAlice\x1fa@x.com\x1f100\x1fBob\x1fb@x.com\x1f200\x1fMerge: a \x1f b\x1e\n\
                   bbb\x1f\x1fAlice\x1fa@x.com\x1f50\x1fAlice\x1fa@x.com\x1f50\x1fInit\x1e\n";
        let commits = parse_log(out.as_bytes()).unwrap();
        assert_eq!(commits.len(), 2);
        assert_eq!(commits[0].parents, ["bbb", "ccc"]);
        assert_eq!(commits[0].committer_name, "Bob");
        assert_eq!(commits[0].committer_time, 200);
        // 标题中出现分隔符以外的任意字符都应保留。
        assert_eq!(commits[0].message, "Merge: a \x1f b");
        assert!(commits[1].parents.is_empty());
    }

    #[test]
    fn rejects_truncated_log_record() {
        assert!(parse_log(b"aaa\x1fbbb\x1e").is_err());
    }

    #[test]
    fn refs_are_grouped_and_sorted() {
        let out = "c1\x1f\x1frefs/remotes/origin/main\x1e\n\
                   c1\x1f\x1frefs/heads/main\x1e\n\
                   c1\x1f\x1frefs/heads/alpha\x1e\n\
                   t0\x1fc1\x1frefs/tags/v1.0\x1e\n\
                   c1\x1f\x1frefs/remotes/origin/HEAD\x1e\n\
                   c2\x1f\x1frefs/tags/light\x1e\n";
        let map = parse_refs(out.as_bytes(), Some("main"));
        let names: Vec<_> = map["c1"]
            .iter()
            .map(|r| (r.name.as_str(), r.kind, r.is_current))
            .collect();
        assert_eq!(
            names,
            [
                ("main", RefKind::LocalBranch, true),
                ("alpha", RefKind::LocalBranch, false),
                ("origin/main", RefKind::RemoteBranch, false),
                ("v1.0", RefKind::Tag, false),
            ]
        );
        assert_eq!(map["c2"][0].name, "light");
        assert!(!map.contains_key("t0"));
    }

    #[test]
    fn parses_name_status() {
        let out = "M\0src/a.rs\0A\0new file.txt\0D\0gone.txt\0R087\0old.rs\0new.rs\0C100\0x\0y\0";
        let files = parse_name_status(out.as_bytes()).unwrap();
        assert_eq!(files.len(), 5);
        assert_eq!(files[0].kind, ChangeKind::Modified);
        assert_eq!(files[1].path, "new file.txt");
        assert_eq!(files[2].kind, ChangeKind::Deleted);
        assert_eq!(files[3].kind, ChangeKind::Renamed);
        assert_eq!(files[3].orig_path.as_deref(), Some("old.rs"));
        assert_eq!(files[3].path, "new.rs");
        assert_eq!(files[4].kind, ChangeKind::Copied);
    }
}
