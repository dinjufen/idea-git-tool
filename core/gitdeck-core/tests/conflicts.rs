//! 冲突解决（读取各方版本、标签、写入结果、接受一方、合并提交信息）的集成测试。

mod common;

use std::fs;
use std::path::Path;

use common::{commit_file, git, git_raw, new_repo, open};
use gitdeck_core::{ConflictKind, ConflictSide, RepositoryState};

/// main 与 other 在 a.txt 的同一行上有不同修改，并在 main 上合并 other 产生冲突。
fn merge_conflict(dir: &Path) {
    new_repo(dir);
    commit_file(dir, "a.txt", "1\nbase\n3\n", "base");
    git(dir, &["checkout", "-q", "-b", "other"]);
    commit_file(dir, "a.txt", "1\ntheirs\n3\n", "theirs");
    git(dir, &["checkout", "-q", "main"]);
    commit_file(dir, "a.txt", "1\nours\n3\n", "ours");
    assert!(!git_raw(dir, &["merge", "other"]).status.success());
}

#[test]
fn reads_versions_labels_and_merge_message() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    merge_conflict(dir);
    let repo = open(dir);

    let versions = repo.conflict_versions("a.txt".into()).unwrap();
    assert_eq!(versions.base.as_deref(), Some("1\nbase\n3\n"));
    assert_eq!(versions.ours.as_deref(), Some("1\nours\n3\n"));
    assert_eq!(versions.theirs.as_deref(), Some("1\ntheirs\n3\n"));

    let labels = repo.conflict_labels();
    assert_eq!(
        (labels.ours.as_str(), labels.theirs.as_str()),
        ("main", "other")
    );
    assert_eq!(
        repo.merge_message()
            .as_deref()
            .map(|m| m.lines().next().unwrap()),
        Some("Merge branch 'other'")
    );
}

#[test]
fn resolve_with_merged_content_marks_file_resolved() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    merge_conflict(dir);
    let repo = open(dir);
    repo.resolve_conflict("a.txt".into(), Some("1\nours and theirs\n3\n".into()))
        .unwrap();

    assert_eq!(
        fs::read_to_string(dir.join("a.txt")).unwrap(),
        "1\nours and theirs\n3\n"
    );
    let status = repo.status().unwrap();
    assert!(status.changes.iter().all(|c| c.conflict.is_none()));
    assert_eq!(status.state, RepositoryState::Merging);
}

#[test]
fn accept_ours_or_theirs() {
    for (side, expected) in [
        (ConflictSide::Ours, "1\nours\n3\n"),
        (ConflictSide::Theirs, "1\ntheirs\n3\n"),
    ] {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path();
        merge_conflict(dir);
        let repo = open(dir);
        repo.accept_conflict_side("a.txt".into(), side).unwrap();
        assert_eq!(fs::read_to_string(dir.join("a.txt")).unwrap(), expected);
        assert!(
            repo.status()
                .unwrap()
                .changes
                .iter()
                .all(|c| c.conflict.is_none())
        );
    }
}

#[test]
fn accepting_deletion_removes_file() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    commit_file(dir, "a.txt", "base\n", "base");
    git(dir, &["checkout", "-q", "-b", "other"]);
    git(dir, &["rm", "-q", "a.txt"]);
    git(dir, &["commit", "-q", "-m", "delete a"]);
    git(dir, &["checkout", "-q", "main"]);
    commit_file(dir, "a.txt", "modified\n", "modify a");
    assert!(!git_raw(dir, &["merge", "other"]).status.success());
    let repo = open(dir);

    let status = repo.status().unwrap();
    let change = status.changes.iter().find(|c| c.path == "a.txt").unwrap();
    assert_eq!(change.conflict, Some(ConflictKind::DeletedByThem));
    let versions = repo.conflict_versions("a.txt".into()).unwrap();
    assert!(versions.ours.is_some() && versions.theirs.is_none());

    repo.accept_conflict_side("a.txt".into(), ConflictSide::Theirs)
        .unwrap();
    assert!(!dir.join("a.txt").exists());
    assert!(
        repo.status()
            .unwrap()
            .changes
            .iter()
            .all(|c| c.conflict.is_none())
    );
}

#[test]
fn rebase_labels_swap_sides() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    commit_file(dir, "a.txt", "base\n", "base");
    git(dir, &["checkout", "-q", "-b", "topic"]);
    commit_file(dir, "a.txt", "topic\n", "topic");
    git(dir, &["checkout", "-q", "main"]);
    commit_file(dir, "a.txt", "main\n", "main");
    git(dir, &["checkout", "-q", "topic"]);
    assert!(!git_raw(dir, &["rebase", "main"]).status.success());

    let repo = open(dir);
    assert_eq!(repo.state(), RepositoryState::Rebasing);
    let labels = repo.conflict_labels();
    assert_eq!(
        (labels.ours.as_str(), labels.theirs.as_str()),
        ("main", "topic")
    );
    let versions = repo.conflict_versions("a.txt".into()).unwrap();
    assert_eq!(versions.ours.as_deref(), Some("main\n"));
    assert_eq!(versions.theirs.as_deref(), Some("topic\n"));
}
