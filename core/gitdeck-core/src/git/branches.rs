//! 解析 `git for-each-ref` 输出的本地与远程分支，供 Branches 弹窗使用。

use crate::error::{CoreError, Result};

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum BranchKind {
    Local,
    Remote,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct BranchRef {
    /// 短名：本地为 `feature/x`，远程为 `origin/feature/x`。
    pub name: String,
    /// 完整引用名，例如 `refs/heads/feature/x`。
    pub full_ref: String,
    pub kind: BranchKind,
    /// 远程分支所属的 remote 名。
    pub remote: Option<String>,
    pub target: String,
    pub is_current: bool,
    pub upstream: Option<String>,
    pub ahead: u32,
    pub behind: u32,
    /// 配置了 upstream，但远程分支已被删除。
    pub upstream_gone: bool,
    /// 最近一次提交的提交者时间（Unix 秒）。
    pub committer_time: i64,
    pub subject: String,
}

const FIELD_SEP: char = '\x1f';
const RECORD_SEP: char = '\x1e';

pub const BRANCH_ARGS: &[&str] = &[
    "for-each-ref",
    "--format=%(refname)%1f%(objectname)%1f%(HEAD)%1f%(upstream:short)%1f%(upstream:track,nobracket)%1f%(committerdate:unix)%1f%(subject)%1e",
    "refs/heads",
    "refs/remotes",
];

pub fn parse_branches(output: &[u8]) -> Result<Vec<BranchRef>> {
    let text = String::from_utf8_lossy(output);
    let mut branches = Vec::new();
    for record in text.split(RECORD_SEP) {
        let record = record.trim_start_matches('\n');
        if record.is_empty() {
            continue;
        }
        let f: Vec<&str> = record.splitn(7, FIELD_SEP).collect();
        if f.len() != 7 {
            return Err(parse_error(record));
        }
        let full_ref = f[0];
        let (kind, name, remote) = if let Some(name) = full_ref.strip_prefix("refs/heads/") {
            (BranchKind::Local, name, None)
        } else if let Some(name) = full_ref.strip_prefix("refs/remotes/") {
            // `origin/HEAD` 是指向默认分支的符号引用，IDEA 不在列表里展示。
            if name.ends_with("/HEAD") {
                continue;
            }
            let remote = name.split('/').next().map(str::to_owned);
            (BranchKind::Remote, name, remote)
        } else {
            continue;
        };
        let track = parse_track(f[4]);
        branches.push(BranchRef {
            name: name.to_owned(),
            full_ref: full_ref.to_owned(),
            kind,
            remote,
            target: f[1].to_owned(),
            is_current: f[2] == "*",
            upstream: (!f[3].is_empty()).then(|| f[3].to_owned()),
            ahead: track.ahead,
            behind: track.behind,
            upstream_gone: track.gone,
            committer_time: f[5].parse().unwrap_or(0),
            subject: f[6].to_owned(),
        });
    }
    Ok(branches)
}

#[derive(Default)]
struct Track {
    ahead: u32,
    behind: u32,
    gone: bool,
}

/// 解析 `%(upstream:track,nobracket)`：`ahead 1, behind 2` / `gone` / 空。
fn parse_track(s: &str) -> Track {
    let mut track = Track::default();
    for part in s.split(", ") {
        match part.split_once(' ') {
            Some(("ahead", n)) => track.ahead = n.parse().unwrap_or(0),
            Some(("behind", n)) => track.behind = n.parse().unwrap_or(0),
            _ if part == "gone" => track.gone = true,
            _ => {}
        }
    }
    track
}

fn parse_error(context: &str) -> CoreError {
    CoreError::Parse {
        detail: format!("unexpected for-each-ref record: {context:?}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record(fields: [&str; 7]) -> String {
        format!("{}\x1e\n", fields.join("\x1f"))
    }

    #[test]
    fn parses_local_and_remote_branches() {
        let out = [
            record([
                "refs/heads/main",
                "aaa",
                "*",
                "origin/main",
                "ahead 2, behind 1",
                "1700000000",
                "Initial commit",
            ]),
            record([
                "refs/heads/feature/x",
                "bbb",
                " ",
                "",
                "",
                "1700000100",
                "Add x",
            ]),
            record([
                "refs/heads/old",
                "ccc",
                " ",
                "origin/old",
                "gone",
                "1600000000",
                "Old",
            ]),
            record([
                "refs/remotes/origin/HEAD",
                "aaa",
                " ",
                "",
                "",
                "1700000000",
                "Initial commit",
            ]),
            record([
                "refs/remotes/origin/main",
                "aaa",
                " ",
                "",
                "",
                "1700000000",
                "Initial commit",
            ]),
        ]
        .concat();
        let branches = parse_branches(out.as_bytes()).unwrap();
        assert_eq!(branches.len(), 4);

        let main = &branches[0];
        assert_eq!(main.name, "main");
        assert!(main.is_current);
        assert_eq!(main.upstream.as_deref(), Some("origin/main"));
        assert_eq!((main.ahead, main.behind), (2, 1));

        assert_eq!(branches[1].name, "feature/x");
        assert_eq!(branches[1].upstream, None);
        assert!(branches[2].upstream_gone);

        let remote = &branches[3];
        assert_eq!(remote.kind, BranchKind::Remote);
        assert_eq!(remote.name, "origin/main");
        assert_eq!(remote.remote.as_deref(), Some("origin"));
    }

    #[test]
    fn subject_may_contain_field_like_text() {
        let out = record(["refs/heads/a", "aaa", " ", "", "", "1", "fix: a | b * c"]);
        let branches = parse_branches(out.as_bytes()).unwrap();
        assert_eq!(branches[0].subject, "fix: a | b * c");
    }

    #[test]
    fn empty_output() {
        assert!(parse_branches(b"").unwrap().is_empty());
    }
}
