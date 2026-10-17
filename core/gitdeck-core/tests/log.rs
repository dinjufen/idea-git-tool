//! Git Log、提交详情与引用标签的集成测试。

mod common;

use std::fs;
use std::path::Path;
use std::process::Command;

use common::{commit_file, empty_repo, git, head, new_repo, open};
use gitdeck_core::{ChangeKind, CoreError, LogFilter, RefKind};

/// 以指定作者与时间提交一个文件改动，返回提交哈希。
fn commit_as(dir: &Path, path: &str, message: &str, author: &str, time: i64) -> String {
    fs::write(dir.join(path), format!("{message}\n")).unwrap();
    git(dir, &["add", "--", path]);
    let date = format!("@{time} +0000");
    let out = Command::new("git")
        .args(["commit", "-m", message])
        .current_dir(dir)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_AUTHOR_NAME", author)
        .env(
            "GIT_AUTHOR_EMAIL",
            format!("{}@example.com", author.to_lowercase()),
        )
        .env("GIT_AUTHOR_DATE", &date)
        .env("GIT_COMMITTER_DATE", &date)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    head(dir)
}

fn subjects(page: &gitdeck_core::LogPage) -> Vec<&str> {
    page.commits.iter().map(|c| c.subject.as_str()).collect()
}

/// main: Initial → a → (merge feature) ；feature: f1 → f2，带附注标签 v1。
fn branchy_repo(dir: &Path) {
    new_repo(dir);
    git(dir, &["checkout", "-b", "feature"]);
    commit_file(dir, "f.txt", "1\n", "f1");
    commit_file(dir, "f.txt", "2\n", "f2");
    git(dir, &["tag", "-a", "v1", "-m", "release v1"]);
    git(dir, &["checkout", "main"]);
    commit_file(dir, "a.txt", "a\n", "a");
    git(dir, &["merge", "--no-ff", "feature", "-m", "Merge feature"]);
}

#[test]
fn log_includes_all_refs_with_graph_and_labels() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    branchy_repo(dir);

    let page = open(dir).log(LogFilter::default()).unwrap();
    assert!(!page.has_more);
    assert_eq!(page.commits.len(), 5);
    let merge = &page.commits[0];
    assert_eq!(merge.subject, "Merge feature");
    assert_eq!(merge.parents.len(), 2);
    assert_eq!(merge.graph.width, 2);
    let main = &merge.refs[0];
    assert_eq!(
        (main.name.as_str(), main.kind, main.is_current),
        ("main", RefKind::LocalBranch, true)
    );
    assert_eq!(page.commits.last().unwrap().subject, "Initial commit");

    // 拓扑顺序：同一分支的提交相邻。
    let s = subjects(&page);
    let f1 = s.iter().position(|x| *x == "f1").unwrap();
    let f2 = s.iter().position(|x| *x == "f2").unwrap();
    assert_eq!(f2 + 1, f1);

    // 附注标签显示在它指向的提交上，feature 分支标签也在 f2 上。
    let f2_refs: Vec<_> = page.commits[f2]
        .refs
        .iter()
        .map(|r| (r.name.as_str(), r.kind))
        .collect();
    assert_eq!(
        f2_refs,
        [("feature", RefKind::LocalBranch), ("v1", RefKind::Tag)]
    );
}

#[test]
fn log_of_empty_repository_is_empty() {
    let tmp = tempfile::tempdir().unwrap();
    empty_repo(tmp.path());
    let page = open(tmp.path()).log(LogFilter::default()).unwrap();
    assert!(page.commits.is_empty());
}

#[test]
fn detached_head_gets_head_label() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    let first = head(dir);
    commit_file(dir, "a.txt", "a\n", "a");
    git(dir, &["checkout", "--detach", &first]);

    let page = open(dir).log(LogFilter::default()).unwrap();
    let initial = page.commits.iter().find(|c| c.hash == first).unwrap();
    assert_eq!(initial.refs[0].kind, RefKind::Head);
    assert!(page.commits[0].refs.iter().all(|r| !r.is_current));
}

#[test]
fn max_count_and_has_more() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    for i in 0..5 {
        commit_file(dir, "n.txt", &format!("{i}\n"), &format!("c{i}"));
    }
    let page = open(dir)
        .log(LogFilter {
            max_count: 3,
            ..Default::default()
        })
        .unwrap();
    assert!(page.has_more);
    assert_eq!(subjects(&page), ["c4", "c3", "c2"]);
}

