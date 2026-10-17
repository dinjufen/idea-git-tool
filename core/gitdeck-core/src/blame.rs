//! Annotate（git blame）与文件历史（对应 IDEA 的 “Annotate with Git Blame” 与 “Show History”）。

use std::collections::HashMap;

use crate::error::{CoreError, Result};
use crate::git::status::ChangeKind;
use crate::repo::Repository;

/// 注释中引用的一个提交。未提交的行使用全零哈希，`is_uncommitted` 为 true。
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct BlameCommit {
    pub hash: String,
    pub author_name: String,
    pub author_email: String,
    pub author_time: i64,
    pub summary: String,
    pub is_uncommitted: bool,
}

/// 每行对应的提交在 `commits` 中的下标；同一提交只出现一次，避免跨 FFI 重复传输。
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct BlameResult {
    pub commits: Vec<BlameCommit>,
    /// 第 i 个元素是第 i 行（从 0 开始）对应的提交下标。
    pub lines: Vec<u32>,
}

/// 文件历史中的一个修订。
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FileRevision {
    pub hash: String,
    pub parents: Vec<String>,
    pub subject: String,
    pub author_name: String,
    pub author_email: String,
    pub author_time: i64,
    /// 该修订中文件的路径（跟踪重命名后可能与当前路径不同）。
    pub path: String,
    /// 本次重命名之前的路径。
    pub orig_path: Option<String>,
    pub kind: ChangeKind,
}

#[uniffi::export]
impl Repository {
    /// 对工作区中的文件（或指定修订中的文件）做 blame。
    pub fn blame(
        &self,
        path: String,
        revision: Option<String>,
    ) -> std::result::Result<BlameResult, CoreError> {
        let mut args = vec!["blame", "--porcelain"];
        if let Some(rev) = revision.as_deref() {
            if rev.starts_with('-') {
                return Err(CoreError::Parse {
                    detail: format!("invalid revision: {rev:?}"),
                });
            }
            args.push(rev);
        }
        args.extend(["--", path.as_str()]);
        let out = self.git.run(&self.root, args)?;
        parse_blame(&out.stdout)
    }

    /// 文件的修订历史（`git log --follow`），最新的在前。
    pub fn file_history(
        &self,
        path: String,
        max_count: u32,
    ) -> std::result::Result<Vec<FileRevision>, CoreError> {
        let limit = format!(
            "--max-count={}",
            if max_count == 0 { 1000 } else { max_count }
        );
        let out = self.git.run(
            &self.root,
            [
                "log",
                "--follow",
                "--name-status",
                "-M",
                limit.as_str(),
                "--format=%x1e%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%s",
                "--",
                path.as_str(),
            ],
        )?;
        parse_file_history(&out.stdout)
    }
}

pub(crate) fn parse_blame(output: &[u8]) -> Result<BlameResult> {
    let text = String::from_utf8_lossy(output);
    let mut commits: Vec<BlameCommit> = Vec::new();
    let mut index_of: HashMap<String, u32> = HashMap::new();
    let mut lines: Vec<u32> = Vec::new();
    let mut current: Option<u32> = None;

    for line in text.split('\n') {
        if let Some(_content) = line.strip_prefix('\t') {
            // 源码行：归属于最近的头部所描述的提交。
            let index = current.ok_or_else(|| parse_error("content before header"))?;
            lines.push(index);
            continue;
        }
        let mut parts = line.splitn(2, ' ');
        let key = parts.next().unwrap_or_default();
        let value = parts.next().unwrap_or_default();
        if key.len() == 40 && key.bytes().all(|b| b.is_ascii_hexdigit()) {
            // 头部行：`<hash> <原行号> <最终行号> [<行数>]`
            let index = *index_of.entry(key.to_owned()).or_insert_with(|| {
                commits.push(BlameCommit {
                    hash: key.to_owned(),
                    author_name: String::new(),
                    author_email: String::new(),
                    author_time: 0,
                    summary: String::new(),
                    is_uncommitted: key.bytes().all(|b| b == b'0'),
                });
                (commits.len() - 1) as u32
            });
            current = Some(index);
            continue;
        }
        let Some(index) = current else { continue };
        let commit = &mut commits[index as usize];
        match key {
            "author" => commit.author_name = value.to_owned(),
            "author-mail" => {
                commit.author_email = value
                    .trim_start_matches('<')
                    .trim_end_matches('>')
                    .to_owned()
            }
            "author-time" => commit.author_time = value.parse().unwrap_or(0),
            "summary" => commit.summary = value.to_owned(),
            _ => {}
        }
    }
    Ok(BlameResult { commits, lines })
}

