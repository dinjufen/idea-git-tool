//! Annotate（blame）与文件历史的集成测试。

mod common;

use std::fs;
use std::path::Path;
use std::process::Command;

use common::{git, head, new_repo, open};
use gitdeck_core::ChangeKind;

/// 以指定作者提交当前暂存区。
fn commit_as(dir: &Path, author: &str, message: &str) {
    let out = Command::new("git")
        .args(["commit", "-q", "-m", message])
        .current_dir(dir)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_AUTHOR_NAME", author)
        .env(
            "GIT_AUTHOR_EMAIL",
            format!("{}@example.com", author.to_lowercase()),
        )
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
}

#[test]
fn blame_attributes_lines_to_commits_and_local_edits() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    fs::write(dir.join("f.txt"), "one\ntwo\nthree\n").unwrap();
    git(dir, &["add", "f.txt"]);
    commit_as(dir, "Alice", "Add f");
    let first = head(dir);
    fs::write(dir.join("f.txt"), "one\nTWO\nthree\n").unwrap();
    git(dir, &["add", "f.txt"]);
    commit_as(dir, "Bob", "Uppercase two");
    let second = head(dir);
    // 未提交的本地修改。
    fs::write(dir.join("f.txt"), "one\nTWO\nthree\nfour\n").unwrap();

    let blame = open(dir).blame("f.txt".into(), None).unwrap();
    assert_eq!(blame.lines.len(), 4);
    let commit_of = |line: usize| &blame.commits[blame.lines[line] as usize];
    assert_eq!(
        (
            commit_of(0).hash.as_str(),
            commit_of(0).author_name.as_str()
        ),
        (first.as_str(), "Alice")
    );
    assert_eq!(
        (commit_of(1).hash.as_str(), commit_of(1).summary.as_str()),
        (second.as_str(), "Uppercase two")
    );
    assert_eq!(commit_of(2).hash, first);
    assert!(commit_of(3).is_uncommitted);
    assert_eq!(commit_of(1).author_email, "bob@example.com");

    // 指定修订时只看该修订的内容。
    let at_first = open(dir)
        .blame("f.txt".into(), Some(first.clone()))
        .unwrap();
    assert_eq!(at_first.lines.len(), 3);
    assert!(at_first.commits.iter().all(|c| c.hash == first));
}

#[test]
fn file_history_follows_renames() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    fs::write(dir.join("old.rs"), "fn a() {}\nfn b() {}\nfn c() {}\n").unwrap();
    git(dir, &["add", "old.rs"]);
    commit_as(dir, "Alice", "Add old");
    fs::write(
        dir.join("old.rs"),
        "fn a() {}\nfn b() {}\nfn c() {}\nfn d() {}\n",
    )
    .unwrap();
    git(dir, &["commit", "-qam", "Add d"]);
    git(dir, &["mv", "old.rs", "新 名字.rs"]);
    git(dir, &["commit", "-qm", "Rename"]);
    fs::write(dir.join("other.txt"), "x\n").unwrap();
    git(dir, &["add", "other.txt"]);
    git(dir, &["commit", "-qm", "Unrelated"]);

    let history = open(dir).file_history("新 名字.rs".into(), 0).unwrap();
    let summary: Vec<_> = history
        .iter()
        .map(|r| (r.subject.as_str(), r.kind, r.path.as_str()))
        .collect();
    assert_eq!(
        summary,
        [
            ("Rename", ChangeKind::Renamed, "新 名字.rs"),
            ("Add d", ChangeKind::Modified, "old.rs"),
            ("Add old", ChangeKind::Added, "old.rs"),
        ]
    );
    assert_eq!(history[0].orig_path.as_deref(), Some("old.rs"));
    assert_eq!(history[2].author_name, "Alice");
}
