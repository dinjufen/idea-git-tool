//! Git Log 与提交详情（对应 IDEA Git 工具窗口的 Log 标签页）。

use crate::error::{CoreError, Result};
use crate::git::log::{self, ChangedFile, RefKind, RefLabel};
use crate::graph::{self, GraphRow};
use crate::repo::Repository;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, uniffi::Enum)]
pub enum LogOrder {
    /// 拓扑顺序，同一分支的提交排在一起（IDEA 的 IntelliSort）。
    #[default]
    Topological,
    /// 按提交时间排序。
    Date,
}

/// Log 筛选条件，对应 IDEA Log 工具栏上的 Branch / User / Date / Paths 筛选与搜索框。
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct LogFilter {
    /// 要显示的分支或修订；为空时显示所有分支、远程分支、标签与 HEAD。
    pub revisions: Vec<String>,
    /// 作者（匹配姓名或邮箱，满足任意一个即可）。
    pub authors: Vec<String>,
    /// 提交时间下限（Unix 秒，含）。
    pub since: Option<i64>,
    /// 提交时间上限（Unix 秒，含）。
    pub until: Option<i64>,
    /// 只显示修改了这些路径的提交（相对仓库根目录）。
    pub paths: Vec<String>,
    /// 在提交信息中搜索（不区分大小写，按字面匹配）。
    pub text: Option<String>,
    pub order: LogOrder,
    /// 最多返回的提交数；0 表示使用默认值。
    pub max_count: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LogCommit {
    pub hash: String,
    pub parents: Vec<String>,
    pub subject: String,
    pub author_name: String,
    pub author_email: String,
    pub author_time: i64,
    pub committer_name: String,
    pub committer_email: String,
    pub committer_time: i64,
    pub refs: Vec<RefLabel>,
    pub graph: GraphRow,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LogPage {
    pub commits: Vec<LogCommit>,
    /// 还有更多提交未加载（达到 `max_count`）。
    pub has_more: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CommitDetails {
    pub hash: String,
    pub parents: Vec<String>,
    /// 完整提交信息（标题 + 正文）。
    pub message: String,
    pub author_name: String,
    pub author_email: String,
    pub author_time: i64,
    pub committer_name: String,
    pub committer_email: String,
    pub committer_time: i64,
    /// 相对第一个父提交的改动；根提交为全部文件。
    pub files: Vec<ChangedFile>,
}

const DEFAULT_MAX_COUNT: u32 = 2000;

#[uniffi::export]
impl Repository {
    pub fn log(&self, filter: LogFilter) -> std::result::Result<LogPage, CoreError> {
        let max_count = if filter.max_count == 0 {
            DEFAULT_MAX_COUNT
        } else {
            filter.max_count
        };
        let has_head = self.has_head();
        let args = log_args(&filter, max_count, has_head);
        let out = self.git.run(&self.root, &args)?;
        let mut raw = log::parse_log(&out.stdout)?;
        let has_more = raw.len() > max_count as usize;
        raw.truncate(max_count as usize);

        let refs_out = self.git.run(&self.root, log::REFS_ARGS)?;
        let current = self.current_branch();
        let mut refs = log::parse_refs(&refs_out.stdout, current.as_deref());
        if current.is_none() && has_head {
            // 分离 HEAD：在当前提交上显示 HEAD 标签。
            let head = self.git.run(&self.root, ["rev-parse", "HEAD"])?;
            let head = String::from_utf8_lossy(&head.stdout).trim().to_owned();
            refs.entry(head).or_default().insert(
                0,
                RefLabel {
                    name: "HEAD".into(),
                    kind: RefKind::Head,
                    is_current: true,
                },
            );
        }

        let pairs: Vec<(String, Vec<String>)> = raw
            .iter()
            .map(|c| (c.hash.clone(), c.parents.clone()))
            .collect();
        let rows = graph::layout(&pairs);
        let commits = raw
            .into_iter()
            .zip(rows)
            .map(|(c, graph)| LogCommit {
                refs: refs.remove(&c.hash).unwrap_or_default(),
                hash: c.hash,
                parents: c.parents,
                subject: c.message,
                author_name: c.author_name,
                author_email: c.author_email,
                author_time: c.author_time,
                committer_name: c.committer_name,
                committer_email: c.committer_email,
                committer_time: c.committer_time,
                graph,
            })
            .collect();
        Ok(LogPage { commits, has_more })
    }

    pub fn commit_details(&self, hash: String) -> std::result::Result<CommitDetails, CoreError> {
        validate_hash(&hash)?;
        let out = self.git.run(
            &self.root,
            [
                "show",
                "-s",
                log::DETAILS_FORMAT,
                "--end-of-options",
                hash.as_str(),
            ],
        )?;
        let commit = log::parse_log(&out.stdout)?
            .into_iter()
            .next()
            .ok_or_else(|| CoreError::Parse {
                detail: format!("no commit for {hash}"),
            })?;

        let mut args = vec![
            "diff-tree",
            "-r",
            "-z",
            "-M",
            "--name-status",
            "--no-commit-id",
        ];
        match commit.parents.first() {
            Some(parent) => {
                args.push(parent.as_str());
                args.push(commit.hash.as_str());
            }
            None => args.extend(["--root", commit.hash.as_str()]),
        }
        let diff = self.git.run(&self.root, &args)?;
        let files = log::parse_name_status(&diff.stdout)?;

        Ok(CommitDetails {
            hash: commit.hash,
            parents: commit.parents,
            message: commit.message,
            author_name: commit.author_name,
            author_email: commit.author_email,
            author_time: commit.author_time,
            committer_name: commit.committer_name,
            committer_email: commit.committer_email,
            committer_time: commit.committer_time,
            files,
        })
    }

    /// 包含该提交的本地与远程分支（IDEA 详情面板中的 “In N branches”）。
    pub fn branches_containing(&self, hash: String) -> std::result::Result<Vec<String>, CoreError> {
        validate_hash(&hash)?;
        let contains = format!("--contains={hash}");
        let out = self.git.run(
            &self.root,
            [
                "for-each-ref",
                contains.as_str(),
                "--format=%(refname:short)",
                "refs/heads",
                "refs/remotes",
            ],
        )?;
        Ok(String::from_utf8_lossy(&out.stdout)
            .lines()
            .filter(|l| !l.is_empty() && !l.ends_with("/HEAD"))
            .map(str::to_owned)
            .collect())
    }
}

fn log_args(filter: &LogFilter, max_count: u32, has_head: bool) -> Vec<String> {
    let mut args: Vec<String> = vec![
        "log".into(),
        match filter.order {
            LogOrder::Topological => "--topo-order".into(),
            LogOrder::Date => "--date-order".into(),
        },
        // 多取一条用于判断是否还有更多。
        format!("--max-count={}", max_count + 1),
        log::LOG_FORMAT.into(),
    ];
    for author in &filter.authors {
        args.push(format!("--author={author}"));
    }
    if let Some(text) = filter.text.as_deref().filter(|t| !t.trim().is_empty()) {
        args.push(format!("--grep={text}"));
    }
    if !filter.authors.is_empty() || filter.text.is_some() {
        args.push("--fixed-strings".into());
        args.push("--regexp-ignore-case".into());
    }
    // `--max-age` / `--min-age` 直接接受 Unix 时间戳，避免日期字符串解析的歧义。
    if let Some(since) = filter.since {
        args.push(format!("--max-age={since}"));
    }
    if let Some(until) = filter.until {
        args.push(format!("--min-age={until}"));
    }
    if !filter.paths.is_empty() {
        // 按路径筛选时改写父提交，使提交图仍然连贯。
        args.push("--parents".into());
    }

    // `--branches` 等是选项，必须放在 `--end-of-options` 之前；其后的内容一律按修订名解析。
    if filter.revisions.is_empty() {
        args.extend(["--branches", "--remotes", "--tags"].map(String::from));
    }
    args.push("--end-of-options".into());
    if filter.revisions.is_empty() {
        if has_head {
            args.push("HEAD".into());
        }
    } else {
        args.extend(filter.revisions.iter().cloned());
    }
    if !filter.paths.is_empty() {
        args.push("--".into());
        args.extend(filter.paths.iter().cloned());
    }
    args
}

/// 只接受十六进制提交哈希（或其前缀），避免把任意字符串当作 git 参数。
fn validate_hash(hash: &str) -> Result<()> {
    if (4..=64).contains(&hash.len()) && hash.bytes().all(|b| b.is_ascii_hexdigit()) {
        Ok(())
    } else {
        Err(CoreError::Parse {
            detail: format!("invalid commit hash: {hash:?}"),
        })
    }
}
