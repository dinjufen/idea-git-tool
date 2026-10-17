//! 按修订读取文件内容的集成测试。

mod common;

use std::fs;

use common::{commit_file, git, new_repo, open};
use gitdeck_core::{CoreError, LineChangeKind, line_changes};

#[test]
fn reads_file_at_head_and_older_revisions() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    let first = commit_file(dir, "src/文件 1.txt", "v1\n", "v1");
    commit_file(dir, "src/文件 1.txt", "v2\n", "v2");
    let repo = open(dir);

    assert_eq!(
        repo.file_at_revision("HEAD".into(), "src/文件 1.txt".into())
            .unwrap()
            .as_deref(),
        Some("v2\n")
    );
    assert_eq!(
        repo.file_at_revision(first, "src/文件 1.txt".into())
            .unwrap()
            .as_deref(),
        Some("v1\n")
    );
    assert_eq!(
        repo.file_at_revision("HEAD".into(), "missing.txt".into())
            .unwrap(),
        None
    );
}

#[test]
fn working_copy_changes_against_head() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    new_repo(dir);
    commit_file(dir, "a.txt", "1\n2\n3\n", "add a");
    fs::write(dir.join("a.txt"), "1\n2 changed\n3\n4\n").unwrap();

    let base = open(dir)
        .file_at_revision("HEAD".into(), "a.txt".into())
        .unwrap()
        .unwrap();
    let text = fs::read_to_string(dir.join("a.txt")).unwrap();
    let kinds: Vec<_> = line_changes(base, text)
        .into_iter()
        .map(|c| (c.kind, c.start, c.count))
        .collect();
    assert_eq!(
        kinds,
        [
            (LineChangeKind::Modified, 1, 1),
            (LineChangeKind::Added, 3, 1)
        ]
    );
}

#[test]
fn empty_repository_has_no_head_content() {
    let tmp = tempfile::tempdir().unwrap();
    git(tmp.path(), &["init", "-b", "main"]);
    assert_eq!(
        open(tmp.path())
            .file_at_revision("HEAD".into(), "a.txt".into())
            .unwrap(),
        None
    );
}

#[test]
fn rejects_option_like_revisions() {
    let tmp = tempfile::tempdir().unwrap();
    new_repo(tmp.path());
    let repo = open(tmp.path());
    for bad in ["--output=x", "HEAD:readme.md"] {
        assert!(
            matches!(
                repo.file_at_revision(bad.into(), "readme.md".into()),
                Err(CoreError::Parse { .. })
            ),
            "{bad}"
        );
    }
}