#[test]
fn filters_by_author_text_and_date() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    empty_repo(dir);
    commit_as(dir, "a.txt", "fix(ui): Button colour", "Alice", 1_000_000);
    commit_as(dir, "b.txt", "Add feature", "Bob", 2_000_000);
    commit_as(dir, "c.txt", "Fix(UI): menu", "Bob", 3_000_000);
    let repo = open(dir);

    let by_bob = repo
        .log(LogFilter {
            authors: vec!["bob".into()],
            ..Default::default()
        })
        .unwrap();
    assert_eq!(subjects(&by_bob), ["Fix(UI): menu", "Add feature"]);

    // 按字面量、不区分大小写匹配，括号不会被当作正则。
    let text = repo
        .log(LogFilter {
            text: Some("fix(ui)".into()),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(subjects(&text), ["Fix(UI): menu", "fix(ui): Button colour"]);

    // 作者与文本同时筛选时取交集。
    let both = repo
        .log(LogFilter {
            authors: vec!["Bob".into()],
            text: Some("fix".into()),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(subjects(&both), ["Fix(UI): menu"]);

    let ranged = repo
        .log(LogFilter {
            since: Some(1_500_000),
            until: Some(2_500_000),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(subjects(&ranged), ["Add feature"]);
}

#[test]
fn path_filter_rewrites_parents() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    let first = commit_file(dir, "tracked.txt", "1\n", "t1");
    commit_file(dir, "other.txt", "x\n", "unrelated");
    let second = commit_file(dir, "tracked.txt", "2\n", "t2");

    let page = open(dir)
        .log(LogFilter {
            paths: vec!["tracked.txt".into()],
            ..Default::default()
        })
        .unwrap();
    assert_eq!(subjects(&page), ["t2", "t1"]);
    // 中间无关的提交被跳过，父提交被改写为 t1，提交图保持连贯。
    assert_eq!(page.commits[0].hash, second);
    assert_eq!(page.commits[0].parents, [first]);
}

#[test]
fn revision_filter_limits_to_branch() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    branchy_repo(dir);
    git(dir, &["checkout", "-b", "side", "HEAD~1"]);
    commit_file(dir, "s.txt", "s\n", "side work");

    let page = open(dir)
        .log(LogFilter {
            revisions: vec!["side".into()],
            ..Default::default()
        })
        .unwrap();
    assert_eq!(subjects(&page), ["side work", "a", "Initial commit"]);
}

#[test]
fn commit_details_lists_changed_files() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    let root = git(dir, &["rev-list", "--max-parents=0", "HEAD"])
        .trim()
        .to_owned();
    commit_file(
        dir,
        "old.txt",
        "same content for rename detection\n",
        "add old",
    );
    git(dir, &["mv", "old.txt", "new.txt"]);
    fs::write(dir.join("readme.md"), "changed\n").unwrap();
    git(dir, &["add", "-A"]);
    git(dir, &["commit", "-m", "Rename and edit\n\nLonger body."]);
    let repo = open(dir);

    let details = repo.commit_details(head(dir)).unwrap();
    assert_eq!(details.message, "Rename and edit\n\nLonger body.");
    assert_eq!(details.author_name, "Test");
    let mut files: Vec<_> = details
        .files
        .iter()
        .map(|f| (f.path.as_str(), f.orig_path.as_deref(), f.kind))
        .collect();
    files.sort_by_key(|f| f.0);
    assert_eq!(
        files,
        [
            ("new.txt", Some("old.txt"), ChangeKind::Renamed),
            ("readme.md", None, ChangeKind::Modified),
        ]
    );

    let root_details = repo.commit_details(root).unwrap();
    assert!(root_details.parents.is_empty());
    assert_eq!(root_details.files.len(), 1);
    assert_eq!(root_details.files[0].kind, ChangeKind::Added);
}

#[test]
fn merge_commit_details_are_relative_to_first_parent() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    branchy_repo(dir);
    let details = open(dir).commit_details(head(dir)).unwrap();
    assert_eq!(details.parents.len(), 2);
    let paths: Vec<_> = details.files.iter().map(|f| f.path.as_str()).collect();
    assert_eq!(paths, ["f.txt"]);
}

#[test]
fn branches_containing_commit() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    branchy_repo(dir);
    let f2 = git(dir, &["rev-parse", "feature"]).trim().to_owned();
    let mut branches = open(dir).branches_containing(f2).unwrap();
    branches.sort();
    assert_eq!(branches, ["feature", "main"]);
}

#[test]
fn rejects_non_hash_arguments() {
    let tmp = tempfile::tempdir().unwrap();
    new_repo(tmp.path());
    let repo = open(tmp.path());
    for bad in ["--output=/tmp/x", "HEAD", "main~1", ""] {
        assert!(
            matches!(
                repo.commit_details(bad.into()),
                Err(CoreError::Parse { .. })
            ),
            "{bad}"
        );
    }
}
