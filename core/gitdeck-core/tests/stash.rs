//! Stash 的集成测试。

mod common;

use std::fs;

use common::{commit_file, git, new_repo, open};
use gitdeck_core::{ChangeKind, CoreError, StashOptions};

#[test]
fn stash_list_files_and_pop() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    commit_file(dir, "a.txt", "a\n", "add a");
    fs::write(dir.join("a.txt"), "a changed\n").unwrap();
    fs::write(dir.join("new.txt"), "new\n").unwrap();
    let repo = open(dir);

    assert!(
        repo.stash_changes(StashOptions {
            message: Some("work in progress".into()),
            include_untracked: true,
            ..Default::default()
        })
        .unwrap()
    );
    assert!(repo.status().unwrap().changes.is_empty());

    let stashes = repo.stashes().unwrap();
    assert_eq!(stashes.len(), 1);
    assert_eq!(stashes[0].index, 0);
    assert_eq!(stashes[0].message, "work in progress");
    assert_eq!(stashes[0].branch.as_deref(), Some("main"));
    assert!(stashes[0].has_untracked);

    let mut files: Vec<_> = repo
        .stash_files(0)
        .unwrap()
        .into_iter()
        .map(|f| (f.path, f.kind))
        .collect();
    files.sort_by(|a, b| a.0.cmp(&b.0));
    assert_eq!(
        files,
        [
            ("a.txt".into(), ChangeKind::Modified),
            ("new.txt".into(), ChangeKind::Untracked)
        ]
    );
    assert_eq!(
        repo.file_at_revision("stash@{0}".into(), "a.txt".into())
            .unwrap()
            .as_deref(),
        Some("a changed\n")
    );

    let outcome = repo.apply_stash(0, true, false).unwrap();
    assert!(!outcome.conflicts);
    assert!(repo.stashes().unwrap().is_empty());
    assert_eq!(fs::read_to_string(dir.join("new.txt")).unwrap(), "new\n");
}

#[test]
fn nothing_to_stash_and_partial_stash() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    let repo = open(dir);
    assert!(!repo.stash_changes(StashOptions::default()).unwrap());

    commit_file(dir, "a.txt", "a\n", "a");
    commit_file(dir, "b.txt", "b\n", "b");
    fs::write(dir.join("a.txt"), "a2\n").unwrap();
    fs::write(dir.join("b.txt"), "b2\n").unwrap();
    repo.stash_changes(StashOptions {
        paths: vec!["a.txt".into()],
        ..Default::default()
    })
    .unwrap();
    let remaining: Vec<_> = repo
        .status()
        .unwrap()
        .changes
        .into_iter()
        .map(|c| c.path)
        .collect();
    assert_eq!(remaining, ["b.txt"]);
    // 未填写消息时使用 HEAD 的提交标题。
    assert_eq!(repo.stashes().unwrap()[0].message, "b");
}

#[test]
fn apply_keeps_stash_and_reports_conflicts() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    commit_file(dir, "a.txt", "base\n", "base");
    fs::write(dir.join("a.txt"), "stashed\n").unwrap();
    let repo = open(dir);
    repo.stash_changes(StashOptions::default()).unwrap();
    commit_file(dir, "a.txt", "committed\n", "conflicting commit");

    let outcome = repo.apply_stash(0, true, false).unwrap();
    assert!(outcome.conflicts);
    // pop 遇到冲突时储藏保留。
    assert_eq!(repo.stashes().unwrap().len(), 1);
}

#[test]
fn drop_clear_and_branch() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    let repo = open(dir);
    for i in 0..3 {
        fs::write(dir.join("readme.md"), format!("change {i}\n")).unwrap();
        repo.stash_changes(StashOptions {
            message: Some(format!("s{i}")),
            ..Default::default()
        })
        .unwrap();
    }
    let messages: Vec<_> = repo
        .stashes()
        .unwrap()
        .into_iter()
        .map(|s| s.message)
        .collect();
    assert_eq!(messages, ["s2", "s1", "s0"]);

    repo.drop_stash(1).unwrap();
    let messages: Vec<_> = repo
        .stashes()
        .unwrap()
        .into_iter()
        .map(|s| s.message)
        .collect();
    assert_eq!(messages, ["s2", "s0"]);

    repo.stash_to_branch(1, "from-stash".into()).unwrap();
    assert_eq!(git(dir, &["branch", "--show-current"]).trim(), "from-stash");
    assert_eq!(
        fs::read_to_string(dir.join("readme.md")).unwrap(),
        "change 0\n"
    );
    assert_eq!(repo.stashes().unwrap().len(), 1);
    assert!(matches!(
        repo.stash_to_branch(0, "bad name".into()),
        Err(CoreError::InvalidBranchName { .. })
    ));

    repo.clear_stashes().unwrap();
    assert!(repo.stashes().unwrap().is_empty());
}
