//! Git Console：记录客户端执行的每条 git 命令（对应 IDEA Git 工具窗口的 Console 标签）。

use std::collections::VecDeque;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ConsoleEntry {
    /// 递增序号，UI 用它增量拉取新记录。
    pub id: u64,
    /// 开始执行的时间（Unix 毫秒）。
    pub time_ms: i64,
    pub cwd: String,
    /// 显示用的命令行（不含客户端统一注入的配置参数）。
    pub command: String,
    pub exit_code: i32,
    pub duration_ms: u32,
    /// 错误输出（截断到一定长度）。
    pub output: String,
    /// 只读查询类命令（status、log 等），Console 可选择隐藏。
    pub background: bool,
}

/// 内存中最多保留的记录数。
const CAPACITY: usize = 2000;
/// 每条记录保存的输出长度上限（字节）。
const OUTPUT_LIMIT: usize = 4000;

static ENTRIES: LazyLock<Mutex<VecDeque<ConsoleEntry>>> =
    LazyLock::new(|| Mutex::new(VecDeque::new()));
static NEXT_ID: AtomicU64 = AtomicU64::new(1);

/// 返回序号大于 `after_id` 的记录（按时间顺序）。
#[uniffi::export]
pub fn console_entries(after_id: u64) -> Vec<ConsoleEntry> {
    let entries = ENTRIES.lock().unwrap_or_else(|e| e.into_inner());
    entries
        .iter()
        .filter(|e| e.id > after_id)
        .cloned()
        .collect()
}

#[uniffi::export]
pub fn clear_console() {
    ENTRIES.lock().unwrap_or_else(|e| e.into_inner()).clear();
}

pub(crate) fn record(
    cwd: &str,
    args: &[String],
    started: SystemTime,
    duration: Duration,
    exit_code: i32,
    stderr: &str,
) {
    let mut output = stderr.trim().to_owned();
    if output.len() > OUTPUT_LIMIT {
        let mut cut = OUTPUT_LIMIT;
        while !output.is_char_boundary(cut) {
            cut -= 1;
        }
        output.truncate(cut);
        output.push('…');
    }
    let entry = ConsoleEntry {
        id: NEXT_ID.fetch_add(1, Ordering::Relaxed),
        time_ms: started
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0),
        cwd: cwd.to_owned(),
        command: display_command(args),
        exit_code,
        duration_ms: duration.as_millis().min(u32::MAX as u128) as u32,
        output,
        background: is_background(args),
    };
    let mut entries = ENTRIES.lock().unwrap_or_else(|e| e.into_inner());
    if entries.len() >= CAPACITY {
        entries.pop_front();
    }
    entries.push_back(entry);
}

/// `git` + 参数，含空格或特殊字符的参数加引号。
fn display_command(args: &[String]) -> String {
    let mut text = String::from("git");
    for arg in args {
        text.push(' ');
        if arg.is_empty() || arg.contains(|c: char| c.is_whitespace() || "'\"$`\\".contains(c)) {
            text.push('"');
            text.push_str(&arg.replace('"', "\\\""));
            text.push('"');
        } else {
            text.push_str(arg);
        }
    }
    text
}

/// 跳过开头的 `-c key=value` 等全局选项，取子命令。
fn subcommand(args: &[String]) -> (Option<&str>, Option<&str>) {
    let mut iter = args.iter().map(String::as_str);
    while let Some(arg) = iter.next() {
        if arg == "-c" || arg == "-C" {
            iter.next();
            continue;
        }
        if arg.starts_with('-') {
            continue;
        }
        return (Some(arg), iter.next());
    }
    (None, None)
}

fn is_background(args: &[String]) -> bool {
    match subcommand(args) {
        (
            Some(
                "status" | "log" | "show" | "cat-file" | "diff-tree" | "rev-list" | "rev-parse"
                | "for-each-ref" | "symbolic-ref" | "show-ref" | "merge-base" | "check-ref-format"
                | "blame" | "ls-tree" | "ls-files" | "grep" | "diff" | "--version",
            ),
            _,
        ) => true,
        (Some("config"), Some(next)) => next.starts_with("--get"),
        (Some("stash"), Some("list")) => true,
        (Some("worktree"), Some("list")) => true,
        (Some("submodule"), Some("status")) => true,
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn formats_commands_with_quoting() {
        assert_eq!(
            display_command(&args(&["commit", "-m", "two words"])),
            r#"git commit -m "two words""#
        );
        assert_eq!(display_command(&args(&["status"])), "git status");
    }

    #[test]
    fn classifies_background_commands() {
        assert!(is_background(&args(&[
            "--no-optional-locks",
            "status",
            "--porcelain=v2"
        ])));
        assert!(is_background(&args(&[
            "config",
            "--get",
            "branch.main.remote"
        ])));
        assert!(is_background(&args(&["stash", "list"])));
        assert!(!is_background(&args(&[
            "-c",
            "core.editor=true",
            "rebase",
            "--continue"
        ])));
        assert!(!is_background(&args(&["stash", "push"])));
        assert!(!is_background(&args(&["push", "origin"])));
    }

    #[test]
    fn records_and_reads_incrementally() {
        let before = console_entries(0).last().map(|e| e.id).unwrap_or(0);
        record(
            "/repo",
            &args(&["fetch"]),
            SystemTime::now(),
            Duration::from_millis(12),
            0,
            "",
        );
        record(
            "/repo",
            &args(&["push"]),
            SystemTime::now(),
            Duration::from_millis(5),
            1,
            "rejected",
        );
        let new: Vec<_> = console_entries(before)
            .into_iter()
            .filter(|e| e.cwd == "/repo")
            .collect();
        assert_eq!(new.len(), 2);
        assert_eq!(new[1].command, "git push");
        assert_eq!(new[1].exit_code, 1);
        assert_eq!(new[1].output, "rejected");
        assert!(new[0].id < new[1].id);
    }
}