pub(crate) fn parse_file_history(output: &[u8]) -> Result<Vec<FileRevision>> {
    let text = String::from_utf8_lossy(output);
    let mut revisions = Vec::new();
    for record in text.split('\x1e').filter(|r| !r.trim().is_empty()) {
        let mut lines = record.lines();
        let header = lines.next().ok_or_else(|| parse_error(record))?;
        let f: Vec<&str> = header.splitn(6, '\x1f').collect();
        let [hash, parents, author, email, time, subject] = f[..] else {
            return Err(parse_error(header));
        };
        // name-status 行：`M\tpath` 或 `R087\told\tnew`。--follow 时每个提交只列出该文件。
        let status = lines.find(|l| !l.trim().is_empty()).unwrap_or_default();
        let cols: Vec<&str> = status.split('\t').collect();
        let (kind, path, orig_path) =
            match (cols.first().and_then(|s| s.bytes().next()), cols.len()) {
                (Some(b'R'), 3) => (ChangeKind::Renamed, cols[2], Some(cols[1].to_owned())),
                (Some(b'C'), 3) => (ChangeKind::Copied, cols[2], Some(cols[1].to_owned())),
                (Some(b'A'), 2) => (ChangeKind::Added, cols[1], None),
                (Some(b'D'), 2) => (ChangeKind::Deleted, cols[1], None),
                (Some(_), 2) => (ChangeKind::Modified, cols[1], None),
                _ => (ChangeKind::Modified, "", None),
            };
        revisions.push(FileRevision {
            hash: hash.to_owned(),
            parents: parents.split_whitespace().map(str::to_owned).collect(),
            subject: subject.to_owned(),
            author_name: author.to_owned(),
            author_email: email.to_owned(),
            author_time: time.parse().unwrap_or(0),
            path: path.to_owned(),
            orig_path,
            kind,
        });
    }
    Ok(revisions)
}

fn parse_error(context: &str) -> CoreError {
    CoreError::Parse {
        detail: format!("unexpected blame/history output: {context:?}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_porcelain_blame_with_repeated_commits() {
        let a = "a".repeat(40);
        let z = "0".repeat(40);
        let out = format!(
            "{a} 1 1 2\nauthor Alice\nauthor-mail <alice@x.com>\nauthor-time 100\nsummary First\nfilename f.rs\n\tline one\n\
             {a} 2 2\n\tline two\n\
             {z} 3 3 1\nauthor Not Committed Yet\nauthor-mail <not.committed.yet>\nauthor-time 200\nsummary Version of f.rs from f.rs\nfilename f.rs\n\tlocal edit\n"
        );
        let blame = parse_blame(out.as_bytes()).unwrap();
        assert_eq!(blame.lines, [0, 0, 1]);
        assert_eq!(blame.commits[0].author_name, "Alice");
        assert_eq!(blame.commits[0].author_email, "alice@x.com");
        assert_eq!(blame.commits[0].summary, "First");
        assert!(!blame.commits[0].is_uncommitted);
        assert!(blame.commits[1].is_uncommitted);
    }

    #[test]
    fn parses_history_with_rename() {
        let out = "\x1eh2\x1fh1\x1fBob\x1fb@x.com\x1f20\x1fRename\n\nR100\told.rs\tnew.rs\n\
                   \x1eh1\x1f\x1fBob\x1fb@x.com\x1f10\x1fAdd\n\nA\told.rs\n";
        let history = parse_file_history(out.as_bytes()).unwrap();
        assert_eq!(history.len(), 2);
        assert_eq!(history[0].kind, ChangeKind::Renamed);
        assert_eq!(history[0].path, "new.rs");
        assert_eq!(history[0].orig_path.as_deref(), Some("old.rs"));
        assert_eq!(history[1].kind, ChangeKind::Added);
        assert!(history[1].parents.is_empty());
    }
}
